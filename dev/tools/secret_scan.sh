#!/usr/bin/env bash

# Release gate: fails when a tracked file holds a provider-shaped credential that
# GitHub push protection would block, so it is caught before the push instead of
# at it. No scanner (gitleaks, trufflehog) is a project dependency, so this is a
# pattern check. Fixtures that need a token-shaped string assemble it at runtime
# (e.g. 'xox' 'b-...'), keeping no matching literal in the tree.
# Usage: bash dev/tools/secret_scan.sh
# Exit code 0 = clean, 1 = match found.

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

patterns=(
  'xox[abposr]-[0-9]{8,}-[0-9A-Za-z-]{8,}'          # Slack bot/user/workspace tokens
  'xapp-[0-9]-[A-Z0-9]+-[0-9]+-[a-z0-9]+'           # Slack app-level tokens
  'gh[pousr]_[A-Za-z0-9]{36,}'                      # GitHub tokens
  'github_pat_[A-Za-z0-9_]{22,}'                    # GitHub fine-grained PATs
  'AKIA[0-9A-Z]{16}'                                # AWS access key IDs
  'sk-ant-api[0-9]{2}-[A-Za-z0-9_-]{80,}'           # Anthropic API keys
  'AIza[0-9A-Za-z_-]{35}'                           # Google API keys
)

args=()
for p in "${patterns[@]}"; do args+=(-e "$p"); done

# AWS documents AKIAIOSFODNN7EXAMPLE; GitHub does not block it and tests use it.
if git grep -nIE "${args[@]}" -- . | grep -v 'EXAMPLE' >&2; then
  echo "Secret-shaped literal found. Assemble fixture tokens at runtime or use a non-matching shape." >&2
  exit 1
fi
echo "No secret-shaped literals in tracked files"
