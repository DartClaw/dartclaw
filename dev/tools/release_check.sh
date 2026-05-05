#!/usr/bin/env bash

# Release readiness check — runs the automatable pre-tag gates from CLAUDE.md
# § Release Preparation. Manual gates (integration tests, UI smoke) are listed
# at the end as reminders, not run, since they require a running server.
#
# Usage:
#   bash dev/tools/release_check.sh            # full run incl. tests
#   bash dev/tools/release_check.sh --quick    # skip dart test (fast iteration)
#
# Exit code 0 = all automated gates passed, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

QUICK=0
for arg in "$@"; do
  case "$arg" in
    --quick|-q) QUICK=1 ;;
    -h|--help)
      sed -n '3,11p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "unknown arg: $arg" >&2; exit 2 ;;
  esac
done

if [[ -t 1 ]]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YLW=$'\033[33m'; C_BLD=$'\033[1m'; C_RST=$'\033[0m'
else
  C_RED=''; C_GRN=''; C_YLW=''; C_BLD=''; C_RST=''
fi

FAILED=()
section() { printf "\n%s==> %s%s\n" "$C_BLD" "$1" "$C_RST"; }
pass()    { printf "  %sPASS%s  %s\n" "$C_GRN" "$C_RST" "$1"; }
fail()    { printf "  %sFAIL%s  %s\n" "$C_RED" "$C_RST" "$1"; FAILED+=("$1"); }
skip()    { printf "  %sSKIP%s  %s\n" "$C_YLW" "$C_RST" "$1"; }

section "1. Exported bundle cleanup (transient dev docs must be empty before merge to main)"
leaked_bundle=""
# dev/bundle is the current export root. The other dev/* directories and root
# markdown files are legacy transient export paths; canonical public docs live
# under dev/state/, dev/guidelines/, docs/, or package-specific directories.
for exported_dir in dev/bundle dev/specs dev/adrs dev/research dev/wireframes dev/design-system dev/architecture dev/diagrams; do
  if [[ -d "$exported_dir" ]]; then
    leaked=$(find "$exported_dir" -type f ! -name '.gitkeep' 2>/dev/null)
    if [[ -n "$leaked" ]]; then
      leaked_bundle+="${leaked}"$'\n'
    fi
  fi
done
for legacy_root_alias in dev/STATE.md dev/LEARNINGS.md dev/STACK.md dev/UBIQUITOUS_LANGUAGE.md dev/TECH-DEBT-BACKLOG.md dev/SPEC-LIFECYCLE.md dev/ROADMAP.md dev/PRODUCT.md dev/PRODUCT-BACKLOG.md dev/INSPIRATION-BACKLOG.md; do
  if [[ -f "$legacy_root_alias" ]]; then
    leaked_bundle+="${legacy_root_alias}"$'\n'
  fi
done
if [[ -z "$leaked_bundle" ]]; then
  pass "no exported implementation bundle files found"
else
  leaked_count=$(printf '%s' "$leaked_bundle" | sed '/^$/d' | wc -l | tr -d ' ')
  fail "exported implementation bundle contains $leaked_count file(s) — remove before squash-merge (see dev/state/SPEC-LIFECYCLE.md)"
  printf '%s' "$leaked_bundle" | sed '/^$/d; s/^/        /'
fi

section "2. Version pins (lockstep across all packages)"
if bash dev/tools/check_versions.sh > /tmp/release_check_versions.log 2>&1; then
  pass "$(tail -1 /tmp/release_check_versions.log)"
else
  fail "version pins drifted — see output below"
  cat /tmp/release_check_versions.log | sed 's/^/        /'
fi

section "3. Format (dart format --set-exit-if-changed .)"
if dart format --output=none --set-exit-if-changed . > /tmp/release_check_fmt.log 2>&1; then
  pass "format clean"
else
  fail "format changes pending — run: dart format ."
  tail -20 /tmp/release_check_fmt.log | sed 's/^/        /'
fi

section "4. Static analysis (dart analyze, fatal on warnings + infos)"
if dart analyze --fatal-warnings --fatal-infos > /tmp/release_check_analyze.log 2>&1; then
  pass "analyze clean (zero warnings, zero infos)"
else
  fail "analyze issues found"
  tail -40 /tmp/release_check_analyze.log | sed 's/^/        /'
fi

section "5. Test suite (dart test)"
if [[ "$QUICK" == "1" ]]; then
  skip "skipped via --quick"
else
  if dart test > /tmp/release_check_test.log 2>&1; then
    pass "$(grep -E 'All tests passed|tests? passed' /tmp/release_check_test.log | tail -1 || echo 'tests passed')"
  else
    fail "test failures — see /tmp/release_check_test.log"
    tail -40 /tmp/release_check_test.log | sed 's/^/        /'
  fi
fi

section "Summary"
if [[ ${#FAILED[@]} -eq 0 ]]; then
  printf "%sAll automated gates passed.%s\n\n" "$C_GRN" "$C_RST"
  cat <<'NEXT'
Manual gates still required before tagging:
  - Integration tests:   dart test -t integration
  - UI smoke test:       bash dev/testing/profiles/smoke-test/run.sh
                         (requires a running dev server)

Then proceed with the version-bump commit and tag per
CLAUDE.md § Release Preparation.
NEXT
  exit 0
else
  printf "%s%d gate(s) failed:%s\n" "$C_RED" "${#FAILED[@]}" "$C_RST"
  for msg in "${FAILED[@]}"; do
    printf "  - %s\n" "$msg"
  done
  exit 1
fi
