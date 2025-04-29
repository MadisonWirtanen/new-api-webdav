FROM oven/bun:latest AS builder
WORKDIR /build
COPY web/package.json .
RUN bun install
COPY ./web .
COPY ./VERSION .
RUN DISABLE_ESLINT_PLUGIN='true' VITE_REACT_APP_VERSION=$(cat VERSION) bun run build
FROM golang:alpine AS builder2
ENV GO111MODULE=on \
    CGO_ENABLED=0 \
    GOOS=linux
WORKDIR /build
ADD go.mod go.sum ./
RUN go mod download
COPY . .
COPY --from=builder /build/dist ./web/dist
RUN go build -ldflags "-s -w -X 'one-api/common.Version=$(cat VERSION)'" -o one-api
FROM alpine
RUN apk update \
    && apk upgrade \
    && apk add --no-cache ca-certificates tzdata ffmpeg bash curl git sha256sum \
    && update-ca-certificates

COPY --from=builder2 /build/one-api /

WORKDIR /data

# 添加同步脚本
RUN echo '#!/bin/bash\n\
\n\
mkdir -p ./data\n\
\n\
# 生成校验和文件\n\
generate_sum() {\n\
    local file=$1\n\
    local sum_file=$2\n\
    sha256sum "$file" > "$sum_file"\n\
}\n\
\n\
# 优先从WebDAV恢复数据\n\
if [ ! -z "$WEBDAV_URL" ] && [ ! -z "$WEBDAV_USERNAME" ] && [ ! -z "$WEBDAV_PASSWORD" ]; then\n\
    echo "尝试从WebDAV恢复数据..."\n\
    curl -L --fail --user "$WEBDAV_USERNAME:$WEBDAV_PASSWORD" "$WEBDAV_URL/one-api.db" -o "./data/one-api.db" && {\n\
        echo "从WebDAV恢复数据成功"\n\
    } || {\n\
        if [ ! -z "$G_NAME" ] && [ ! -z "$G_TOKEN" ]; then\n\
            echo "从WebDAV恢复失败,尝试从GitHub恢复..."\n\
            REPO_URL="https://${G_TOKEN}@github.com/${G_NAME}.git"\n\
            git clone "$REPO_URL" ./data/temp && {\n\
                if [ -f ./data/temp/one-api.db ]; then\n\
                    mv ./data/temp/one-api.db ./data/one-api.db\n\
                    echo "从GitHub仓库恢复成功"\n\
                    rm -rf ./data/temp\n\
                else\n\
                    echo "GitHub仓库中未找到one-api.db"\n\
                    rm -rf ./data/temp\n\
                fi\n\
            }\n\
        else\n\
            echo "WebDAV恢复失败,且未配置GitHub"\n\
        fi\n\
    }\n\
else\n\
    echo "未配置WebDAV,跳过数据恢复"\n\
fi\n\
\n\
# 同步函数\n\
sync_data() {\n\
    while true; do\n\
        echo "开始同步..."\n\
        HOUR=$(date +%H)\n\
        \n\
        if [ -f "./data/one-api.db" ]; then\n\
            # 生成新的校验和文件\n\
            generate_sum "./data/one-api.db" "./data/one-api.db.sha256.new"\n\
            \n\
            # 检查文件是否变化\n\
            if [ ! -f "./data/one-api.db.sha256" ] || ! cmp -s "./data/one-api.db.sha256.new" "./data/one-api.db.sha256"; then\n\
                echo "检测到文件变化，开始同步..."\n\
                mv "./data/one-api.db.sha256.new" "./data/one-api.db.sha256"\n\
                \n\
                # 同步到WebDAV\n\
                if [ ! -z "$WEBDAV_URL" ] && [ ! -z "$WEBDAV_USERNAME" ] && [ ! -z "$WEBDAV_PASSWORD" ]; then\n\
                    echo "同步到WebDAV..."\n\
                    \n\
                    # 上传数据文件\n\
                    curl -L -T "./data/one-api.db" --user "$WEBDAV_USERNAME:$WEBDAV_PASSWORD" "$WEBDAV_URL/one-api.db" && {\n\
                        echo "WebDAV更新成功"\n\
                        \n\
                        # 每日备份(包括WebDAV和GitHub)，在每天0点进行\n\
                        if [ "$HOUR" = "00" ]; then\n\
                            echo "开始每日备份..."\n\
                            \n\
                            # 获取前一天的日期\n\
                            YESTERDAY=$(date -d "yesterday" \'+%Y%m%d\')\n\
                            FILENAME_DAILY="one-api_${YESTERDAY}.db"\n\
                            \n\
                            # WebDAV每日备份\n\
                            curl -L -T "./data/one-api.db" --user "$WEBDAV_USERNAME:$WEBDAV_PASSWORD" "$WEBDAV_URL/$FILENAME_DAILY" && {\n\
                                echo "WebDAV日期备份成功: $FILENAME_DAILY"\n\
                                \n\
                                # GitHub每日备份\n\
                                if [ ! -z "$G_NAME" ] && [ ! -z "$G_TOKEN" ]; then\n\
                                    echo "开始GitHub每日备份..."\n\
                                    REPO_URL="https://${G_TOKEN}@github.com/${G_NAME}.git"\n\
                                    git clone "$REPO_URL" ./data/temp || {\n\
                                        echo "GitHub克隆失败"\n\
                                        rm -rf ./data/temp\n\
                                    }\n\
                                    \n\
                                    if [ -d "./data/temp" ]; then\n\
                                        cd ./data/temp\n\
                                        git config user.name "AutoSync Bot"\n\
                                        git config user.email "autosync@bot.com"\n\
                                        git checkout main || git checkout master\n\
                                        cp ../one-api.db ./one-api.db\n\
                                        \n\
                                        if [[ -n $(git status -s) ]]; then\n\
                                            git add one-api.db\n\
                                            git commit -m "Auto sync one-api.db for ${YESTERDAY}"\n\
                                            git push origin HEAD && {\n\
                                                echo "GitHub推送成功"\n\
                                            } || echo "GitHub推送失败"\n\
                                        else\n\
                                            echo "GitHub: 无数据变化"\n\
                                        fi\n\
                                        cd ../..\n\
                                        rm -rf ./data/temp\n\
                                    fi\n\
                                fi\n\
                            } || echo "WebDAV日期备份失败"\n\
                        fi\n\
                    } || {\n\
                        echo "WebDAV上传失败,重试..."\n\
                        sleep 10\n\
                        curl -L -T "./data/one-api.db" --user "$WEBDAV_USERNAME:$WEBDAV_PASSWORD" "$WEBDAV_URL/one-api.db" || {\n\
                            echo "WebDAV重试失败"\n\
                        }\n\
                    }\n\
                fi\n\
            else\n\
                echo "文件未发生变化，跳过同步"\n\
                rm -f "./data/one-api.db.sha256.new"\n\
            fi\n\
        else\n\
            echo "未找到one-api.db,跳过同步"\n\
        fi\n\
        \n\
        echo "当前时间: $(date \'+%Y-%m-%d %H:%M:%S\')"\n\
        echo "下次同步: $(date -d \'+5 minutes\' \'+%Y-%m-%d %H:%M:%S\')"\n\
        sleep 300\n\
    done\n\
}\n\
\n\
# 启动同步进程\n\
sync_data &\n\
\n\
# 执行原始命令\n\
exec "$@"' > /sync.sh

RUN chmod +x /sync.sh

EXPOSE 3000
ENTRYPOINT ["/bin/bash", "-c", "/sync.sh && /one-api"]