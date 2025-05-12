#!/bin/bash

# --- 配置 START ---
# 数据库文件路径和名称 (根据您的应用调整，这里仿照示例使用 one-api.db)
DB_FILE_PATH="/data/one-api.db"
DB_FILE_NAME="one-api.db" # 仅文件名部分
BACKUP_FILE_PREFIX="one-api_backup_" # WebDAV上备份文件的前缀
MAX_BACKUPS_TO_KEEP=5 # 在WebDAV上保留的最大备份数量
# --- 配置 END ---

# 检查核心 WebDAV 环境变量
if [[ -z "$WEBDAV_URL" ]] || [[ -z "$WEBDAV_USERNAME" ]] || [[ -z "$WEBDAV_PASSWORD" ]]; then
    echo "警告: 环境变量 WEBDAV_URL, WEBDAV_USERNAME, 或 WEBDAV_PASSWORD 未完整设置。"
    echo "WebDAV 备份和恢复功能将被禁用。"
    # 直接启动主应用
    echo "启动 one-api 程序..."
    exec /one-api "$@"
fi

# 设置 WebDAV 备份的完整 URL
# WEBDAV_BACKUP_PATH 是用户可以指定在 WEBDAV_URL 基础上的子目录
WEBDAV_PATH_SUFFIX=${WEBDAV_BACKUP_PATH:-""}
FULL_WEBDAV_URL="${WEBDAV_URL}"
if [ -n "$WEBDAV_PATH_SUFFIX" ]; then
    # 清理 WEBDAV_PATH_SUFFIX 前后的斜杠
    WEBDAV_PATH_SUFFIX=$(echo "$WEBDAV_PATH_SUFFIX" | sed 's:/*$::' | sed 's:^/*::')
    # 组合 URL，确保 WEBDAV_URL 和 WEBDAV_PATH_SUFFIX 之间只有一个斜杠
    FULL_WEBDAV_URL="${WEBDAV_URL%/}/${WEBDAV_PATH_SUFFIX}"
fi
echo "WebDAV 备份将使用 URL: $FULL_WEBDAV_URL"

