#!/usr/bin/env bash

PROFILE_POSTGRES_CONTAINER=""
PROFILE_POSTGRES_RUNTIME=""

profile_postgres_start() {
  if [ -n "${DARTCLAW_POSTGRES_URL:-}" ]; then
    return 0
  fi
  local candidate
  for candidate in docker podman; do
    if command -v "$candidate" >/dev/null 2>&1 && "$candidate" info >/dev/null 2>&1; then
      PROFILE_POSTGRES_RUNTIME="$candidate"
      break
    fi
  done
  if [ -z "$PROFILE_POSTGRES_RUNTIME" ]; then
    echo "Set DARTCLAW_POSTGRES_URL to a dedicated PostgreSQL 14+ database, or start Docker or Podman." >&2
    return 1
  fi

  PROFILE_POSTGRES_CONTAINER="$("$PROFILE_POSTGRES_RUNTIME" run -d --rm \
    -e POSTGRES_PASSWORD=PostgresFixturePasswordX9 \
    -e POSTGRES_DB=dartclaw_profile \
    -p 127.0.0.1::5432 \
    'postgres:14@sha256:816cf7d06ec33116c8f54cf14197085be89f25291686229485ee7d53a785b901')"
  local ready=false
  for ((attempt = 0; attempt < 60; attempt++)); do
    if "$PROFILE_POSTGRES_RUNTIME" exec "$PROFILE_POSTGRES_CONTAINER" pg_isready --host 127.0.0.1 \
      --username postgres --dbname dartclaw_profile >/dev/null 2>&1; then
      ready=true
      break
    fi
    sleep 1
  done
  if [ "$ready" != true ]; then
    echo "Disposable PostgreSQL did not become ready." >&2
    return 1
  fi
  local address
  address="$("$PROFILE_POSTGRES_RUNTIME" port "$PROFILE_POSTGRES_CONTAINER" 5432/tcp)"
  export DARTCLAW_POSTGRES_URL="postgres://postgres:PostgresFixturePasswordX9@${address}/dartclaw_profile?sslmode=disable"
  echo "Using disposable PostgreSQL for this testing profile." >&2
}

profile_postgres_stop() {
  if [ -n "$PROFILE_POSTGRES_CONTAINER" ]; then
    "$PROFILE_POSTGRES_RUNTIME" rm -f -v "$PROFILE_POSTGRES_CONTAINER" >/dev/null 2>&1 || true
    PROFILE_POSTGRES_CONTAINER=""
  fi
}
