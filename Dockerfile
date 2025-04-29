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

RUN apk update && \
    apk upgrade -a && \
    apk add --no-cache \
        ca-certificates \
        tzdata \
        ffmpeg \
        bash \
        curl \
        python3 \
        py3-pip && \
    apk add --no-cache --virtual .build-deps \
        build-base \
        python3-dev \
        libffi-dev \
        cargo && \
    pip install --no-cache-dir --upgrade pip && \
    pip install --no-cache-dir requests webdavclient3 && \
    apk del .build-deps && \
    update-ca-certificates && \
    rm -rf /var/cache/apk/*

COPY --from=builder2 /build/one-api /one-api
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
EXPOSE 3000
WORKDIR /data
ENTRYPOINT ["/entrypoint.sh"]