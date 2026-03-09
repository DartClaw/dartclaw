#!/usr/bin/env bash
# Start DartClaw with an example config.
# Usage: bash examples/run.sh [config] [extra args...]
#
# Examples:
#   bash examples/run.sh                  # uses dev (default)
#   bash examples/run.sh production       # uses production.yaml
#   bash examples/run.sh dev --port 4000  # dev with custom port
#
# Available configs: dev, production, personal-assistant
# Data is stored in the data_dir specified in the config (default: .dartclaw-dev/).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."

CONFIG_NAME="dev"
if [ $# -gt 0 ] && [[ ! "$1" == -* ]]; then
  CONFIG_NAME="$1"
  shift
fi

CONFIG="${SCRIPT_DIR}/${CONFIG_NAME}.yaml"
if [ ! -f "$CONFIG" ]; then
  echo "Error: config not found: ${CONFIG}" >&2
  echo "Available: $(ls "$SCRIPT_DIR"/*.yaml 2>/dev/null | xargs -n1 basename | sed 's/\.yaml$//' | tr '\n' ' ')" >&2
  exit 1
fi

cd "$REPO_ROOT"
exec dart run dartclaw_cli:dartclaw --config "$CONFIG" serve "$@"
