FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Install claude CLI (Bun standalone binary)
RUN curl -fsSL https://claude.ai/install.sh | sh || true

# Non-root user
RUN groupadd -g 1000 dartclaw && \
    useradd -m -u 1000 -g dartclaw dartclaw

WORKDIR /workspace
USER dartclaw

# No ENTRYPOINT — managed by docker exec
CMD ["sleep", "infinity"]
