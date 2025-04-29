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
FROM alpine
# 安装必要的运行时依赖
# ca-certificates: HTTPS 证书
# tzdata: 时区信息
# ffmpeg: 可能用于某些 API 功能（保留原样）
# bash: 用于运行 entrypoint.sh 脚本
# python3, py3-pip: 用于运行 Python 备份/恢复逻辑
# curl: 用于上传备份到 WebDAV
# tar: 用于打包备份文件
RUN apk update \
    && apk upgrade \
    && apk add --no-cache ca-certificates tzdata ffmpeg \
                           bash python3 py3-pip curl tar \
    && update-ca-certificates \
    # 安装 Python 库
    && pip install requests webdavclient3 \
    # 清理 apk 缓存减少镜像体积
    && rm -rf /var/cache/apk/*

# 从 Go 构建阶段复制编译好的二进制文件
COPY --from=builder2 /build/one-api /one-api

# 复制新的入口点脚本
COPY entrypoint.sh /entrypoint.sh
# 赋予入口点脚本执行权限
RUN chmod +x /entrypoint.sh

# 设置工作目录
WORKDIR /data

# 暴露应用程序端口
EXPOSE 3000

# 设置容器的入口点为新的脚本
ENTRYPOINT ["/entrypoint.sh"]