# 函数：从 WebDAV 恢复最新备份
restore_backup() {
    echo "开始从 WebDAV 下载并恢复最新备份 (数据库文件: $DB_FILE_NAME)..."
    python3 -c "
import sys
import os
import tarfile
import requests
from webdav3.client import Client
import shutil

# 从环境变量获取配置 (由 shell 脚本传入)
webdav_hostname = '$FULL_WEBDAV_URL'
webdav_login = '$WEBDAV_USERNAME'
webdav_password = '$WEBDAV_PASSWORD'
db_file_path = '$DB_FILE_PATH' # 最终恢复的目标路径, e.g., /data/one-api.db
db_file_name = '$DB_FILE_NAME' # e.g., one-api.db
backup_prefix = '$BACKUP_FILE_PREFIX' # e.g., one-api_backup_

options = {
    'webdav_hostname': webdav_hostname,
    'webdav_login':    webdav_login,
    'webdav_password': webdav_password
}
client = Client(options)

# 确保 /data 目录存在 (虽然它是 WORKDIR, 双重检查无害)
os.makedirs(os.path.dirname(db_file_path), exist_ok=True)

print(f'正在从 {webdav_hostname} 列出备份文件...')
try:
    # 获取 WebDAV 目录中的所有文件/目录名
    files_on_server = client.list() 
    # 筛选出符合条件的备份文件 (例如 'one-api_backup_....tar.gz')
    # 假设 client.list() 返回的是相对于 webdav_hostname 的文件名或路径
    backups = []
    for item_name in files_on_server:
        # 我们只关心文件名本身是否匹配模式
        base_name = os.path.basename(item_name) 
        if base_name.endswith('.tar.gz') and base_name.startswith(backup_prefix):
            backups.append(base_name) # 存储文件名
except Exception as e:
    print(f'错误: 无法列出 WebDAV 目录 ({webdav_hostname}) 内容: {e}')
    print('请检查 WebDAV URL、路径、凭据以及服务端是否正确响应 LIST 请求。')
    sys.exit(1) # 列出失败是严重错误

if not backups:
    print(f'在 WebDAV 上没有找到符合条件的备份文件 ({backup_prefix}*.tar.gz)。')
    if os.path.exists(db_file_path):
        print(f'本地数据库 {db_file_path} 已存在，将使用现有数据库。')
    else:
        print(f'本地数据库 {db_file_path} 未找到。应用将作为全新实例启动。')
    return # 允许应用启动

# 按文件名排序找到最新的备份 (文件名中的时间戳应确保正确排序)
latest_backup_filename = sorted(backups)[-1]
print(f'找到的最新备份文件：{latest_backup_filename}')

# 构建完整的下载 URL
download_url = f'{webdav_hostname.rstrip(\"/\")}/{latest_backup_filename}'
temp_local_backup_file = f'/tmp/{latest_backup_filename}'

print(f'正在下载 {download_url} 到 {temp_local_backup_file} ...')
try:
    with requests.get(download_url, auth=(webdav_login, webdav_password), stream=True) as r:
        r.raise_for_status() # 如果 HTTP 请求返回错误状态码，则抛出异常
        with open(temp_local_backup_file, 'wb') as f:
            for chunk in r.iter_content(chunk_size=8192):
                f.write(chunk)
    print(f'成功下载备份文件到 {temp_local_backup_file}')
except requests.exceptions.RequestException as e:
    print(f'错误: 下载备份文件 {latest_backup_filename} 失败: {e}')
    if os.path.exists(temp_local_backup_file): os.remove(temp_local_backup_file) # 清理部分下载的文件
    if os.path.exists(db_file_path):
        print(f'将使用本地已存在的数据库 {db_file_path}。')
        return
    else:
        print('由于下载失败且本地无数据库，恢复操作无法继续。')
        sys.exit(1)

# 解压备份文件
temp_restore_dir = '/tmp/restore_one_api_db'
if os.path.exists(temp_restore_dir): # 清理旧的临时解压目录
    shutil.rmtree(temp_restore_dir)
os.makedirs(temp_restore_dir, exist_ok=True)

print(f'正在解压 {temp_local_backup_file} 到 {temp_restore_dir}...')
try:
    with tarfile.open(temp_local_backup_file, 'r:gz') as tar:
        tar.extractall(path=temp_restore_dir)
    print('解压完成。')
except tarfile.TarError as e:
    print(f'错误: 解压备份文件 {temp_local_backup_file} 失败: {e}')
    shutil.rmtree(temp_restore_dir)
    os.remove(temp_local_backup_file)
    if os.path.exists(db_file_path):
        print(f'将使用本地已存在的数据库 {db_file_path}。')
        return
    else:
        print('由于解压失败且本地无数据库，恢复操作无法继续。')
        sys.exit(1)

# 在解压内容中查找数据库文件
extracted_db_found_path = None
for root, dirs, files in os.walk(temp_restore_dir):
    if db_file_name in files:
        extracted_db_found_path = os.path.join(root, db_file_name)
        break

if extracted_db_found_path:
    print(f'在备份中找到数据库文件: {extracted_db_found_path}')
    try:
        # 移动 (覆盖) 数据库文件到最终位置
        shutil.move(extracted_db_found_path, db_file_path)
        print(f'成功从备份 {latest_backup_filename} 恢复数据库到 {db_file_path}')
    except Exception as e:
        print(f'错误: 移动恢复的数据库文件到 {db_file_path} 失败: {e}')
        sys.exit(1) # 无法放置DB文件是严重错误
else:
    print(f'警告: 在备份文件 {latest_backup_filename} 的内容中未找到目标数据库文件 {db_file_name}。')
    # 如果本地已有数据库，则保留；否则应用将全新启动
    if os.path.exists(db_file_path):
        print(f'将使用本地已存在的数据库 {db_file_path}。')

# 清理临时文件和目录
print('清理临时备份文件和目录...')
try:
    if os.path.exists(temp_restore_dir): shutil.rmtree(temp_restore_dir)
    if os.path.exists(temp_local_backup_file): os.remove(temp_local_backup_file)
    print('临时文件清理完毕。')
except Exception as e:
    print(f'警告: 删除临时文件/目录时出错: {e}')
"
    # 检查 Python 脚本的退出状态码
    if [ $? -ne 0 ]; then
        echo "错误: Python 恢复脚本执行失败。请检查以上日志。容器将退出。"
        exit 1 # 如果 Python 脚本指示严重错误，则退出容器
    fi
    echo "数据恢复检查完成。"
}

