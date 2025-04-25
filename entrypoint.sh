#!/bin/bash

# 确保在 /data 目录下工作，虽然 WORKDIR 应该已经设置了
cd /data || exit 1

echo "容器启动 - 执行初始化脚本..."
echo "工作目录: $(pwd)"

# --- 函数定义 ---

# 生成校验和文件
generate_sum() {
    local file=$1
    local sum_file=$2
    # 使用 /data 绝对路径
    sha256sum "/data/$file" > "/data/$sum_file"
}

# 同步函数 (后台运行)
sync_data() {
    echo "后台同步进程启动..."
    while true; do
        echo "[Sync] 开始同步检查..."
        HOUR=$(date +%H)
        DB_FILE="/data/one-api.db"
        SUM_FILE_CURRENT="/data/one-api.db.sha256"
        SUM_FILE_NEW="/data/one-api.db.sha256.new"

        if [ -f "$DB_FILE" ]; then
            # 生成新的校验和
            generate_sum "one-api.db" "one-api.db.sha256.new"

            # 检查文件是否变化
            if [ ! -f "$SUM_FILE_CURRENT" ] || ! cmp -s "$SUM_FILE_NEW" "$SUM_FILE_CURRENT"; then
                echo "[Sync] 检测到 $DB_FILE 变化，开始同步..."
                mv "$SUM_FILE_NEW" "$SUM_FILE_CURRENT"

                # 同步到WebDAV
                if [ ! -z "$WEBDAV_URL" ] && [ ! -z "$WEBDAV_USERNAME" ] && [ ! -z "$WEBDAV_PASSWORD" ]; then
                    echo "[Sync] 同步到 WebDAV ($WEBDAV_URL)..."
                    curl -L -T "$DB_FILE" --user "$WEBDAV_USERNAME:$WEBDAV_PASSWORD" "$WEBDAV_URL/one-api.db" && {
                        echo "[Sync] WebDAV 更新成功"

                        # 每日备份 (仅在 WebDAV 更新成功后检查)
                        if [ "$HOUR" = "00" ]; then
                            echo "[Sync] 当前时间为午夜，开始每日备份..."
                            YESTERDAY=$(date -d "yesterday" '+%Y%m%d')
                            FILENAME_DAILY="one-api_${YESTERDAY}.db"

                            # WebDAV 每日备份
                            echo "[Sync] 备份到 WebDAV: $FILENAME_DAILY..."
                            curl -L -T "$DB_FILE" --user "$WEBDAV_USERNAME:$WEBDAV_PASSWORD" "$WEBDAV_URL/$FILENAME_DAILY" && {
                                echo "[Sync] WebDAV 日期备份成功: $FILENAME_DAILY"

                                # GitHub 每日备份 (仅在 WebDAV 日期备份成功后)
                                if [ ! -z "$G_NAME" ] && [ ! -z "$G_TOKEN" ]; then
                                    echo "[Sync] 开始 GitHub 每日备份 (仓库: $G_NAME)..."
                                    # 使用 x-access-token 进行认证，适用于 GitHub PAT
                                    REPO_URL="https://x-access-token:${G_TOKEN}@github.com/${G_NAME}.git"
                                    TEMP_DIR="/data/temp_git_clone_sync"
                                    rm -rf "$TEMP_DIR" # 清理旧目录

                                    # 使用 --depth 1 加速克隆
                                    git clone --depth 1 "$REPO_URL" "$TEMP_DIR" && {
                                        echo "[Sync] GitHub 仓库克隆成功"
                                        cd "$TEMP_DIR" || exit 1 # 进入临时目录

                                        # 配置 Git 用户信息
                                        git config user.name "AutoSync Bot"
                                        git config user.email "autosync@bot.com"

                                        # 尝试切换到 main 或 master 分支
                                        git checkout main || git checkout master || echo "[Sync][Warn] 无法切换到 main 或 master 分支"

                                        # 复制数据库文件
                                        cp "$DB_FILE" ./one-api.db

                                        # 检查是否有变动，然后添加、提交、推送
                                        if git status --porcelain | grep -q "one-api.db"; then
                                            git add one-api.db
                                            git commit -m "Auto sync one-api.db for ${YESTERDAY}"
                                            git push origin HEAD && echo "[Sync] GitHub 推送成功" || echo "[Sync][Error] GitHub 推送失败"
                                        else
                                            echo "[Sync] GitHub: one-api.db 无数据变化，无需推送"
                                        fi

                                        cd /data # 返回工作目录
                                        rm -rf "$TEMP_DIR" # 清理临时目录
                                    } || {
                                        echo "[Sync][Error] GitHub 克隆失败: $REPO_URL"
                                        rm -rf "$TEMP_DIR" # 确保清理
                                    }
                                fi # End GitHub backup check
                            } || echo "[Sync][Error] WebDAV 日期备份失败: $FILENAME_DAILY" # End WebDAV daily backup success
                        fi # End daily backup hour check
                    } || { # WebDAV 主文件上传失败
                        echo "[Sync][Error] WebDAV 上传失败, 10秒后重试..."
                        sleep 10
                        curl -L -T "$DB_FILE" --user "$WEBDAV_USERNAME:$WEBDAV_PASSWORD" "$WEBDAV_URL/one-api.db" || echo "[Sync][Error] WebDAV 重试失败"
                    }
                else
                     echo "[Sync] 未配置 WebDAV，跳过上传"
                fi # End WebDAV configured check
            else
                echo "[Sync] $DB_FILE 未发生变化，跳过同步"
                rm -f "$SUM_FILE_NEW" # 清理未改变的校验和文件
            fi # End file changed check
        else
            echo "[Sync] 未找到 $DB_FILE, 跳过本次同步检查"
        fi # End one-api.db exists check

        # 获取同步间隔，默认为 300 秒 (5 分钟)
        raw_interval="${SYNC_INTERVAL:-300}"
        interval=300 # Default value if validation fails

        # 验证是否为正整数 (大于0的整数)
        if [[ "$raw_interval" =~ ^[1-9][0-9]*$ ]]; then
            interval="$raw_interval"
        elif [ "$raw_interval" != "300" ]; then # 如果用户显式设置了但无效，发出警告
            echo "[Sync][Warn] SYNC_INTERVAL ('$raw_interval') 不是一个有效的正整数。将使用默认间隔 300 秒。"
        fi

        echo "[Sync] 同步检查完成。当前时间: $(date '+%Y-%m-%d %H:%M:%S')"
        # 使用 date 命令动态计算下次执行时间 (-d "+N seconds" 在 alpine 的 date (coreutils) 中可用)
        next_sync_time=$(date -d "+${interval} seconds" '+%Y-%m-%d %H:%M:%S')
        echo "[Sync] 下次同步检查将在 ${interval} 秒后进行 (${next_sync_time})。"

        sleep "$interval"
    done
}

