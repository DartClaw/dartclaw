#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
exec dart "$ROOT_DIR/dev/tools/release_check.dart" "$@"
