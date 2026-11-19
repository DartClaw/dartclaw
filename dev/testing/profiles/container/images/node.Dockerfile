FROM dartclaw-agent:latest
USER root
RUN apt-get update && apt-get install -y --no-install-recommends libatomic1 libstdc++6 \
    && rm -rf /var/lib/apt/lists/*
COPY --from=node:24.22.3-bookworm-slim /usr/local/ /usr/local/
ENV PATH="/usr/local/bin:${PATH}" \
    NPM_CONFIG_CACHE=/var/cache/dartclaw/npm-cache
USER dartclaw
