FROM debian:bookworm-slim

ARG CLAUDE_VERSION=latest

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

ENV PATH="/home/dartclaw/.local/bin:${PATH}"

COPY --chown=dartclaw:dartclaw .claude/ /home/dartclaw/.claude/

WORKDIR /workspace

CMD ["sleep", "infinity"]
