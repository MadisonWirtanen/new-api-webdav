#!/bin/bash

# 定义常量和变量
DB_FILE="./data/one-api.db"               # 数据库文件路径
DB_SUM_FILE="${DB_FILE}.sha256"           # 数据库校验和文件路径
DB_SUM_NEW_FILE="${DB_SUM_FILE}.new"      # 新生成的校验和临时文件路径
BACKUP_FILENAME_PREFIX="one-api"          # 备份文件名前缀
BACKUP_FILE_EXTENSION="db"                # 备份文件扩展名
DATA_DIR="./data"                         # 数据目录
TEMP_DIR_PREFIX="sync_temp_"              # 临时目录前缀

# 确保数据目录存在
mkdir -p "$DATA_DIR"
# 切换到工作目录，确保所有相对路径正确
cd "$DATA_DIR" || exit 1

# --- 函数定义 ---

# 生成校验和文件
generate_sum() {
    local file=$1
    local sum_file=$2
    # 确保文件存在才生成校验和
    if [ -f "$file" ]; then
        sha256sum "$file" > "$sum_file"
        return 0
    else
        return 1
    fi
}

# --- 启动时数据恢复逻辑 ---
echo "容器启动，检查数据恢复..."
if [ ! -z "$WEBDAV_URL" ] && [ ! -z "$WEBDAV_USERNAME" ] && [ ! -z "$WEBDAV_PASSWORD" ]; then
    echo "尝试从WebDAV恢复 ${BACKUP_FILENAME_PREFIX}.${BACKUP_FILE_EXTENSION}..."
    # 下载到当前目录 (.) 即 /data
    curl -L --fail --user "$WEBDAV_USERNAME:$WEBDAV_PASSWORD" "$WEBDAV_URL/${BACKUP_FILENAME_PREFIX}.${BACKUP_FILE_EXTENSION}" -o "./${BACKUP_FILENAME_PREFIX}.${BACKUP_FILE_EXTENSION}" && {
        echo "从WebDAV恢复数据成功"
    } || {
        echo "从WebDAV恢复失败或文件不存在。"
        if [ ! -z "$G_NAME" ] && [ ! -z "$G_TOKEN" ]; then
            echo "尝试从GitHub恢复 ${BACKUP_FILENAME_PREFIX}.${BACKUP_FILE_EXTENSION}..."
            REPO_URL="https://${G_TOKEN}@github.com/${G_NAME}.git"
            # 创建一个唯一的临时克隆目录
            TEMP_CLONE_DIR=$(mktemp -d -p "$(pwd)" "${TEMP_DIR_PREFIX}XXXXXX")
            if git clone --depth 1 "$REPO_URL" "$TEMP_CLONE_DIR"; then
                if [ -f "${TEMP_CLONE_DIR}/${BACKUP_FILENAME_PREFIX}.${BACKUP_FILE_EXTENSION}" ]; then
                    # 从临时目录移动恢复的文件到当前目录 (/data)
                    mv "${TEMP_CLONE_DIR}/${BACKUP_FILENAME_PREFIX}.${BACKUP_FILE_EXTENSION}" "./${BACKUP_FILENAME_PREFIX}.${BACKUP_FILE_EXTENSION}"
                    echo "从GitHub仓库恢复成功"
                else
                    echo "GitHub仓库中未找到 ${BACKUP_FILENAME_PREFIX}.${BACKUP_FILE_EXTENSION}"
                fi
                # 清理临时目录
                rm -rf "$TEMP_CLONE_DIR"
            else
                echo "GitHub克隆失败"
                # 清理失败的临时目录
                rm -rf "$TEMP_CLONE_DIR"
            fi
        else
            echo "未配置GitHub, 跳过GitHub恢复"
        fi
    }
else
    echo "未配置WebDAV, 跳过数据恢复"
fi
echo "数据恢复检查完成。"

