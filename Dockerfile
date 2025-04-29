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
    && apk add --no-cache ca-certificates tzdata ffmpeg python3 py3-pip curl bash \
    && update-ca-certificates \
    && pip3 install --no-cache-dir requests webdavclient3

COPY --from=builder2 /build/one-api /

# Add sync script
RUN echo '#!/bin/bash\n\
\n\
# 检查环境变量\n\
if [[ -z "$WEBDAV_URL" ]] || [[ -z "$WEBDAV_USERNAME" ]] || [[ -z "$WEBDAV_PASSWORD" ]]; then\n\
    echo "缺少 WEBDAV_URL、WEBDAV_USERNAME 或 WEBDAV_PASSWORD，启动时将不包含备份功能"\n\
    exec /one-api\n\
fi\n\
\n\
# 设置备份路径\n\
WEBDAV_BACKUP_PATH=${WEBDAV_BACKUP_PATH:-""}\n\
FULL_WEBDAV_URL="${WEBDAV_URL}"\n\
if [ -n "$WEBDAV_BACKUP_PATH" ]; then\n\
    FULL_WEBDAV_URL="${WEBDAV_URL}/${WEBDAV_BACKUP_PATH}"\n\
fi\n\
\n\
# 下载最新备份并恢复\n\
restore_backup() {\n\
    echo "开始从 WebDAV 下载最新备份..."\n\
    python3 -c "\n\
import sys\n\
import os\n\
import tarfile\n\
import requests\n\
from webdav3.client import Client\n\
import shutil\n\
options = {\n\
    \"webdav_hostname\": \"$FULL_WEBDAV_URL\",\n\
    \"webdav_login\": \"$WEBDAV_USERNAME\",\n\
    \"webdav_password\": \"$WEBDAV_PASSWORD\"\n\
}\n\
client = Client(options)\n\
backups = [file for file in client.list() if file.endswith(\".tar.gz\") and file.startswith(\"oneapi_backup_\")]\n\
if not backups:\n\
    print(\"没有找到备份文件\")\n\
    sys.exit()\n\
latest_backup = sorted(backups)[-1]\n\
print(f\"最新备份文件：{latest_backup}\")\n\
with requests.get(f\"$FULL_WEBDAV_URL/{latest_backup}\", auth=(\"$WEBDAV_USERNAME\", \"$WEBDAV_PASSWORD\"), stream=True) as r:\n\
    if r.status_code == 200:\n\
        with open(f\"/tmp/{latest_backup}\", \"wb\") as f:\n\
            for chunk in r.iter_content(chunk_size=8192):\n\
                f.write(chunk)\n\
        print(f\"成功下载备份文件到 /tmp/{latest_backup}\")\n\
        if os.path.exists(f\"/tmp/{latest_backup}\"):\n\
            # 解压备份文件到临时目录\n\
            temp_dir = \"/tmp/restore\"\n\
            os.makedirs(temp_dir, exist_ok=True)\n\
            tar = tarfile.open(f\"/tmp/{latest_backup}\", \"r:gz\")\n\
            tar.extractall(temp_dir)\n\
            tar.close()\n\
            # 查找并移动 one-api.db 文件\n\
            for root, dirs, files in os.walk(temp_dir):\n\
                if \"one-api.db\" in files:\n\
                    db_path = os.path.join(root, \"one-api.db\")\n\
                    os.makedirs(\"/data\", exist_ok=True)\n\
                    shutil.copy2(db_path, \"/data/one-api.db\")\n\
                    print(f\"成功从 {latest_backup} 恢复备份\")\n\
                    break\n\
            else:\n\
                print(\"备份文件中未找到 one-api.db\")\n\
            # 删除临时目录\n\
            try:\n\
                shutil.rmtree(temp_dir)\n\
            except Exception as e:\n\
                print(f\"删除临时目录时出错：{e}\")\n\
            os.remove(f\"/tmp/{latest_backup}\")\n\
        else:\n\
            print(\"下载的备份文件不存在\")\n\
    else:\n\
        print(f\"下载备份失败：{r.status_code}\")\n\
"\n\
}\n\
\n\
# 首次启动时下载最新备份\n\
echo "正在从 WebDAV 下载最新备份..."\n\
restore_backup\n\
\n\
# 同步函数\n\
sync_data() {\n\
    while true; do\n\
        echo "在 $(date) 开始同步进程"\n\
\n\
        if [ -f "/data/one-api.db" ]; then\n\
            timestamp=$(date +%Y%m%d_%H%M%S)\n\
            backup_file="oneapi_backup_${timestamp}.tar.gz"\n\
\n\
            # 打包数据库文件\n\
            tar -czf "/tmp/${backup_file}" -C /data one-api.db\n\
\n\
            # 上传新备份到WebDAV\n\
            curl -u "$WEBDAV_USERNAME:$WEBDAV_PASSWORD" -T "/tmp/${backup_file}" "$FULL_WEBDAV_URL/${backup_file}"\n\
            if [ $? -eq 0 ]; then\n\
                echo "成功将 ${backup_file} 上传至 WebDAV"\n\
            else\n\
                echo "上传 ${backup_file} 至 WebDAV 失败"\n\
            fi\n\
\n\
            # 清理旧备份文件\n\
            python3 -c "\n\
import sys\n\
from webdav3.client import Client\n\
options = {\n\
    \"webdav_hostname\": \"$FULL_WEBDAV_URL\",\n\
    \"webdav_login\": \"$WEBDAV_USERNAME\",\n\
    \"webdav_password\": \"$WEBDAV_PASSWORD\"\n\
}\n\
client = Client(options)\n\
backups = [file for file in client.list() if file.endswith(\".tar.gz\") and file.startswith(\"oneapi_backup_\")]\n\
backups.sort()\n\
if len(backups) > 5:\n\
    to_delete = len(backups) - 5\n\
    for file in backups[:to_delete]:\n\
        client.clean(file)\n\
        print(f\"成功删除 {file}。\")\n\
else:\n\
    print(\"仅找到 {} 个备份，无需清理。\".format(len(backups)))\n\
" 2>&1\n\
\n\
            rm -f "/tmp/${backup_file}"\n\
        else\n\
            echo "数据库文件尚不存在，等待下次同步..."\n\
        fi\n\
\n\
        SYNC_INTERVAL=${SYNC_INTERVAL:-600}\n\
        echo "下次同步将在 ${SYNC_INTERVAL} 秒后进行..."\n\
        sleep $SYNC_INTERVAL\n\
    done\n\
}\n\
\n\
# 后台启动同步进程\n\
sync_data &\n\
\n\
# 启动主应用\n\
exec /one-api' > /sync_data.sh

RUN chmod +x /sync_data.sh

EXPOSE 3000
WORKDIR /data
ENTRYPOINT ["/sync_data.sh"]
