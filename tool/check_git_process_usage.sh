#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if rg -n "Process\\.(run|start)\\s*\\(\\s*['\\\"]git" packages apps --glob '!**/test/**'; then
  echo "Raw git Process.run/Process.start usage is forbidden in production code; use SafeProcess.git instead." >&2
  exit 1
fi

echo "No raw git Process.run/Process.start usage found in production code."
