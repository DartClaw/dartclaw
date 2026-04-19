#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

if rg -n "import 'package:dartclaw_server" packages/dartclaw_workflow/lib; then
  echo "Fitness function failed: packages/dartclaw_workflow/lib must not import package:dartclaw_server."
  exit 1
fi

echo "Fitness function passed: packages/dartclaw_workflow/lib has no package:dartclaw_server imports."
