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

FROM python:3.10-alpine
RUN apk update
RUN apk upgrade
RUN apk add --no-cache ca-certificates tzdata ffmpeg bash curl git coreutils tar libxml2 libxslt
RUN apk add --no-cache --virtual .build-deps build-base libxml2-dev libxslt-dev
RUN pip3 install --no-cache-dir webdavclient3 requests
RUN update-ca-certificates
RUN apk del .build-deps
RUN rm -rf /var/cache/apk/* /tmp/*

COPY --from=builder2 /build/one-api /one-api

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
WORKDIR /data
EXPOSE 3000
ENTRYPOINT ["/entrypoint.sh"]