# --- 后台同步函数 ---
sync_data() {
    echo "启动后台数据同步循环..."
    while true; do
        echo "[同步检查] 开始检查 ${DB_FILE}..."
        # DB_FILE 需要相对于当前目录（/data）
        local current_db_file="./${BACKUP_FILENAME_PREFIX}.${BACKUP_FILE_EXTENSION}"
        local current_sum_file="${current_db_file}.sha256"
        local current_sum_new_file="${current_sum_file}.new"

        if [ -f "$current_db_file" ]; then
            # 生成新的校验和
            generate_sum "$current_db_file" "$current_sum_new_file"

            # 检查文件是否变化 (校验和文件不存在或内容不同)
            if [ ! -f "$current_sum_file" ] || ! cmp -s "$current_sum_new_file" "$current_sum_file"; then
                echo "[同步] 检测到 ${current_db_file} 文件变化，开始同步..."

                # 同步到WebDAV (如果配置了)
                if [ ! -z "$WEBDAV_URL" ] && [ ! -z "$WEBDAV_USERNAME" ] && [ ! -z "$WEBDAV_PASSWORD" ]; then
                    echo "[同步] 上传 ${current_db_file} 到 WebDAV..."
                    # 使用 curl 上传当前目录下的文件
                    if curl --connect-timeout 15 -L -T "$current_db_file" --user "$WEBDAV_USERNAME:$WEBDAV_PASSWORD" "$WEBDAV_URL/${BACKUP_FILENAME_PREFIX}.${BACKUP_FILE_EXTENSION}"; then
                        echo "[同步] WebDAV更新成功"
                        # 更新校验和文件
                        mv "$current_sum_new_file" "$current_sum_file"

                        # 检查是否需要每日备份 (每天0点)
                        local HOUR=$(date +%H)
                        if [ "$HOUR" = "00" ]; then
                            echo "[同步] 开始每日备份 (0点)..."
                            local YESTERDAY=$(date -d "yesterday" '+%Y%m%d')
                            local FILENAME_DAILY="${BACKUP_FILENAME_PREFIX}_${YESTERDAY}.${BACKUP_FILE_EXTENSION}"

                            # WebDAV 每日备份
                            echo "[同步] 备份 ${FILENAME_DAILY} 到 WebDAV..."
                            if curl --connect-timeout 15 -L -T "$current_db_file" --user "$WEBDAV_USERNAME:$WEBDAV_PASSWORD" "$WEBDAV_URL/$FILENAME_DAILY"; then
                                echo "[同步] WebDAV日期备份成功: $FILENAME_DAILY"

                                # GitHub 每日备份 (如果配置了)
                                if [ ! -z "$G_NAME" ] && [ ! -z "$G_TOKEN" ]; then
                                    echo "[同步] 开始GitHub每日备份..."
                                    local REPO_URL="https://${G_TOKEN}@github.com/${G_NAME}.git"
                                    # 在当前目录(/data)下创建临时目录
                                    local TEMP_CLONE_DIR=$(mktemp -d -p "$(pwd)" "${TEMP_DIR_PREFIX}XXXXXX")
                                    if git clone --depth 1 "$REPO_URL" "$TEMP_CLONE_DIR"; then
                                        # 进入临时目录进行 git 操作
                                        ( # 使用子shell确保操作后能返回原目录
                                            cd "$TEMP_CLONE_DIR" || exit 1
                                            git config user.name "AutoSync Bot"
                                            git config user.email "autosync@bot.com"
                                            # 确定默认分支名 (main 或 master)
                                            local MAIN_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD | sed 's@^refs/remotes/origin/@@')
                                            git checkout "$MAIN_BRANCH"
                                            # 从父目录(/data)复制当前数据库文件到仓库
                                            cp "../${current_db_file}" "./${BACKUP_FILENAME_PREFIX}.${BACKUP_FILE_EXTENSION}"

                                            # 检查是否有变动需要提交
                                            if [[ -n $(git status -s) ]]; then
                                                git add "${BACKUP_FILENAME_PREFIX}.${BACKUP_FILE_EXTENSION}"
                                                git commit -m "Auto sync ${BACKUP_FILENAME_PREFIX}.${BACKUP_FILE_EXTENSION} for ${YESTERDAY}"
                                                if git push origin HEAD; then
                                                    echo "[同步] GitHub推送成功"
                                                else
                                                    echo "[同步] GitHub推送失败"
                                                fi
                                            else
                                                echo "[同步] GitHub: 无数据变化，无需推送"
                                            fi
                                        ) # 子shell结束，返回 /data 目录
                                        # 清理临时目录
                                        rm -rf "$TEMP_CLONE_DIR"
                                    else # git clone failed
                                        echo "[同步] GitHub克隆失败 (用于每日备份)"
                                        rm -rf "$TEMP_CLONE_DIR"
                                    fi
                                fi # end github backup check
                            else # webdav daily backup failed
                                echo "[同步] WebDAV日期备份失败: $FILENAME_DAILY"
                            fi # end webdav daily backup check
                        fi # end daily backup time check
                    else # webdav upload failed
                        echo "[同步] WebDAV上传失败, 尝试重试..."
                        sleep 20
                        if curl --connect-timeout 15 -L -T "$current_db_file" --user "$WEBDAV_USERNAME:$WEBDAV_PASSWORD" "$WEBDAV_URL/${BACKUP_FILENAME_PREFIX}.${BACKUP_FILE_EXTENSION}"; then
                            echo "[同步] WebDAV重试更新成功"
                            # 更新校验和文件
                            mv "$current_sum_new_file" "$current_sum_file"
                        else
                            echo "[同步] WebDAV重试失败"
                            # 保留新的校验和文件供下次比较
                            echo "[同步] 保留 ${current_sum_new_file} 用于下次检查"
                        fi
                    fi # end webdav upload attempt
                else # webdav not configured
                     echo "[同步] 未配置WebDAV，仅更新本地校验和文件"
                     # 即使没有远程同步，也要更新校验和文件，以便下次能检测到变化
                     mv "$current_sum_new_file" "$current_sum_file"
                fi # end webdav config check
            else # no change detected
                echo "[同步检查] ${current_db_file} 文件未发生变化，跳过同步"
                # 移除临时生成的新校验和文件
                rm -f "$current_sum_new_file"
            fi # end change detection
        else # db file not found
            echo "[同步检查] 未找到 ${current_db_file}, 跳过本次同步检查"
        fi # end db file exists check

        local current_time=$(date '+%Y-%m-%d %H:%M:%S')
        local next_sync_time=$(date -d '+5 minutes' '+%Y-%m-%d %H:%M:%S')
        echo "[同步检查] 当前时间: $current_time, 下次检查时间: $next_sync_time"
        sleep 300 # 等待5分钟
    done
}

# --- 主逻辑 ---

# 在后台启动同步循环
sync_data &

# 获取后台同步进程的PID
SYNC_PID=$!
echo "后台同步进程已启动 (PID: $SYNC_PID)"

# 使用 exec 启动主应用程序 (/one-api)
# "$@" 会将传递给 entrypoint.sh 的所有参数原样传递给 /one-api
echo "启动 one-api 主服务..."
exec /one-api "$@"

# exec 执行后，当前脚本进程被 one-api 进程替换
# 当 one-api 退出时，容器将停止，后台的 sync_data 进程也会被终止