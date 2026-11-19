FROM dartclaw-agent:latest
USER root
RUN apt-get update && apt-get install -y --no-install-recommends libbz2-1.0 libffi8 liblzma5 libsqlite3-0 \
    && rm -rf /var/lib/apt/lists/*
COPY --from=python:3.14.9-slim-bookworm /usr/local/ /usr/local/
COPY --from=ghcr.io/astral-sh/uv:0.13.6 /uv /uvx /usr/local/bin/
RUN ldconfig
# uv uses the image's Python; the cache volume is another filesystem than the worktree.
ENV PIP_CACHE_DIR=/var/cache/dartclaw/pip \
    UV_CACHE_DIR=/var/cache/dartclaw/uv \
    UV_LINK_MODE=copy \
    UV_PYTHON_DOWNLOADS=never \
    HOME=/tmp
USER dartclaw
