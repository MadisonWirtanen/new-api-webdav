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
# 安装基础运行环境和同步脚本所需工具
RUN apk update \
    && apk upgrade \
    && apk add --no-cache ca-certificates tzdata ffmpeg \
           bash curl git coreutils \
    && update-ca-certificates

# 复制构建好的 one-api 程序到根目录
COPY --from=builder2 /build/one-api /one-api

# 复制入口脚本到根目录
COPY entrypoint.sh /entrypoint.sh
# 赋予入口脚本执行权限
RUN chmod +x /entrypoint.sh

# 设置工作目录为 /data，脚本中的相对路径将基于此目录
WORKDIR /data

# 暴露端口
EXPOSE 3000

# 设置入口点为我们创建的脚本
ENTRYPOINT ["/entrypoint.sh"]

# 可选：如果 one-api 需要默认参数，可以在这里设置 CMD
# CMD ["--port", "3000"]