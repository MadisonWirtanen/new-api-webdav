#!/bin/bash
set -e # 如果任何命令以非零状态退出，则立即退出脚本。

# --- 配置 ---
DB_FILE="one-api.db" # 数据库文件名 (相对于工作目录 /data)
BACKUP_PREFIX="oneapi_backup_" # 备份文件名前缀
BACKUP_SUFFIX=".tar.gz" # 备份文件名后缀
TMP_DIR="/tmp" # 用于下载和存档的临时目录
KEEP_BACKUPS=5 # 在 WebDAV 上保留的备份数量 (根据需要调整)

# --- 辅助函数 ---
log() {
    # 将带时间戳的消息记录到标准输出
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

# 构造完整的 WebDAV URL，处理可选路径以及开头/结尾的斜杠
get_full_webdav_url() {
    local base_url="$WEBDAV_URL"
    local backup_path="${WEBDAV_BACKUP_PATH:-}" # 如果未设置则使用空字符串

    # 如果基础 URL 未设置，则无法继续
    if [[ -z "$base_url" ]]; then
        echo "" # 返回空字符串表示失败/无法构造
        return
    fi

    # 移除基础 URL 末尾可能存在的斜杠
    local url_stripped=$(echo "$base_url" | sed 's:/*$::')

    # 如果提供了备份路径，则处理它
    if [[ -n "$backup_path" ]]; then
        # 移除路径开头和末尾可能存在的斜杠
        local path_stripped=$(echo "$backup_path" | sed 's:^/*::' | sed 's:/*$::')
        # 仅当处理后的路径不为空时才追加
        if [[ -n "$path_stripped" ]]; then
            echo "${url_stripped}/${path_stripped}"
        else
            # 如果备份路径只是斜杠或为空，则返回基础 URL
            echo "${url_stripped}"
        fi
    else
        # 如果没有备份路径，则只返回处理后的基础 URL
        echo "${url_stripped}"
    fi
}

# --- 恢复逻辑 ---
restore_backup() {
    # 检查必需的 WebDAV 环境变量
    if [[ -z "$WEBDAV_URL" ]] || [[ -z "$WEBDAV_USERNAME" ]] || [[ -z "$WEBDAV_PASSWORD" ]]; then
        log "缺少 WebDAV 环境变量 (WEBDAV_URL, WEBDAV_USERNAME, WEBDAV_PASSWORD)，跳过启动时恢复备份。"
        return # 跳过恢复，不退出脚本
    fi

    # 使用辅助函数构造完整的 WebDAV URL
    FULL_WEBDAV_URL=$(get_full_webdav_url)
    if [[ -z "$FULL_WEBDAV_URL" ]]; then
         log "[错误] 无法构造有效的 WebDAV URL，跳过恢复。"
         return
    fi

    log "开始尝试从 WebDAV ($FULL_WEBDAV_URL) 下载并恢复最新 '${BACKUP_PREFIX}*${BACKUP_SUFFIX}' 备份..."

    # 导出 Python 脚本所需的变量
    export FULL_WEBDAV_URL WEBDAV_USERNAME WEBDAV_PASSWORD
    export DB_FILE BACKUP_PREFIX BACKUP_SUFFIX TMP_DIR

    # 执行 Python 脚本进行恢复逻辑
    python3 -c "
import sys
import os
import tarfile
import requests
from webdav3.client import Client
import shutil
import logging

# 为 Python 脚本设置基本日志记录
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - PythonRestore - %(message)s')

# 从环境变量检索配置
webdav_url = os.environ.get('FULL_WEBDAV_URL')
webdav_user = os.environ.get('WEBDAV_USERNAME')
webdav_pass = os.environ.get('WEBDAV_PASSWORD')
db_filename = os.environ.get('DB_FILE')
backup_prefix = os.environ.get('BACKUP_PREFIX')
backup_suffix = os.environ.get('BACKUP_SUFFIX')
tmp_dir = os.environ.get('TMP_DIR', '/tmp')
# 目标目录是 Dockerfile 的 WORKDIR 设置的当前工作目录 (应该是 /data)
target_dir = '.'

# 验证必需的变量
if not all([webdav_url, webdav_user, webdav_pass, db_filename, backup_prefix, backup_suffix]):
    logging.error('Python 脚本缺少必要的环境变量。')
    sys.exit(1)

# WebDAV 客户端选项
options = {
    'webdav_hostname': webdav_url,
    'webdav_login':    webdav_user,
    'webdav_password': webdav_pass,
    'verify_ssl': True # 默认为 True，以后可能需要配置
}

latest_backup = None # 存储在 WebDAV 上找到的最新备份的路径
local_tmp_backup_path = None # 存储备份下载到的本地路径
temp_extract_dir = os.path.join(tmp_dir, 'oneapi_restore_temp') # 用于解压的临时目录

try:
    # 初始化 WebDAV 客户端
    client = Client(options)
    logging.info(f'尝试连接到 WebDAV: {webdav_url}')
    # 执行简单的列表操作以测试连接和凭据
    client.ls()
    logging.info('WebDAV 连接成功.')

    logging.info(f'查找备份文件 (前缀: {backup_prefix}, 后缀: {backup_suffix})...')
    # 列出 WebDAV 上目标目录中的文件
    files_on_server = client.list() # 返回相对于 webdav_hostname 的路径列表

    # 根据基本名称过滤列表以查找相关的备份文件
    backups = [f for f in files_on_server if os.path.basename(f).startswith(backup_prefix) and f.endswith(backup_suffix)]

    # 如果未找到备份，则记录警告并正常退出 (不是错误)
    if not backups:
        logging.warning('在 WebDAV 上没有找到匹配的备份文件。')
        sys.exit(0)

    # 按基本名称对备份进行排序 (假设时间戳格式使字母排序按时间顺序工作)
    backups.sort(key=lambda f: os.path.basename(f))
    latest_backup = backups[-1] # 获取最新备份的完整路径
    latest_backup_basename = os.path.basename(latest_backup)
    logging.info(f'找到最新备份文件: {latest_backup} (Basename: {latest_backup_basename})')

    # 定义本地下载路径
    local_tmp_backup_path = os.path.join(tmp_dir, latest_backup_basename)

    # 下载最新的备份文件
    logging.info(f'开始下载 {latest_backup} 到 {local_tmp_backup_path}')
    client.download_sync(remote_path=latest_backup, local_path=local_tmp_backup_path)
    logging.info(f'成功下载备份文件.')

    # 验证下载成功
    if not os.path.exists(local_tmp_backup_path):
         logging.error('下载的备份文件未在本地找到。')
         sys.exit(1)

    # 解压下载的备份存档
    os.makedirs(temp_extract_dir, exist_ok=True) # 确保解压目录存在
    logging.info(f'解压备份文件 {local_tmp_backup_path} 到 {temp_extract_dir}')
    try:
        with tarfile.open(local_tmp_backup_path, 'r:gz') as tar:
            # 安全性：在解压前检查路径
            for member in tar.getmembers():
                member_path = os.path.join(temp_extract_dir, member.name)
                # 将路径解析为绝对路径以防止遍历攻击
                abs_member_path = os.path.abspath(member_path)
                abs_temp_extract_dir = os.path.abspath(temp_extract_dir)
                # 确保解压后的路径在指定的临时目录内
                if not abs_member_path.startswith(abs_temp_extract_dir):
                     raise tarfile.TarError(f'不安全的压缩文件成员路径 (尝试跳出目录): {member.name}')
                # 检查成员是否是文件再解压 (可选，根据需要)
                if member.isfile():
                    tar.extract(member, path=temp_extract_dir) # 将成员解压到 temp_extract_dir
        logging.info(f'成功解压备份文件.')
    except tarfile.TarError as e:
        logging.error(f'解压备份文件时出错: {e}')
        # 在解压错误退出前进行清理
        if os.path.exists(local_tmp_backup_path): os.remove(local_tmp_backup_path)
        if os.path.exists(temp_extract_dir): shutil.rmtree(temp_extract_dir)
        sys.exit(1)

    # 在解压内容中查找数据库文件
    # 常见模式：直接在根目录，或在子目录中 (如 'data')
    extracted_db_path = None
    possible_paths = [
        os.path.join(temp_extract_dir, db_filename), # 例如 /tmp/oneapi_restore_temp/one-api.db
        os.path.join(temp_extract_dir, 'data', db_filename) # 例如 /tmp/oneapi_restore_temp/data/one-api.db
    ]
    for path_to_check in possible_paths:
        if os.path.isfile(path_to_check):
            extracted_db_path = path_to_check
            logging.info(f'在解压内容中找到数据库文件: {extracted_db_path}')
            break

    # 如果找到数据库文件，则将其移动到目标位置
    if extracted_db_path:
        target_db_path = os.path.join(target_dir, db_filename) # 例如 ./one-api.db 相对于 WORKDIR
        logging.info(f'准备恢复数据库文件到 {target_db_path}')
        # 尽可能使用 os.replace 进行原子移动/覆盖
        os.replace(extracted_db_path, target_db_path)
        logging.info(f'成功从备份 {latest_backup_basename} 恢复数据库.')
    else:
        # 如果在存档中未找到数据库文件，则记录警告但继续 (应用程序可能会创建一个)
        logging.warning(f'在备份文件 {latest_backup_basename} 的解压内容中未找到 {db_filename}。')

    # 如果全部成功，则以 0 退出
    sys.exit(0)

except Exception as e:
    # 捕获过程中的任何其他异常
    logging.error(f'恢复备份过程中发生意外错误: {e}', exc_info=True) # 记录回溯信息
    sys.exit(1) # 指示失败

finally:
    # 清理：确保删除临时文件和目录
    if local_tmp_backup_path and os.path.exists(local_tmp_backup_path):
        try:
            os.remove(local_tmp_backup_path)
            logging.info(f'已删除临时下载文件 {local_tmp_backup_path}')
        except OSError as e:
            logging.warning(f'删除临时下载文件时出错: {e}')
    if os.path.exists(temp_extract_dir):
        try:
            shutil.rmtree(temp_extract_dir)
            logging.info(f'已删除临时解压目录 {temp_extract_dir}')
        except OSError as e:
            logging.warning(f'删除临时解压目录时出错: {e}')
"
    # 检查 Python 脚本的退出代码
    restore_status=$?
    if [ $restore_status -ne 0 ]; then
        log "[警告] Python 恢复脚本执行失败 (退出码: $restore_status)。请检查日志。One-API 将尝试启动，可能会创建新的数据库。"
        # 此处不要退出主脚本，允许 one-api 尝试启动
    else
        log "恢复过程完成。"
    fi
    # 无论 Python 脚本结果如何 (除非是 'set -e' 处理的致命错误)，继续执行
}


# --- 同步逻辑 (设计为在后台运行) ---
sync_data() {
    # 再次检查 WebDAV 变量，以防它们仅用于同步
    if [[ -z "$WEBDAV_URL" ]] || [[ -z "$WEBDAV_USERNAME" ]] || [[ -z "$WEBDAV_PASSWORD" ]]; then
        log "缺少 WebDAV 环境变量，后台备份功能将不会运行。"
        # 退出此函数，同步不会运行，但主应用程序仍应启动 (如果被调用)
        return
    fi

    # 重新计算完整的 WebDAV URL，以防变量更改或仅为同步设置
    FULL_WEBDAV_URL=$(get_full_webdav_url)
     if [[ -z "$FULL_WEBDAV_URL" ]]; then
         log "[错误] 无法构造有效的 WebDAV URL，后台备份功能将不会运行。"
         return
    fi

    log "后台同步进程启动，目标 WebDAV: $FULL_WEBDAV_URL"
    # 导出循环内清理 Python 脚本所需的变量
    export FULL_WEBDAV_URL WEBDAV_USERNAME WEBDAV_PASSWORD
    export BACKUP_PREFIX BACKUP_SUFFIX KEEP_BACKUPS

    # 用于定期备份的无限循环
    while true; do
        # 从环境获取同步间隔或使用默认值。在循环内检查以适应动态更改。
        SYNC_INTERVAL_SECONDS=${SYNC_INTERVAL:-600} # 默认为 10 分钟 (600 秒)
        # 验证间隔是正整数
        if ! [[ "$SYNC_INTERVAL_SECONDS" =~ ^[0-9]+$ ]] || [ "$SYNC_INTERVAL_SECONDS" -le 0 ]; then
            log "[警告] SYNC_INTERVAL ('$SYNC_INTERVAL_SECONDS') 不是有效的正整数，使用默认值 600 秒。"
            SYNC_INTERVAL_SECONDS=600
        fi
        # 可选：设置最小间隔以防止过度备份
        if [ "$SYNC_INTERVAL_SECONDS" -lt 60 ]; then
             log "[警告] SYNC_INTERVAL ('$SYNC_INTERVAL_SECONDS' 秒) 小于 60 秒，可能过于频繁。已调整为 60 秒。"
             SYNC_INTERVAL_SECONDS=60
        fi

        # 检查数据库文件是否存在于工作目录 (/data) 中
        if [ -f "$DB_FILE" ]; then
            log "发现数据库文件 '$DB_FILE'，开始执行备份..."
            timestamp=$(date +%Y%m%d_%H%M%S) # 为备份文件名生成时间戳
            backup_filename="${BACKUP_PREFIX}${timestamp}${BACKUP_SUFFIX}"
            local_tmp_backup_path="${TMP_DIR}/${backup_filename}" # 本地存档的路径
            remote_backup_path="${FULL_WEBDAV_URL}/${backup_filename}" # curl 上传目标的完整 URL

            # 创建数据库文件的压缩存档
            log "创建备份文件: ${local_tmp_backup_path}"
            # 使用 tar: c=创建, z=gzip压缩, f=文件。相对于当前目录 (/data) 存档 DB_FILE。
            if tar -czf "${local_tmp_backup_path}" "$DB_FILE"; then
                log "成功创建本地备份文件。"

                # 使用 curl 上传创建的存档
                log "上传 ${backup_filename} 到 ${FULL_WEBDAV_URL}"
                # curl 选项:
                # -sS: 静默模式但显示错误
                # --fail: 在 HTTP >= 400 错误时返回非零退出代码
                # -u: 用户名:密码 用于认证
                # -T: 上传指定文件
                # 捕获 curl 可能的错误消息到 stderr
                upload_output=$(curl -sS --fail -u "$WEBDAV_USERNAME:$WEBDAV_PASSWORD" -T "${local_tmp_backup_path}" "${remote_backup_path}" 2>&1)
                upload_status=$?

                # 检查上传状态
                if [ $upload_status -eq 0 ]; then
                    log "成功上传 ${backup_filename}"

                    # 使用 Python 脚本清理 WebDAV 上的旧备份
                    log "清理 WebDAV 上的旧备份 (保留最新的 ${KEEP_BACKUPS} 个)..."
                    python3 -c "
import sys
import os
from webdav3.client import Client
import logging

logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - PythonCleanup - %(message)s')

# 从环境获取配置
webdav_url = os.environ.get('FULL_WEBDAV_URL')
webdav_user = os.environ.get('WEBDAV_USERNAME')
webdav_pass = os.environ.get('WEBDAV_PASSWORD')
backup_prefix = os.environ.get('BACKUP_PREFIX')
backup_suffix = os.environ.get('BACKUP_SUFFIX')
# 确保 KEEP_BACKUPS 是整数
try:
    keep_backups = int(os.environ.get('KEEP_BACKUPS', 5))
    if keep_backups < 0: keep_backups = 0 # 不能保留负数个备份
except ValueError:
    logging.warning('KEEP_BACKUPS 环境变量不是有效的整数，使用默认值 5。')
    keep_backups = 5

if not all([webdav_url, webdav_user, webdav_pass, backup_prefix, backup_suffix]):
    logging.error('Python 清理脚本缺少必要的环境变量。')
    sys.exit(1)

options = {
    'webdav_hostname': webdav_url,
    'webdav_login':    webdav_user,
    'webdav_password': webdav_pass,
    'verify_ssl': True
}

try:
    client = Client(options)
    logging.info(f'连接到 WebDAV ({webdav_url}) 以清理旧备份')
    files_on_server = client.list() # 获取文件/目录列表

    # 按基本名称前缀和后缀过滤备份文件
    backups = [f for f in files_on_server if os.path.basename(f).startswith(backup_prefix) and f.endswith(backup_suffix)]
    # 按基本名称对备份进行排序 (如果时间戳格式可排序，则按时间顺序)
    backups.sort(key=lambda f: os.path.basename(f))

    num_backups = len(backups)
    logging.info(f'找到 {num_backups} 个备份文件。需要保留 {keep_backups} 个。')

    # 确定要删除的备份数量
    if num_backups > keep_backups:
        to_delete_count = num_backups - keep_backups
        logging.info(f'需要删除 {to_delete_count} 个最旧的备份。')
        deleted_count = 0
        # 遍历最旧的备份并删除它们
        for i in range(to_delete_count):
            file_to_delete = backups[i] # 使用 list() 返回的完整路径
            try:
                logging.info(f'删除旧备份: {file_to_delete}')
                client.clean(file_to_delete) # clean() 等同于 delete()
                logging.info(f'成功删除 {file_to_delete}')
                deleted_count += 1
            except Exception as e:
                logging.error(f'删除备份 {file_to_delete} 时出错: {e}')
        logging.info(f'清理完成，成功删除 {deleted_count}/{to_delete_count} 个旧备份。')
    else:
        # 如果数量未超限，则无需删除
        logging.info('备份数量未超过限制，无需清理。')

    sys.exit(0) # 成功

except Exception as e:
    logging.error(f'清理旧备份时发生错误: {e}', exc_info=True)
    sys.exit(1) # 指示失败
                    "
                    cleanup_status=$?
                    if [ $cleanup_status -ne 0 ]; then
                        log "[警告] Python 清理脚本执行失败 (退出码: $cleanup_status)。"
                    fi
                else
                    # 记录上传失败详情
                    log "[错误] 上传 ${backup_filename} 失败 (curl exit code $upload_status)。服务器响应/错误信息: ${upload_output}"
                fi

                # 在尝试上传和清理后删除本地临时备份文件
                log "删除本地临时备份文件: ${local_tmp_backup_path}"
                rm -f "${local_tmp_backup_path}"

            else
                # 记录 tar 命令失败
                log "[错误] 创建 tar 备份文件失败: ${local_tmp_backup_path}"
                # 确保删除可能存在的损坏/部分 tar 文件
                rm -f "${local_tmp_backup_path}"
            fi # 结束 tar 创建成功检查
        else
            # 如果数据库文件不存在则记录日志
            log "数据库文件 '$DB_FILE' 不存在，跳过此次备份。"
        fi

        # 休眠直到下一个同步周期
        log "下次同步检查将在 ${SYNC_INTERVAL_SECONDS} 秒后进行..."
        sleep $SYNC_INTERVAL_SECONDS
    done # while 循环结束
}

# --- 主执行逻辑 ---
log "容器启动脚本 (entrypoint.sh) 开始执行..."

# 步骤 1: 尝试从 WebDAV 恢复最新备份 (在前台运行)
# 此函数内部会检查所需的环境变量。
restore_backup

# 步骤 2: 启动后台同步进程 (如果配置了 WebDAV)
# sync_data 函数内部也会检查环境变量。
sync_data &
SYNC_PID=$! # 捕获后台同步进程的 PID

# 根据同步进程是否已启动记录日志
if kill -0 $SYNC_PID > /dev/null 2>&1; then
    log "后台同步进程已启动 (PID: $SYNC_PID)。"
else
    log "后台同步进程未启动 (可能由于缺少 WebDAV 配置)。"
    SYNC_PID="" # 如果未运行，则清除 SYNC_PID
fi

# 步骤 3: 使用 exec 启动主应用程序 (one-api)
# 'exec' 将当前 shell 进程替换为 '/one-api' 进程。
# 这对于正确的信号处理 (例如，用于优雅关闭的 SIGTERM)至关重要。
# "$@" 将传递给容器的任何命令行参数传递给 one-api 可执行文件。
log "启动 one-api 主程序..."
exec /one-api "$@"

# 如果 'exec /one-api' 失败 (例如，文件未找到，不可执行)，
# 脚本将在此处继续执行。这表示一个严重错误。
EXEC_FAILED_CODE=$?
log "[致命错误] 无法执行 /one-api 程序！退出码: $EXEC_FAILED_CODE"

# 如果后台同步进程已启动，则在退出前尝试终止它
if [ -n "$SYNC_PID" ]; then
    log "由于主程序启动失败，正在尝试停止后台同步进程 (PID: $SYNC_PID)..."
    # 向后台进程发送 SIGTERM 信号
    kill $SYNC_PID
    # 短暂等待进程优雅终止
    wait $SYNC_PID 2>/dev/null
fi

# 使用失败的 exec 尝试的错误代码退出
exit $EXEC_FAILED_CODE