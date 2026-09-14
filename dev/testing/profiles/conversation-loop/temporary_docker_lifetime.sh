#!/usr/bin/env bash
set -euo pipefail
EVIDENCE="${1:?evidence directory required}"
MODE="${2:?mode must be eof or sigkill}"
exec "$(dirname "$0")/temporary_conversation_e2e.sh" "$MODE" "$EVIDENCE"
