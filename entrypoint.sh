#!/bin/sh

# 增加脚本的健壮性，任何命令失败则退出脚本（除了后台循环）
# set -e # 暂时不加，因为后台循环和某些检查可能需要更灵活的处理

# --- 配置 ---
# 可以通过环境变量覆盖同步间隔 (秒)
SYNC_INTERVAL=${SYNC_INTERVAL:-300}
# 可以通过环境变量禁用同步 (设置为非 "true" 的任何值)
ENABLE_SYNC=${ENABLE_SYNC:-"true"}
# GitHub 临时克隆目录
GIT_TEMP_DIR="./temp_git_clone"
GIT_TEMP_DIR_DAILY="./temp_git_clone_daily"
# 数据库文件名
DB_FILE="one-api.db"
DB_CHECKSUM_FILE="${DB_FILE}.sha256"
DB_CHECKSUM_FILE_NEW="${DB_CHECKSUM_FILE}.new"

# --- 确保依赖存在 ---
echo "检查依赖: curl, git, date, cmp, sha256sum..."
missing_deps=""
for cmd in curl git date cmp sha256sum; do
    if ! command -v $cmd > /dev/null; then
        missing_deps="$missing_deps $cmd"
    fi
done

if [ -n "$missing_deps" ]; then
    echo "错误: 缺少以下依赖项: $missing_deps" >&2
    echo "请确保在 Dockerfile 中通过 'apk add --no-cache curl git' 安装它们 (date, cmp, sha256sum 通常由 busybox 或 coreutils 提供)." >&2
    exit 1
fi
echo "依赖检查通过."


# --- 函数定义 ---

# 生成校验和文件
generate_sum() {
    local file=$1
    local sum_file=$2
    echo "  生成校验和: $file -> $sum_file"
    if [ -f "$file" ]; then
        sha256sum "$file" > "$sum_file"
        return $?
    else
        echo "  错误: 文件 '$file' 不存在，无法生成校验和。" >&2
        return 1
    fi
}

