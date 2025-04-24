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

# 安装依赖：ca-certificates, tzdata, ffmpeg (来自原文件), curl, git
# date, cmp, sha256sum 通常包含在 Alpine 的 busybox 中，无需额外安装 coreutils
# 添加 git 和 curl
RUN apk update \
    && apk upgrade \
    && apk add --no-cache ca-certificates tzdata ffmpeg curl git \
    && update-ca-certificates \
    && rm -rf /var/cache/apk/*

COPY --from=builder2 /build/one-api /one-api
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
EXPOSE 3000
WORKDIR /data
ENTRYPOINT ["/entrypoint.sh"]