# 函数：定期同步数据到 WebDAV
sync_data() {
    while true; do
        # 从环境变量获取同步间隔，默认为 600 秒 (10分钟)
        SYNC_INTERVAL=${SYNC_INTERVAL:-600}
        echo "下次 WebDAV 同步将在 ${SYNC_INTERVAL} 秒后进行..."
        sleep "$SYNC_INTERVAL"

        echo "-----------------------------------------------------"
        echo "[$(date)] 开始数据同步到 WebDAV..."

        if [ ! -f "$DB_FILE_PATH" ]; then
            echo "[$(date)] 数据库文件 $DB_FILE_PATH 未找到，跳过本次同步。"
            echo "-----------------------------------------------------"
            continue
        fi

        timestamp=$(date +%Y%m%d_%H%M%S)
        CURRENT_BACKUP_FILENAME="${BACKUP_FILE_PREFIX}${timestamp}.tar.gz"
        TEMP_LOCAL_TAR_PATH="/tmp/${CURRENT_BACKUP_FILENAME}"

        echo "正在将数据库文件 $DB_FILE_PATH 打包到 $TEMP_LOCAL_TAR_PATH..."
        # 使用 -C 选项来改变 tar 的工作目录，这样压缩包内不包含 /data/ 路径层级
        if tar -czf "$TEMP_LOCAL_TAR_PATH" -C "$(dirname "$DB_FILE_PATH")" "$DB_FILE_NAME"; then
            echo "数据库文件打包成功: $TEMP_LOCAL_TAR_PATH"
        else
            echo "错误: 打包数据库文件 $DB_FILE_PATH 失败。"
            rm -f "$TEMP_LOCAL_TAR_PATH" # 清理可能产生的损坏的tar文件
            echo "-----------------------------------------------------"
            continue # 跳过此轮同步
        fi

        # 构建 WebDAV 上的完整备份文件路径
        REMOTE_BACKUP_FULL_URL_PATH="${FULL_WEBDAV_URL%/}/${CURRENT_BACKUP_FILENAME}"
        echo "正在上传 $CURRENT_BACKUP_FILENAME 到 $REMOTE_BACKUP_FULL_URL_PATH..."
        
        # 使用 curl 上传，--fail 使其在 HTTP 错误时返回非零退出码
        if curl --fail -u "$WEBDAV_USERNAME:$WEBDAV_PASSWORD" -T "$TEMP_LOCAL_TAR_PATH" "$REMOTE_BACKUP_FULL_URL_PATH"; then
            echo "成功将 ${CURRENT_BACKUP_FILENAME} 上传到 WebDAV。"
        else
            upload_exit_code=$?
            echo "错误: 上传 ${CURRENT_BACKUP_FILENAME} 到 WebDAV 失败。Curl 退出码: $upload_exit_code"
            # 上传失败，保留本地 tar 文件供调试，下次循环会重新尝试或创建新的
            # rm -f "$TEMP_LOCAL_TAR_PATH" 
            echo "-----------------------------------------------------"
            continue # 跳过旧备份清理，下次再试
        fi
        
        # 上传成功后删除本地临时 tar 文件
        rm -f "$TEMP_LOCAL_TAR_PATH"

        echo "开始清理 WebDAV 上的旧备份 (保留最新的 $MAX_BACKUPS_TO_KEEP 个)..."
        python3 -c "
import sys
import os
from webdav3.client import Client

webdav_hostname = '$FULL_WEBDAV_URL'
webdav_login = '$WEBDAV_USERNAME'
webdav_password = '$WEBDAV_PASSWORD'
backup_prefix = '$BACKUP_FILE_PREFIX'
max_backups = int('$MAX_BACKUPS_TO_KEEP')

options = {
    'webdav_hostname': webdav_hostname,
    'webdav_login':    webdav_login,
    'webdav_password': webdav_password
}
client = Client(options)

try:
    files_on_server = client.list()
    backups = []
    for item_name in files_on_server:
        base_name = os.path.basename(item_name)
        if base_name.endswith('.tar.gz') and base_name.startswith(backup_prefix):
            backups.append(base_name)
    backups.sort() # 按文件名 (时间戳) 排序
except Exception as e:
    print(f'错误: 无法列出 WebDAV 目录内容进行清理: {e}')
    # 非致命错误，仅跳过本次清理
    sys.exit(0) 

if len(backups) > max_backups:
    to_delete_count = len(backups) - max_backups
    print(f'找到 {len(backups)} 个备份, 将删除最旧的 {to_delete_count} 个...')
    for i in range(to_delete_count):
        file_to_delete = backups[i] # backups 已排序，最旧的在前面
        print(f'正在删除旧备份: {file_to_delete} ...')
        try:
            # client.clean() 需要的是相对于 webdav_hostname 的路径/文件名
            client.clean(file_to_delete) 
            print(f'成功删除 {file_to_delete}。')
        except Exception as e:
            print(f'删除 {file_to_delete} 失败: {e}')
else:
    print(f'找到 {len(backups)} 个备份，无需清理 (配置保留 {max_backups} 个)。')
"
        echo "[$(date)] 数据同步完成。"
        echo "-----------------------------------------------------"
    done
}

# --- 脚本主逻辑 ---

# 1. 执行首次启动时的数据恢复 (如果WebDAV已配置)
echo "正在检查是否需要从 WebDAV 恢复数据..."
restore_backup # 此函数已包含WebDAV配置检查的早期退出逻辑

# 2. 后台启动定期数据同步进程 (如果WebDAV已配置)
echo "启动后台数据同步到 WebDAV 的进程..."
sync_data &

# 3. 启动主应用程序 (one-api)
echo "启动 one-api 程序..."
# 使用 exec 将使 one-api 进程替换 shell 进程，这是容器中运行主服务的推荐方式
exec /one-api "$@"