# 同步函数 (后台运行)
sync_data() {
    if [ "$ENABLE_SYNC" != "true" ]; then
        echo "[Sync Process] 同步功能已禁用 (ENABLE_SYNC != 'true'). 进程退出。"
        return
    fi

    echo "[Sync Process] 后台同步进程启动，检查间隔: ${SYNC_INTERVAL} 秒。"
    while true; do
        echo "[Sync $(date '+%Y-%m-%d %H:%M:%S')] 开始检查同步..."

        if [ ! -f "$DB_FILE" ]; then
            echo "[Sync $(date '+%Y-%m-%d %H:%M:%S')] $DB_FILE 未找到，跳过本次同步。"
            sleep "$SYNC_INTERVAL"
            continue # 跳到下一次循环
        fi

        # 生成新的校验和文件
        if ! generate_sum "$DB_FILE" "$DB_CHECKSUM_FILE_NEW"; then
            echo "[Sync $(date '+%Y-%m-%d %H:%M:%S')] 生成新校验和失败，跳过本次同步。"
            sleep "$SYNC_INTERVAL"
            continue
        fi

        # 检查文件是否变化
        should_sync=false
        if [ ! -f "$DB_CHECKSUM_FILE" ]; then
            echo "[Sync $(date '+%Y-%m-%d %H:%M:%S')] 未找到旧校验和文件，视为文件已更改。"
            should_sync=true
        elif ! cmp -s "$DB_CHECKSUM_FILE_NEW" "$DB_CHECKSUM_FILE"; then
            echo "[Sync $(date '+%Y-%m-%d %H:%M:%S')] 检测到文件变化，准备同步..."
            should_sync=true
        else
            echo "[Sync $(date '+%Y-%m-%d %H:%M:%S')] 文件未发生变化。"
            rm -f "$DB_CHECKSUM_FILE_NEW" # 清理未变化的新校验和文件
        fi

        # 如果需要同步
        if $should_sync; then
            echo "[Sync $(date '+%Y-%m-%d %H:%M:%S')] 更新本地校验和文件..."
            mv "$DB_CHECKSUM_FILE_NEW" "$DB_CHECKSUM_FILE"

            # 1. 同步到 WebDAV
            if [ -n "$WEBDAV_URL" ] && [ -n "$WEBDAV_USERNAME" ] && [ -n "$WEBDAV_PASSWORD" ]; then
                echo "[Sync $(date '+%Y-%m-%d %H:%M:%S')] 同步到 WebDAV ($WEBDAV_URL)..."
                if ! curl -f -L -T "$DB_FILE" --user "$WEBDAV_USERNAME:$WEBDAV_PASSWORD" "$WEBDAV_URL/$DB_FILE"; then
                    echo "[Sync $(date '+%Y-%m-%d %H:%M:%S')] WebDAV 上传失败，10秒后重试..." >&2
                    sleep 10
                    if ! curl -f -L -T "$DB_FILE" --user "$WEBDAV_USERNAME:$WEBDAV_PASSWORD" "$WEBDAV_URL/$DB_FILE"; then
                        echo "[Sync $(date '+%Y-%m-%d %H:%M:%S')] WebDAV 重试上传失败。" >&2
                    else
                        echo "[Sync $(date '+%Y-%m-%d %H:%M:%S')] WebDAV 重试上传成功。"
                    fi
                else
                    echo "[Sync $(date '+%Y-%m-%d %H:%M:%S')] WebDAV 上传成功。"
                fi
            else
                echo "[Sync $(date '+%Y-%m-%d %H:%M:%S')] 未配置 WebDAV，跳过同步。"
            fi

            # 2. 每日备份 (约 0 点执行，且当天未执行过)
            HOUR=$(date +%H)
            TODAY=$(date '+%Y%m%d')
            BACKUP_FLAG_FILE="./daily_backup_done_${TODAY}"

            if [ "$HOUR" = "00" ] && [ ! -f "$BACKUP_FLAG_FILE" ]; then
                echo "[Sync $(date '+%Y-%m-%d %H:%M:%S')] 开始每日备份 (日期: $TODAY)..."
                # Alpine date -d 'yesterday' 可能无效，使用 date -d @$(( $(date +%s) - 86400 ))
                YESTERDAY_TS=$(( $(date +%s) - 86400 ))
                YESTERDAY=$(date -d "@$YESTERDAY_TS" '+%Y%m%d')
                FILENAME_DAILY="webui_${YESTERDAY}.db" # 备份前一天的，文件名也用前一天的日期

                # 2a. WebDAV 每日备份
                if [ -n "$WEBDAV_URL" ] && [ -n "$WEBDAV_USERNAME" ] && [ -n "$WEBDAV_PASSWORD" ]; then
                    echo "[Sync Daily Backup] 备份到 WebDAV: $FILENAME_DAILY ..."
                    if curl -f -L -T "$DB_FILE" --user "$WEBDAV_USERNAME:$WEBDAV_PASSWORD" "$WEBDAV_URL/$FILENAME_DAILY"; then
                        echo "[Sync Daily Backup] WebDAV 日期备份成功: $FILENAME_DAILY"
                    else
                        echo "[Sync Daily Backup] WebDAV 日期备份失败: $FILENAME_DAILY" >&2
                    fi
                else
                     echo "[Sync Daily Backup] 未配置 WebDAV，跳过每日备份。"
                fi

                # 2b. GitHub 每日备份
                if [ -n "$G_NAME" ] && [ -n "$G_TOKEN" ]; then
                    echo "[Sync Daily Backup] 备份到 GitHub ($G_NAME)..."
                    REPO_URL="https://${G_TOKEN}@github.com/${G_NAME}.git"
                    rm -rf "$GIT_TEMP_DIR_DAILY" # 清理旧的临时目录
                    echo "[Sync Daily Backup] 克隆仓库 $REPO_URL 到 $GIT_TEMP_DIR_DAILY ..."
                    if git clone --depth 1 "$REPO_URL" "$GIT_TEMP_DIR_DAILY"; then
                        cd "$GIT_TEMP_DIR_DAILY"
                        echo "[Sync Daily Backup] 配置 Git 用户..."
                        git config user.name "AutoSync Bot"
                        git config user.email "autosync@bot.com"

                        # 确定默认分支
                        DEFAULT_BRANCH=$(git remote show origin | sed -n '/HEAD branch/s/.*: //p')
                        if [ -z "$DEFAULT_BRANCH" ]; then
                             echo "[Sync Daily Backup] 无法确定默认分支，尝试 main 或 master..." >&2
                             if git show-ref --verify --quiet refs/heads/main; then
                                DEFAULT_BRANCH="main"
                             elif git show-ref --verify --quiet refs/heads/master; then
                                DEFAULT_BRANCH="master"
                             else
                                echo "[Sync Daily Backup] 错误: 无法找到 main 或 master 分支。" >&2
                                DEFAULT_BRANCH=""
                             fi
                        fi

                        if [ -n "$DEFAULT_BRANCH" ]; then
                            echo "[Sync Daily Backup] 切换到分支: $DEFAULT_BRANCH"
                            git checkout "$DEFAULT_BRANCH"
                            echo "[Sync Daily Backup] 复制 $DB_FILE 到仓库..."
                            cp "../$DB_FILE" "./$DB_FILE"
                            # 使用 sh 兼容的方式检查是否有更改
                            if [ -n "$(git status --porcelain)" ]; then
                                echo "[Sync Daily Backup] 检测到更改，提交并推送..."
                                git add "$DB_FILE"
                                git commit -m "Auto sync $DB_FILE for $YESTERDAY"
                                if git push origin "$DEFAULT_BRANCH"; then
                                    echo "[Sync Daily Backup] GitHub 推送成功。"
                                else
                                    echo "[Sync Daily Backup] GitHub 推送失败。" >&2
                                fi
                            else
                                echo "[Sync Daily Backup] GitHub: 无数据变化，无需推送。"
                            fi
                        fi
                        cd .. # 返回 /data 目录
                    else
                        echo "[Sync Daily Backup] GitHub 克隆失败。" >&2
                    fi
                    echo "[Sync Daily Backup] 清理 GitHub 临时目录 $GIT_TEMP_DIR_DAILY ..."
                    rm -rf "$GIT_TEMP_DIR_DAILY"
                else
                     echo "[Sync Daily Backup] 未配置 GitHub，跳过每日备份。"
                fi

                # 创建标记文件，表示今天备份已完成
                touch "$BACKUP_FLAG_FILE"
                echo "[Sync $(date '+%Y-%m-%d %H:%M:%S')] 每日备份完成。"

                # 清理7天前的标记文件 (可选)
                find . -name 'daily_backup_done_*' -mtime +7 -delete

            elif [ "$HOUR" != "00" ]; then
                # 如果不是 0 点了，就删除可能存在的标记文件，以便下次到 0 点时可以执行
                rm -f ./daily_backup_done_*
            fi
            # --- 每日备份逻辑结束 ---
        fi # end if $should_sync

        echo "[Sync $(date '+%Y-%m-%d %H:%M:%S')] 等待 ${SYNC_INTERVAL} 秒..."
        sleep "$SYNC_INTERVAL"
    done
}


