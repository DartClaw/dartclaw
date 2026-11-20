FROM dartclaw-agent:latest
USER root
# Cargo links test binaries with the system C toolchain.
RUN apt-get update && apt-get install -y --no-install-recommends gcc libc6-dev \
    && rm -rf /var/lib/apt/lists/*
COPY --from=rust:1.99.0-slim-bookworm /usr/local/rustup/toolchains/ /usr/local/rustup/toolchains/
RUN ln -s /usr/local/rustup/toolchains/*/bin/* /usr/local/bin/
# Cargo has no environment setting for source replacement; its upward config
# search reaches /.cargo from any working directory. The route is DartClaw's
# `crates` record.
RUN mkdir /.cargo && printf '%s\n' '[source.crates-io]' 'replace-with = "dartclaw-mirror"' \
    '[source.dartclaw-mirror]' 'registry = "sparse+http://127.0.0.1:8082/crates/"' > /.cargo/config.toml
ENV CARGO_HOME=/var/cache/dartclaw/cargo \
    HOME=/tmp
USER dartclaw
