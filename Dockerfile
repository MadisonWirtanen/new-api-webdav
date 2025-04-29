# 第一阶段：构建前端
FROM oven/bun:latest AS builder
WORKDIR /build
COPY web/package.json .
RUN bun install
COPY ./web .
COPY ./VERSION .
# 构建 React 应用，并将版本信息注入
RUN DISABLE_ESLINT_PLUGIN='true' VITE_REACT_APP_VERSION=$(cat VERSION) bun run build

# 第二阶段：构建 Go 后端
FROM golang:alpine AS builder2
ENV GO111MODULE=on \
    CGO_ENABLED=0 \
    GOOS=linux
WORKDIR /build
ADD go.mod go.sum ./
# 下载 Go 模块依赖
RUN go mod download
COPY . .
# 从第一阶段复制构建好的前端静态文件
COPY --from=builder /build/dist ./web/dist
# 编译 Go 应用，并注入版本信息
RUN go build -ldflags "-s -w -X 'one-api/common.Version=$(cat VERSION)'" -o one-api

# 最终运行阶段
FROM alpine:3.18 # 使用一个明确的稳定版本

# 更新 Alpine 包索引并升级现有包
RUN apk update && apk upgrade \
    && echo "[Build Step] Alpine packages updated and upgraded successfully."

# 安装运行 entrypoint.sh 和 one-api 所需的依赖
# ca-certificates: HTTPS 证书支持
# tzdata: 时区数据
# ffmpeg: 原 Dockerfile 中包含，予以保留
# bash: entrypoint.sh 使用 bash
# python3, py3-pip: 运行 Python 备份/恢复/清理脚本
# curl: 用于上传备份到 WebDAV
# tar: 用于打包数据库文件
RUN apk add --no-cache \
    ca-certificates \
    tzdata \
    ffmpeg \
    bash \
    python3 \
    py3-pip \
    curl \
    tar \
    && echo "[Build Step] Essential APK packages installed successfully."

# 更新系统 CA 证书
RUN update-ca-certificates \
    && echo "[Build Step] CA certificates updated successfully."

# 安装 Python 依赖库 (requests 用于 HTTP 请求，webdavclient3 用于 WebDAV 操作)
# 使用国内镜像源 (清华源) 加速下载并增加稳定性
# --no-cache-dir: 不使用缓存，确保获取最新包并减少镜像层大小
RUN pip install --no-cache-dir -i https://pypi.tuna.tsinghua.edu.cn/simple requests webdavclient3 \
    && echo "[Build Step] Python dependencies (requests, webdavclient3) installed successfully."

# 清理 apk 缓存以减小最终镜像体积
RUN rm -rf /var/cache/apk/* \
    && echo "[Build Step] APK cache cleared."

# 从 Go 构建阶段复制编译好的 one-api 二进制文件到根目录
COPY --from=builder2 /build/one-api /one-api

# 复制入口点脚本到镜像根目录
COPY entrypoint.sh /entrypoint.sh
# 赋予入口点脚本执行权限
RUN chmod +x /entrypoint.sh

# 设置工作目录为 /data，one-api 默认会在此目录下寻找或创建数据库文件
WORKDIR /data

# 暴露 one-api 服务端口
EXPOSE 3000

# 设置容器启动时执行的命令为入口点脚本
# 入口点脚本会先处理备份/恢复逻辑（如果配置了 WebDAV），然后启动 one-api 服务
ENTRYPOINT ["/entrypoint.sh"]