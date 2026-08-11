FROM debian:bookworm-slim

ARG CLAUDE_VERSION=latest

# Codex is pinned to an exact release with a per-architecture sha256. A
# floating `latest` is rejected below: an agent binary that can change under a
# rebuilt image is not a boundary anyone can reason about, and a version probe
# alone would accept any runnable binary from any source. Bumping the version
# means replacing both digests – obtain them from the release's
# `codex-<arch>-unknown-linux-musl.tar.gz` assets.
ARG CODEX_VERSION=0.146.0
ARG CODEX_SHA256_AMD64=5ba3b9405543953081f661d0854d266f76e2abbe51d41349355a36de7673776a
ARG CODEX_SHA256_ARM64=975bac91562abeedeb8f79636d51a86649b31f34a9de6a3bcb059565b6cf1f87
ARG TARGETARCH

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    git \
    && rm -rf /var/lib/apt/lists/*

RUN groupadd -g 1000 dartclaw && \
    useradd -m -u 1000 -g dartclaw dartclaw

USER dartclaw
RUN curl -fsSL https://claude.ai/install.sh | bash -s -- "${CLAUDE_VERSION}"
RUN set -eux; \
    case "${CODEX_VERSION}" in \
      ""|latest) \
        echo "CODEX_VERSION must pin an exact release, got '${CODEX_VERSION}'" >&2; exit 1 ;; \
    esac; \
    target_arch="${TARGETARCH:-}"; \
    if [ -z "${target_arch}" ]; then \
      target_arch="$(dpkg --print-architecture 2>/dev/null || true)"; \
    fi; \
    if [ -z "${target_arch}" ]; then \
      target_arch="$(uname -m)"; \
    fi; \
    case "${target_arch}" in \
      amd64|x86_64) codex_arch="x86_64"; codex_sha256="${CODEX_SHA256_AMD64}" ;; \
      arm64|aarch64) codex_arch="aarch64"; codex_sha256="${CODEX_SHA256_ARM64}" ;; \
      *) echo "Unsupported TARGETARCH: ${target_arch}" >&2; exit 1 ;; \
    esac; \
    if [ -z "${codex_sha256}" ]; then \
      echo "No sha256 pinned for ${codex_arch}; refusing an unverified Codex install" >&2; exit 1; \
    fi; \
    archive="/tmp/codex-${codex_arch}.tar.gz"; \
    curl -fsSL \
      "https://github.com/openai/codex/releases/download/rust-v${CODEX_VERSION}/codex-${codex_arch}-unknown-linux-musl.tar.gz" \
      -o "${archive}"; \
    echo "${codex_sha256}  ${archive}" | sha256sum -c -; \
    mkdir -p /home/dartclaw/.local/bin; \
    tar -xzf "${archive}" -C /tmp "codex-${codex_arch}-unknown-linux-musl"; \
    mv "/tmp/codex-${codex_arch}-unknown-linux-musl" /home/dartclaw/.local/bin/codex; \
    chmod +x /home/dartclaw/.local/bin/codex; \
    rm -f "${archive}"; \
    /home/dartclaw/.local/bin/codex --version; \
    # The probe creates a Codex home. The image must ship none: containerized
    # Codex is always pointed at a generated auth-clean home instead, and a
    # leftover one is a second place a client could read state from.
    rm -rf /home/dartclaw/.codex

ENV PATH="/home/dartclaw/.local/bin:${PATH}"

COPY --chown=dartclaw:dartclaw .claude/ /home/dartclaw/.claude/

WORKDIR /workspace

CMD ["sleep", "infinity"]
