FROM dartclaw-agent:latest
USER root
COPY --from=golang:1.26.9-bookworm /usr/local/go /usr/local/go
# Login shells reset PATH; expose the toolchain in their standard search path too.
RUN ln -s /usr/local/go/bin/go /usr/local/go/bin/gofmt /usr/local/bin/
# /tmp is noexec, so test binaries are built under the cache volume.
ENV CGO_ENABLED=0 \
    GOPATH=/var/cache/dartclaw/go \
    GOMODCACHE=/var/cache/dartclaw/go/pkg/mod \
    GOCACHE=/var/cache/dartclaw/go/build \
    GOTMPDIR=/var/cache/dartclaw \
    HOME=/tmp
USER dartclaw