# --- 启动时数据恢复 ---

# 确保 /data 目录存在 (虽然 WORKDIR 应该处理，但显式创建无害)
mkdir -p /data

if [ ! -z "$WEBDAV_URL" ] && [ ! -z "$WEBDAV_USERNAME" ] && [ ! -z "$WEBDAV_PASSWORD" ]; then
    echo "[Init] 检测到 WebDAV 配置，尝试恢复 one-api.db ..."
    # 使用 --fail 使 curl 在 HTTP 错误时返回非零退出码
    curl -L --fail --user "$WEBDAV_USERNAME:$WEBDAV_PASSWORD" "$WEBDAV_URL/one-api.db" -o "/data/one-api.db" && {
        echo "[Init] 从 WebDAV 恢复 one-api.db 成功"
    } || {
        echo "[Init] 从 WebDAV 恢复失败 (可能文件不存在或认证错误)"
        # WebDAV 失败后，尝试 GitHub
        if [ ! -z "$G_NAME" ] && [ ! -z "$G_TOKEN" ]; then
            echo "[Init] WebDAV 失败，尝试从 GitHub 恢复 (仓库: $G_NAME)..."
            REPO_URL="https://x-access-token:${G_TOKEN}@github.com/${G_NAME}.git"
            TEMP_DIR="/data/temp_git_clone_recover"
            rm -rf "$TEMP_DIR"

            git clone --depth 1 "$REPO_URL" "$TEMP_DIR" && {
                if [ -f "$TEMP_DIR/one-api.db" ]; then
                    mv "$TEMP_DIR/one-api.db" "/data/one-api.db"
                    echo "[Init] 从 GitHub 仓库恢复 one-api.db 成功"
                    rm -rf "$TEMP_DIR"
                else
                    echo "[Init] GitHub 仓库中未找到 one-api.db 文件"
                    rm -rf "$TEMP_DIR"
                fi
            } || {
                 echo "[Init][Error] 从 GitHub 克隆失败: $REPO_URL"
                 rm -rf "$TEMP_DIR"
            }
        else
            echo "[Init] WebDAV 恢复失败，且未配置 GitHub 恢复信息"
        fi
    }
else
    echo "[Init] 未配置 WebDAV, 跳过启动时的数据恢复"
fi

echo "[Init] 初始化恢复逻辑执行完毕。"

# --- 启动后台同步任务 ---
echo "[Init] 启动后台数据同步任务 (sync_data &)..."
sync_data &
SYNC_PID=$!
echo "[Init] 后台同步任务 PID: $SYNC_PID"

# --- 启动主应用程序 ---
echo "[Init] 启动主应用程序: /one-api ..."
# 使用 exec 将 shell 进程替换为 one-api 进程
# "$@" 会将传递给 entrypoint.sh 的所有参数传递给 /one-api
exec /one-api "$@"

# exec 后面的代码不会执行
echo "[Error] 如果你看到这条消息，说明 exec /one-api 失败了！"
exit 1