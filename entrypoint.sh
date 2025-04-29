#!/bin/bash

# 数据库文件名和备份文件名前缀
DB_FILENAME="one-api.db"
BACKUP_PREFIX="one_api_backup_"
# 数据目录（容器内绝对路径）
DATA_DIR="/data"
# 数据库文件完整路径
DB_FILE_PATH="${DATA_DIR}/${DB_FILENAME}"
# 临时文件目录
TMP_DIR="/tmp"

# 检查 WebDAV 环境变量，如果缺少则只启动主程序
if [[ -z "$WEBDAV_URL" ]] || [[ -z "$WEBDAV_USERNAME" ]] || [[ -z "$WEBDAV_PASSWORD" ]]; then
    echo "缺少 WEBDAV_URL、WEBDAV_USERNAME 或 WEBDAV_PASSWORD 环境变量，启动时不启用备份/恢复功能。"

else
    echo "检测到 WebDAV 配置，启用备份/恢复功能。"

    # 处理可选的备份子目录路径
    WEBDAV_BACKUP_PATH=${WEBDAV_BACKUP_PATH:-""}
    # 确保基础 URL 没有尾部斜杠
    WEBDAV_URL_BASE=${WEBDAV_URL%/}
    FULL_WEBDAV_URL="${WEBDAV_URL_BASE}"
    if [ -n "$WEBDAV_BACKUP_PATH" ]; then
        # 确保子目录路径没有前导斜杠
        WEBDAV_BACKUP_PATH_CLEAN=${WEBDAV_BACKUP_PATH#/}
        FULL_WEBDAV_URL="${WEBDAV_URL_BASE}/${WEBDAV_BACKUP_PATH_CLEAN}"
    fi
    echo "WebDAV 完整路径: ${FULL_WEBDAV_URL}"

    # 下载最新备份并恢复函数
    restore_backup() {
        echo "开始尝试从 WebDAV 下载并恢复最新备份..."
        python3 -c "
import sys
import os
import tarfile
import requests
from webdav3.client import Client
import shutil

# 从环境变量获取配置
webdav_url = '$FULL_WEBDAV_URL'
webdav_user = '$WEBDAV_USERNAME'
webdav_pass = '$WEBDAV_PASSWORD'
db_filename = '$DB_FILENAME'
backup_prefix = '$BACKUP_PREFIX'
local_db_path = '$DB_FILE_PATH' # 恢复的目标路径
tmp_dir = '$TMP_DIR/restore_$$' # 唯一的临时解压目录
tmp_download_dir = '$TMP_DIR' # 下载文件存放目录

options = {
    'webdav_hostname': webdav_url,
    'webdav_login': webdav_user,
    'webdav_password': webdav_pass
}

try:
    client = Client(options)
    # 尝试创建远程目录（如果不存在），忽略 'Method Not Allowed' (目录已存在) 或类似错误
    try:
        # webdavclient3 的 mkdir 需要相对路径（相对于 hostname）
        relative_path = webdav_url.replace(client.options.get('webdav_root', ''), '', 1)
        if not relative_path.startswith('/'): relative_path = '/' + relative_path # 确保有根
        client.mkdir(relative_path)
        print(f'尝试创建/确认 WebDAV 目录 {relative_path} 存在')
    except Exception as mkdir_err:
        # 常见的目录已存在错误码可能不同，这里简单忽略一些已知情况
        if '405' not in str(mkdir_err) and 'exists' not in str(mkdir_err).lower():
             print(f'警告：创建 WebDAV 目录时发生非预期错误: {mkdir_err}')

    # 列出 WebDAV 目录中的所有文件/目录
    remote_items = client.list()
    # print(f'DEBUG: Remote items: {remote_items}') # 调试时取消注释

    # 筛选出符合条件的备份文件（.tar.gz 结尾且前缀匹配）
    # client.list() 返回的可能是 基础URL后的相对路径 或 完整URL，需要处理
    backups = []
    for item in remote_items:
         basename = os.path.basename(item.rstrip('/')) # 获取文件名
         if basename.endswith('.tar.gz') and basename.startswith(backup_prefix):
             # 存储完整路径或相对路径，取决于 client.list() 返回什么
             # 假设返回的是相对路径，需要拼接才能下载
             backups.append(item)

    if not backups:
        print('在 WebDAV 上没有找到符合条件的备份文件，跳过恢复。')
        sys.exit(0) # 正常退出，不执行恢复

    # 按文件名排序找到最新的备份
    backups.sort(key=lambda x: os.path.basename(x.rstrip('/')))
    latest_backup_path = backups[-1] # list返回的路径
    latest_backup_basename = os.path.basename(latest_backup_path.rstrip('/'))
    print(f'找到最新备份文件: {latest_backup_basename}')

    # 构建完整的下载 URL
    # 确保 URL 基础部分没有尾部斜杠，路径部分没有前导斜杠
    download_url = options['webdav_hostname'].rstrip('/') + '/' + latest_backup_path.lstrip('/')
    local_tmp_download_path = os.path.join(tmp_download_dir, latest_backup_basename)

    # 下载备份文件
    print(f'开始下载: {download_url} -> {local_tmp_download_path}')
    try:
        with requests.get(download_url, auth=(options['webdav_login'], options['webdav_password']), stream=True, timeout=300) as r:
            r.raise_for_status() # 如果状态码不是 2xx，则抛出 HTTPError
            with open(local_tmp_download_path, 'wb') as f:
                for chunk in r.iter_content(chunk_size=8192):
                    f.write(chunk)
            print(f'成功下载备份文件到 {local_tmp_download_path}')
    except requests.exceptions.RequestException as download_err:
         print(f'下载备份文件时出错: {download_err}')
         sys.exit(1) # 下载失败，异常退出

    # 解压并恢复数据库文件
    if os.path.exists(local_tmp_download_path):
        try:
            os.makedirs(tmp_dir, exist_ok=True)
            print(f'开始解压 {local_tmp_download_path} 到 {tmp_dir}')
            with tarfile.open(local_tmp_download_path, 'r:gz') as tar:
                # 安全解压，防止路径遍历攻击
                def is_within_directory(directory, target):
                    abs_directory = os.path.abspath(directory)
                    abs_target = os.path.abspath(target)
                    prefix = os.path.commonprefix([abs_directory, abs_target])
                    return prefix == abs_directory

                for member in tar.getmembers():
                    member_path = os.path.join(tmp_dir, member.name)
                    if not is_within_directory(tmp_dir, member_path):
                        raise Exception(f'检测到不安全的解压路径: {member.name}')
                tar.extractall(path=tmp_dir)

            # 查找解压后的数据库文件 (应该就在解压根目录)
            extracted_db_path = os.path.join(tmp_dir, db_filename)
            if os.path.isfile(extracted_db_path):
                print(f'在解压目录中找到 {db_filename}')
                # 确保目标目录存在
                os.makedirs(os.path.dirname(local_db_path), exist_ok=True)
                # 移动（覆盖）数据库文件
                shutil.move(extracted_db_path, local_db_path)
                print(f'成功从 {latest_backup_basename} 恢复 {db_filename} 到 {local_db_path}')
            else:
                print(f'错误：在解压后的备份文件 {tmp_dir} 中未找到 {db_filename}。')
                # 可选：检查是否存在旧格式 (如 data/one-api.db)，如果需要兼容
                # old_format_path = os.path.join(tmp_dir, 'data', db_filename)
                # if os.path.isfile(old_format_path): ...

        except (tarfile.TarError, OSError, Exception) as extract_err:
             print(f'解压或恢复数据库时出错: {extract_err}')
        finally:
            # 清理下载的压缩包和解压目录
            print(f'清理临时文件: {local_tmp_download_path}')
            os.remove(local_tmp_download_path)
            if os.path.exists(tmp_dir):
                 print(f'清理临时目录: {tmp_dir}')
                 shutil.rmtree(tmp_dir)
    else:
        print(f'错误：下载的备份文件 {local_tmp_download_path} 未找到。')

except Exception as e:
    print(f'执行恢复备份过程中发生意外错误: {e}')
    # 即使恢复失败，也允许主程序继续启动，可能使用空的或旧的数据库
"
        # 检查 Python 脚本的退出码
        if [ $? -ne 0 ]; then
             echo "警告：恢复备份脚本执行失败。"
        fi
    }

    # 首次启动时尝试恢复最新备份
    restore_backup

    # 后台定期同步函数
    sync_data() {
        local keep_latest_backups=5 # 保留最新的备份数量

        while true; do
            # 获取同步间隔，默认 600 秒 (10 分钟)
            SYNC_INTERVAL=${SYNC_INTERVAL:-600}
            echo "同步检查开始: $(date)"

            # 检查数据库文件是否存在
            if [ -f "$DB_FILE_PATH" ]; then
                timestamp=$(date +%Y%m%d_%H%M%S)
                backup_basename="${BACKUP_PREFIX}${timestamp}.tar.gz"
                local_tmp_backup_path="${TMP_DIR}/${backup_basename}"

                echo "找到数据库文件: ${DB_FILE_PATH}"
                echo "创建本地临时备份: ${local_tmp_backup_path}"
                # 使用 tar 打包，-C 指定源目录，只包含文件名
                tar -czf "${local_tmp_backup_path}" -C "${DATA_DIR}" "${DB_FILENAME}"
                if [ $? -ne 0 ]; then
                     echo "错误：创建 tar 压缩文件失败。"
                     # 失败后也需要等待，避免高频重试
                     echo "下次同步检查将在 ${SYNC_INTERVAL} 秒后进行..."
                     sleep $SYNC_INTERVAL
                     continue # 跳过本次循环的后续步骤
                fi

                # 上传新备份到 WebDAV
                echo "准备上传备份: ${backup_basename}"
                # 确保 URL 尾部有斜杠，文件名不以斜杠开头
                upload_url="${FULL_WEBDAV_URL%/}/${backup_basename}"
                echo "上传至: ${upload_url}"
                # 使用 curl 上传，-T 指定文件，-u 提供认证信息
                # --fail: HTTP 错误时返回非零退出码
                # -s: 静默模式
                # -o /dev/null: 丢弃服务器响应体
                # --connect-timeout 10: 连接超时10秒
                # --max-time 300: 最大传输时间300秒
                curl -u "$WEBDAV_USERNAME:$WEBDAV_PASSWORD" -T "${local_tmp_backup_path}" "${upload_url}" --fail -s -o /dev/null --connect-timeout 10 --max-time 300
                upload_status=$?

                if [ ${upload_status} -eq 0 ]; then
                    echo "成功将 ${backup_basename} 上传至 WebDAV"
                else
                    echo "上传 ${backup_basename} 至 WebDAV 失败 (curl 退出码: ${upload_status})"
                    # 上传失败不删除本地临时文件，以便排查
                fi

                # 清理 WebDAV 上的旧备份文件
                echo "开始清理 WebDAV 上的旧备份 (保留最新的 ${keep_latest_backups} 个)..."
                python3 -c "
import sys
import os
from webdav3.client import Client

# 从环境变量获取配置
webdav_url = '$FULL_WEBDAV_URL'
webdav_user = '$WEBDAV_USERNAME'
webdav_pass = '$WEBDAV_PASSWORD'
backup_prefix = '$BACKUP_PREFIX'
keep_latest = $keep_latest_backups

options = {
    'webdav_hostname': webdav_url,
    'webdav_login': webdav_user,
    'webdav_password': webdav_pass
}

try:
    client = Client(options)
    remote_items = client.list()
    # print(f'DEBUG: Remote items before cleanup: {remote_items}') # 调试时取消注释

    # 筛选备份文件
    backups = []
    for item in remote_items:
        basename = os.path.basename(item.rstrip('/'))
        if basename.endswith('.tar.gz') and basename.startswith(backup_prefix):
             # 假设 client.list() 返回的是相对路径或带 hostname 的路径
             # 需要从路径中提取用于删除的部分，通常是 hostname 之后的部分
             relative_path = item.replace(client.options.get('webdav_root',''), '', 1).lstrip('/')
             backups.append(relative_path) # 存储用于排序和删除的相对路径

    if not backups:
        print('未找到需要清理的备份文件。')
        sys.exit(0)

    # 按文件名（时间戳）排序
    backups.sort()

    print(f'找到 {len(backups)} 个备份文件。')
    if len(backups) > keep_latest:
        to_delete_count = len(backups) - keep_latest
        print(f'需要删除 {to_delete_count} 个旧备份。')
        files_to_delete = backups[:to_delete_count]
        deleted_count = 0
        for file_path in files_to_delete:
            try:
                # 使用 client.clean 删除，需要相对路径
                client.clean(file_path)
                print(f'成功删除旧备份: {os.path.basename(file_path)}')
                deleted_count += 1
            except Exception as delete_err:
                print(f'删除旧备份 {os.path.basename(file_path)} 时出错: {delete_err}')
        print(f'实际删除 {deleted_count} 个旧备份。')
    else:
        print(f'备份数量 ({len(backups)}) 未超过限制 ({keep_latest})，无需清理。')

except Exception as e:
    print(f'清理旧备份时发生意外错误: {e}')
" # Python 清理脚本结束

                # 清理本地临时备份文件（无论上传是否成功，只要 tar 创建成功就清理）
                echo "清理本地临时备份文件: ${local_tmp_backup_path}"
                rm -f "${local_tmp_backup_path}"
            else
                echo "数据库文件 ${DB_FILE_PATH} 不存在，跳过本次备份。"
            fi

            echo "下次同步检查将在 ${SYNC_INTERVAL} 秒后进行..."
            sleep $SYNC_INTERVAL
        done
    }

    # 后台启动同步进程
    echo "在后台启动定期备份进程..."
    sync_data &
    sync_pid=$!
    echo "备份进程 PID: ${sync_pid}"

fi # 结束 WebDAV 配置检查

# 启动主应用程序
echo "启动主程序: /one-api $@"
# 使用 exec 将 shell 替换为 one-api 进程
# "$@" 将传递给 entrypoint.sh 的所有参数原样传递给 one-api
exec /one-api "$@"

# exec 后面的代码不会执行
echo "如果看到此消息，则 exec /one-api 失败！"
exit 1