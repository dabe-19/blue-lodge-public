# ── Multi-Stage Layered Dockerfile: George Web Sidecar ──────────
# Stage 1: Dependency Cache & Compilation
FROM rust:1.80-slim-bookworm AS builder

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

# Install minimal runtime dependencies (curl, procps, bash)
RUN apt-get update && apt-get install -y \
    ca-certificates \
    curl \
    procps \
    ripgrep \
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