# --- 主逻辑 ---

echo "Entrypoint script started."
echo "当前工作目录: $(pwd)" # 应该输出 /data

# --- 1. 启动时数据恢复 ---
echo "阶段 1: 启动时数据恢复..."
if [ -f "$DB_FILE" ]; then
    echo "$DB_FILE 已存在，跳过恢复。"
else
    echo "$DB_FILE 不存在，尝试恢复..."
    recovered=0

    # 优先从 WebDAV 恢复
    if [ -n "$WEBDAV_URL" ] && [ -n "$WEBDAV_USERNAME" ] && [ -n "$WEBDAV_PASSWORD" ]; then
        echo "尝试从 WebDAV ($WEBDAV_URL) 恢复 $DB_FILE ..."
        # 使用 -f 选项，如果 HTTP 错误则 curl 静默失败并返回错误码
        # 使用临时文件避免下载不完整覆盖空文件
        if curl -f -L --user "$WEBDAV_USERNAME:$WEBDAV_PASSWORD" "$WEBDAV_URL/$DB_FILE" -o "$DB_FILE.tmp"; then
            mv "$DB_FILE.tmp" "$DB_FILE"
            echo "从 WebDAV 恢复数据成功。"
            recovered=1
        else
            echo "从 WebDAV 恢复失败 (可能文件不存在或认证失败)。" >&2
            rm -f "$DB_FILE.tmp" # 清理可能的空文件或部分文件
        fi
    else
        echo "未配置 WebDAV，跳过 WebDAV 恢复。"
    fi

    # 如果 WebDAV 恢复失败，并且配置了 GitHub，则尝试从 GitHub 恢复
    if [ "$recovered" -eq 0 ] && [ -n "$G_NAME" ] && [ -n "$G_TOKEN" ]; then
        echo "尝试从 GitHub 仓库 $G_NAME 恢复..."
        REPO_URL="https://${G_TOKEN}@github.com/${G_NAME}.git"
        rm -rf "$GIT_TEMP_DIR" # 清理可能存在的旧临时目录
        echo "克隆仓库 $REPO_URL 到 $GIT_TEMP_DIR ..."
        # 克隆最新状态，不需要历史记录
        if git clone --depth 1 "$REPO_URL" "$GIT_TEMP_DIR"; then
            if [ -f "$GIT_TEMP_DIR/$DB_FILE" ]; then
                echo "在 GitHub 仓库中找到 $DB_FILE，复制到当前目录..."
                mv "$GIT_TEMP_DIR/$DB_FILE" "./$DB_FILE"
                echo "从 GitHub 仓库恢复成功。"
                recovered=1
            else
                echo "GitHub 仓库中未找到 $DB_FILE。" >&2
            fi
        else
            echo "GitHub 仓库克隆失败。" >&2
        fi
        echo "清理 GitHub 临时目录 $GIT_TEMP_DIR ..."
        rm -rf "$GIT_TEMP_DIR"
    elif [ "$recovered" -eq 0 ]; then
        echo "未配置 GitHub 或 WebDAV 已恢复成功，跳过 GitHub 恢复。"
    fi

    # 最终检查恢复状态
    if [ "$recovered" -eq 0 ]; then
        echo "警告: 未能从任何来源恢复 $DB_FILE。应用程序将以无初始数据状态启动。" >&2
    fi
fi
echo "阶段 1: 数据恢复完成。"

# --- 2. 启动后台同步进程 ---
echo "阶段 2: 启动后台同步进程..."
sync_data &
sync_pid=$!
echo "后台同步进程已启动，PID: $sync_pid。"

# --- 3. 启动主应用 ---
echo "阶段 3: 启动主应用程序 (/one-api)..."
# 使用 exec 将当前 shell 进程替换为 one-api 进程
# "$@" 会将传递给 entrypoint.sh 的所有参数传递给 one-api
exec /one-api "$@"

# 如果 exec 成功，下面的代码不会执行
echo "错误: exec /one-api 失败！" >&2
# 可以尝试 kill 后台进程，然后退出
kill $sync_pid
exit 1