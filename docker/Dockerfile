FROM debian:bookworm-slim

ARG CLAUDE_VERSION=latest
ARG CODEX_VERSION=latest
ARG TARGETARCH

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    git \
    socat \
    && rm -rf /var/lib/apt/lists/*

RUN groupadd -g 1000 dartclaw && \
    useradd -m -u 1000 -g dartclaw dartclaw

USER dartclaw
RUN curl -fsSL https://claude.ai/install.sh | bash -s -- "${CLAUDE_VERSION}"
RUN set -eux; \
    target_arch="${TARGETARCH:-}"; \
    if [ -z "${target_arch}" ]; then \
      target_arch="$(dpkg --print-architecture 2>/dev/null || true)"; \
    fi; \
    if [ -z "${target_arch}" ]; then \
      target_arch="$(uname -m)"; \
    fi; \
    case "${target_arch}" in \
      amd64) codex_arch="x86_64" ;; \
      x86_64) codex_arch="x86_64" ;; \
      arm64) codex_arch="aarch64" ;; \
      aarch64) codex_arch="aarch64" ;; \
      *) echo "Unsupported TARGETARCH: ${target_arch}" >&2; exit 1 ;; \
    esac; \
    case "${CODEX_VERSION}" in \
      latest) codex_release_path="latest/download" ;; \
      *) codex_release_path="download/${CODEX_VERSION}" ;; \
    esac; \
    mkdir -p /home/dartclaw/.local/bin; \
    curl -fsSL "https://github.com/openai/codex/releases/${codex_release_path}/codex-linux-${codex_arch}" \
      -o /home/dartclaw/.local/bin/codex; \
    chmod +x /home/dartclaw/.local/bin/codex

ENV PATH="/home/dartclaw/.local/bin:${PATH}"

COPY --chown=dartclaw:dartclaw .claude/ /home/dartclaw/.claude/

WORKDIR /workspace

CMD ["sleep", "infinity"]
