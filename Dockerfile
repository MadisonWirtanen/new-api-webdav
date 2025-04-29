# Stage 1: Build frontend
FROM oven/bun:latest AS builder
WORKDIR /build
COPY web/package.json .
# Use --frozen-lockfile for reproducible installs if lock file exists
# Consider handling potential errors if lockfile is missing or out of sync
RUN bun install --frozen-lockfile || bun install
COPY ./web .
COPY ./VERSION .
# Ensure VERSION file exists and is readable
RUN V_CONTENT=$(cat VERSION || echo "unknown") && \
    echo "Building frontend with Version: $V_CONTENT" && \
    DISABLE_ESLINT_PLUGIN='true' VITE_REACT_APP_VERSION="$V_CONTENT" bun run build

# Stage 2: Build backend
FROM golang:1.21-alpine AS builder2
# Using a specific Go version like 1.21 for reproducibility
ENV GO111MODULE=on \
    CGO_ENABLED=0 \
    GOOS=linux \
    GOARCH=amd64 # Specify architecture explicitly
WORKDIR /build
# Copy only necessary files for dependency download first to leverage Docker cache
COPY go.mod go.sum ./
RUN go mod download && go mod verify

# Copy the rest of the source code
COPY . .

# Copy built frontend from the first stage
COPY --from=builder /build/dist ./web/dist

# Build the Go application
# Ensure VERSION file is available or provide a default
COPY ./VERSION .
RUN V_CONTENT=$(cat VERSION || echo "unknown") && \
    echo "Building One API backend with Version: $V_CONTENT" && \
    go build -ldflags="-s -w -X 'one-api/common.Version=$V_CONTENT'" -o one-api main.go # Assuming main.go is the entry point

# Stage 3: Final image
FROM alpine:latest

# Add necessary runtime dependencies for one-api and the sync script
# Group dependencies logically
RUN apk update \
    && apk upgrade \
    && apk add --no-cache \
        ca-certificates \
        tzdata \
        ffmpeg \
        # Dependencies for entrypoint.sh and sync logic
        bash \
        curl \
        python3 \
        py3-pip \
        tar \
    && update-ca-certificates \
    # Install Python packages and clean up pip cache
    && pip install --no-cache-dir requests webdav3.client \
    # Clean up apk cache
    && rm -rf /var/cache/apk/*

# Copy the built one-api executable from builder2
COPY --from=builder2 /build/one-api /one-api

# Copy the entrypoint script (ensure this file exists in the build context)
COPY entrypoint.sh /entrypoint.sh
# Make the entrypoint script executable
RUN chmod +x /entrypoint.sh

# Expose the application port defined by one-api
EXPOSE 3000

# Set the working directory where one-api expects its data (like one-api.db)
WORKDIR /data

# Optional: Add a basic healthcheck targeting a potential status endpoint of one-api
# Adjust the CMD path as needed
# HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
#   CMD curl -f http://localhost:3000/api/status || exit 1

# Set the entrypoint to our wrapper script
ENTRYPOINT ["/entrypoint.sh"]

# Optional: Default command for the entrypoint (can be empty if entrypoint.sh handles everything)
# CMD []