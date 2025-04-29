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
        # 使用唯一的临时目录名，避免潜在冲突
        local restore_tmp_dir="${TMP_DIR}/restore_$$"
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
tmp_dir = '$restore_tmp_dir' # 使用传入的唯一临时解压目录
tmp_download_dir = '$TMP_DIR' # 下载文件存放目录

options = {
    'webdav_hostname': webdav_url,
    'webdav_login': webdav_user,
    'webdav_password': webdav_pass,
    # 可选：根据需要增加 timeout 等选项
    # 'webdav_timeout': 60
}

try:
    client = Client(options)
    # 注意：移除显式的 client.mkdir 调用。
    # 假设 list 或 upload 会隐式处理目录存在性，或依赖用户预先创建目录。
    # 如果必须创建，考虑 client.mkdir('.')，但这可能因服务器实现而异。
    print(f'尝试列出 WebDAV 目录 {webdav_url} 中的内容...')

    # 列出 WebDAV 目录中的所有文件/目录
    remote_items = client.list()
    # print(f'DEBUG: Remote items: {remote_items}') # 调试时取消注释

    # 筛选出符合条件的备份文件（.tar.gz 结尾且前缀匹配）
    # client.list() 返回的通常是相对路径
    backups = []
    for item_path in remote_items:
         basename = os.path.basename(item_path.rstrip('/')) # 获取文件名
         if basename.endswith('.tar.gz') and basename.startswith(backup_prefix):
             # 存储 list() 返回的路径，它应该是相对路径
             backups.append(item_path)

    if not backups:
        print('在 WebDAV 上没有找到符合条件的备份文件，跳过恢复。')
        sys.exit(0) # 正常退出，不执行恢复

    # 按文件名排序找到最新的备份 (假设文件名中的时间戳可以正确排序)
    backups.sort() # 直接排序相对路径列表
    latest_backup_path = backups[-1] # list() 返回的相对路径
    latest_backup_basename = os.path.basename(latest_backup_path.rstrip('/'))
    print(f'找到最新备份文件路径: {latest_backup_path} (文件名: {latest_backup_basename})')

    # 构建完整的下载 URL (这里使用 options 字典是正确的)
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
         # 如果下载文件存在，尝试删除，避免遗留不完整文件
         if os.path.exists(local_tmp_download_path):
             os.remove(local_tmp_download_path)
         sys.exit(1) # 下载失败，异常退出

    # 解压并恢复数据库文件
    if os.path.exists(local_tmp_download_path):
        try:
            os.makedirs(tmp_dir, exist_ok=True)
            print(f'开始解压 {local_tmp_download_path} 到 {tmp_dir}')
            with tarfile.open(local_tmp_download_path, 'r:gz') as tar:
                # 安全解压 (检查路径是否在目标目录内)
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

        except (tarfile.TarError, OSError, Exception) as extract_err:
             print(f'解压或恢复数据库时出错: {extract_err}')
        finally:
            # 清理下载的压缩包和解压目录
            print(f'清理临时下载文件: {local_tmp_download_path}')
            os.remove(local_tmp_download_path)
            if os.path.exists(tmp_dir):
                 print(f'清理临时解压目录: {tmp_dir}')
                 shutil.rmtree(tmp_dir)
    else:
        print(f'错误：下载的备份文件 {local_tmp_download_path} 未找到 (可能下载失败后被清理)。')

except Exception as e:
    print(f'执行恢复备份过程中发生意外错误: {e}')
    # 尝试清理可能残留的临时文件/目录
    if 'local_tmp_download_path' in locals() and os.path.exists(local_tmp_download_path):
        os.remove(local_tmp_download_path)
    if 'tmp_dir' in locals() and os.path.exists(tmp_dir):
        shutil.rmtree(tmp_dir)
    # 即使恢复失败，也允许主程序继续启动
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
                # 添加错误检查
                if tar -czf "${local_tmp_backup_path}" -C "${DATA_DIR}" "${DB_FILENAME}"; then
                    echo "本地临时备份创建成功。"
                else
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
                # 使用 curl 上传，增加超时和错误处理
                curl_output=$(curl -u "$WEBDAV_USERNAME:$WEBDAV_PASSWORD" -T "${local_tmp_backup_path}" "${upload_url}" --fail -sS --connect-timeout 10 --max-time 300 2>&1)
                upload_status=$?

                if [ ${upload_status} -eq 0 ]; then
                    echo "成功将 ${backup_basename} 上传至 WebDAV"
                else
                    echo "上传 ${backup_basename} 至 WebDAV 失败 (curl 退出码: ${upload_status})。错误信息: ${curl_output}"
                    # 上传失败不删除本地临时文件，以便排查
                fi

                # 清理 WebDAV 上的旧备份文件 (只有在上传成功后或者无论上传是否成功都执行清理，取决于策略，当前策略是总是尝试清理)
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
    'webdav_password': webdav_pass,
    # 可选：增加 timeout 等选项
    # 'webdav_timeout': 60
}

try:
    client = Client(options)
    print(f'尝试列出 WebDAV 目录 {webdav_url} 以进行清理...')
    remote_items = client.list()
    # print(f'DEBUG: Remote items before cleanup: {remote_items}') # 调试时取消注释

    # 筛选备份文件，保存 basename 和原始相对路径
    backups_info = []
    for item_path in remote_items:
        # 确保 item_path 是字符串类型，os.path.basename 可以处理
        if isinstance(item_path, str):
            basename = os.path.basename(item_path.rstrip('/'))
            if basename.endswith('.tar.gz') and basename.startswith(backup_prefix):
                 # 存储包含 basename 和 path 的字典
                 backups_info.append({'basename': basename, 'path': item_path})
        else:
            print(f'警告: client.list() 返回了非字符串类型项: {item_path}')


    if not backups_info:
        print('未找到需要清理的备份文件。')
        sys.exit(0)

    # 按文件名（时间戳）排序
    backups_info.sort(key=lambda x: x['basename'])

    print(f'找到 {len(backups_info)} 个符合条件的备份文件。')
    if len(backups_info) > keep_latest:
        to_delete_count = len(backups_info) - keep_latest
        print(f'需要删除 {to_delete_count} 个旧备份。')
        files_to_delete_info = backups_info[:to_delete_count] # 获取要删除的文件信息列表
        deleted_count = 0
        for file_info in files_to_delete_info:
            try:
                # 使用存储的原始相对路径进行删除 (file_info['path'])
                print(f'准备删除: {file_info["path"]}')
                client.clean(file_info['path'])
                print(f'成功删除旧备份: {file_info["basename"]}')
                deleted_count += 1
            except Exception as delete_err:
                # 打印更详细的错误，包括尝试删除的文件路径
                print(f'删除旧备份 {file_info["basename"]} (路径: {file_info["path"]}) 时出错: {delete_err}')
        print(f'实际删除 {deleted_count} 个旧备份。')
    else:
        print(f'备份数量 ({len(backups_info)}) 未超过限制 ({keep_latest})，无需清理。')

except Exception as e:
    # 打印详细的异常信息，包括类型和参数
    import traceback
    print(f'清理旧备份时发生意外错误: {type(e).__name__}: {e}')
    # traceback.print_exc() # 可选：打印完整堆栈跟踪
" # Python 清理脚本结束
                cleanup_status=$?
                if [ ${cleanup_status} -ne 0 ]; then
                    echo "警告：清理旧备份的 Python 脚本执行失败。"
                fi

                # 清理本地临时备份文件（无论上传或清理是否成功，只要 tar 创建成功就清理）
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