#!/usr/bin/env bash

# Release readiness check — runs the automatable pre-tag gates from CLAUDE.md
# § Release Preparation. Manual gates are listed at the end as reminders; they
# require provider credentials, a running server, or external platforms.
#
# Usage:
#   bash dev/tools/release_check.sh --version 0.21.0
#   bash dev/tools/release_check.sh --version 0.21.0 --quick  # skip workspace tests
#
# Exit code 0 = all automated gates passed, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

QUICK=0
RELEASE_VERSION=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      if [[ $# -lt 2 ]]; then
        echo "--version requires a value" >&2
        exit 2
      fi
      RELEASE_VERSION="$2"
      shift 2
      ;;
    --quick|-q)
      QUICK=1
      shift
      ;;
    -h|--help)
      sed -n '3,11p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
if [[ -z "$RELEASE_VERSION" ]]; then
  echo "--version is required" >&2
  exit 2
fi

worktree_status="$(git status --porcelain=v1 --untracked-files=all)"
if [[ -n "$worktree_status" ]]; then
  echo "Release check requires a clean worktree so every verified file is part of HEAD." >&2
  printf '%s\n' "$worktree_status" | sed 's/^/  /' >&2
  exit 1
fi

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

section "1. Transient release inputs (must be absent before merge to main)"
leaked_bundle=""
# dev/bundle is the current export root. The other dev/* directories, generated
# test reports, and root markdown files listed here are transient. Canonical public
# docs live under dev/state/, dev/guidelines/, dev/architecture/,
# dev/design-system/, dev/adrs/, docs/, or package-specific directories.
for exported_dir in dev/bundle dev/specs dev/research dev/wireframes dev/diagrams dev/testing/evidence; do
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
  pass "no transient release inputs found"
else
  leaked_count=$(printf '%s' "$leaked_bundle" | sed '/^$/d' | wc -l | tr -d ' ')
  fail "transient release inputs contain $leaked_count file(s) — remove before squash-merge"
  printf '%s' "$leaked_bundle" | sed '/^$/d; s/^/        /'
fi

section "2. Version pins (all packages at $RELEASE_VERSION)"
if bash dev/tools/check_versions.sh "$RELEASE_VERSION" > /tmp/release_check_versions.log 2>&1; then
  pass "$(tail -1 /tmp/release_check_versions.log)"
else
  fail "version pins drifted — see output below"
  cat /tmp/release_check_versions.log | sed 's/^/        /'
fi

section "3. Dependency lock"
if {
  git ls-files --error-unmatch pubspec.lock
  dart pub get --enforce-lockfile
  git diff --exit-code -- pubspec.lock
} > /tmp/release_check_lock.log 2>&1; then
  pass "tracked workspace lockfile is current"
else
  fail "workspace lockfile missing or stale — see /tmp/release_check_lock.log"
  tail -40 /tmp/release_check_lock.log | sed 's/^/        /'
fi

section "4. Format (dart format --line-length=120 --set-exit-if-changed .)"
if dart format --line-length=120 --output=none --set-exit-if-changed . > /tmp/release_check_fmt.log 2>&1; then
  pass "format clean"
else
  fail "format changes pending — run: dart format --line-length=120 ."
  tail -20 /tmp/release_check_fmt.log | sed 's/^/        /'
fi

section "5. Embedded asset drift"
if {
  git ls-files --error-unmatch -- \
    packages/dartclaw_server/lib/src/generated/embedded_assets.g.dart \
    packages/dartclaw_workflow/lib/src/generated/embedded_assets.g.dart
  dart run dev/tools/embed_assets.dart
  git diff --exit-code -- '**/generated/embedded_assets.g.dart'
} > /tmp/release_check_assets.log 2>&1; then
  pass "embedded assets current"
else
  fail "embedded assets drifted — see /tmp/release_check_assets.log"
  tail -40 /tmp/release_check_assets.log | sed 's/^/        /'
fi

section "6. Static analysis (dart analyze, fatal on warnings + infos)"
if dart analyze --fatal-warnings --fatal-infos > /tmp/release_check_analyze.log 2>&1; then
  pass "analyze clean (zero warnings, zero infos)"
else
  fail "analyze issues found"
  tail -40 /tmp/release_check_analyze.log | sed 's/^/        /'
fi

section "7. Workspace tests (CI test_workspace.sh)"
if [[ "$QUICK" == "1" ]]; then
  skip "skipped via --quick"
else
  if bash dev/tools/test_workspace.sh > /tmp/release_check_test.log 2>&1; then
    pass "all workspace tests passed"
  else
    fail "test failures — see /tmp/release_check_test.log"
    tail -40 /tmp/release_check_test.log | sed 's/^/        /'
  fi
fi

section "8. Architecture check"
if dart run dev/tools/arch_check.dart > /tmp/release_check_arch.log 2>&1; then
  pass "architecture check green"
else
  fail "architecture check failed — see /tmp/release_check_arch.log"
  tail -40 /tmp/release_check_arch.log | sed 's/^/        /'
fi

section "9. Fitness functions (CI governance suite)"
if bash dev/tools/fitness/run_all.sh > /tmp/release_check_fitness.log 2>&1; then
  pass "fitness suite green"
else
  fail "fitness suite failed — see /tmp/release_check_fitness.log"
  tail -40 /tmp/release_check_fitness.log | sed 's/^/        /'
fi

section "10. Whitespace errors"
if git diff --check > /tmp/release_check_whitespace.log 2>&1; then
  pass "no whitespace errors"
else
  fail "whitespace errors found"
  cat /tmp/release_check_whitespace.log | sed 's/^/        /'
fi

section "Summary"
if [[ ${#FAILED[@]} -eq 0 ]]; then
  printf "%sAll automated gates passed.%s\n\n" "$C_GRN" "$C_RST"
  cat <<'NEXT'
Manual gates still required before tagging:
  - Integration tests:   bash dev/testing/profiles/workflow-live/run.sh --full
                         plus any package-specific --run-skipped live files
  - UI smoke test:       bash dev/testing/profiles/plain/run.sh
                         (requires a running dev server)

The tag workflow builds and smoke-tests the Windows archive, tests the installer,
then publishes all five platform archives in one gated job. Re-run live Claude and
Codex turns on native Windows only after relevant provider integration changes.

After the manual gates pass, tag the already-pinned scope-frozen commit per
CLAUDE.md § Release Preparation. Do not tag from this feature branch.
NEXT
  exit 0
else
  printf "%s%d gate(s) failed:%s\n" "$C_RED" "${#FAILED[@]}" "$C_RST"
  for msg in "${FAILED[@]}"; do
    printf "  - %s\n" "$msg"
  done
  exit 1
fi
