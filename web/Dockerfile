# ── Multi-Stage Layered Dockerfile: George Web Sidecar ──────────
# Stage 1: Dependency Cache & Compilation
FROM rust:slim-bookworm AS builder

WORKDIR /usr/src/george-web

# Install build dependencies
RUN apt-get update && apt-get install -y pkg-config libssl-dev && rm -rf /var/lib/apt/lists/*

# Layer 1: Cache Cargo dependencies separately from source code
COPY Cargo.toml Cargo.lock ./
RUN mkdir src && echo "fn main() {}" > src/main.rs && \
    cargo build --release && \
    rm -rf src

# Layer 2: Copy actual source and compile production binary
COPY src ./src
RUN touch src/main.rs && cargo build --release

# ── Stage 2: Lightweight Minimal Runtime ─────────────────────────
FROM debian:bookworm-slim AS runtime

WORKDIR /app

# Install runtime dependencies for George Web, embedded PTY ./lodge agent loop, and Kubernetes self-management
RUN apt-get update && apt-get install -y \
    bubblewrap \
    ca-certificates \
    curl \
    ffmpeg \
    git \
    iproute2 \
    jq \
    mosquitto-clients \
    openssh-client \
    poppler-utils \
    procps \
    python3 \
    python3-pip \
    python3-venv \
    ripgrep \
    sqlite3 \
    zstd \
    && curl -fsSL "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" -o /usr/local/bin/kubectl \
    && chmod +x /usr/local/bin/kubectl \
    && curl -LsSf https://astral.sh/uv/install.sh | BINDIR=/usr/local/bin sh \
    && rm -rf /var/lib/apt/lists/*

# Copy compiled binary from builder
COPY --from=builder /usr/src/george-web/target/release/george-web /usr/local/bin/george-web

# Copy default static assets
COPY static ./static

# Expose web server port
EXPOSE 3000

ENV LODGE_DIR=/workspace \
    PORT=3000

CMD ["/usr/local/bin/george-web"]
