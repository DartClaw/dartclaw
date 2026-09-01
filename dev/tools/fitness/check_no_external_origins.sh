#!/usr/bin/env bash
# Fails when a served surface would load a subresource from an external origin.
#
# Scope is deliberately narrow: subresource tags in the served templates, CSS
# fetched by the served stylesheets, and the CSP that would have to permit them.
# Outbound <a href> navigation, code comments and VENDORS.md upgrade commands
# are outside the scan by construction rather than by allowlist.
#
# Every detector runs multiline (-U) so that whitespace between an attribute
# name, its '=' and its value may span a line break. A line-based grep would
# pass a re-introduced CDN reference that a formatter had wrapped.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$ROOT_DIR"

TEMPLATES_DIR="packages/dartclaw_runtime/lib/src/templates"
STATIC_DIR="packages/dartclaw_runtime/lib/src/static"
CSP_FILE="packages/dartclaw_runtime/lib/src/auth/security_headers.dart"

# [\x22\x27] is ["'] written to avoid shell quoting ambiguity.
# (https?:)? makes the scheme optional so protocol-relative //cdn… is caught.
PAT_TAG='<(link|script|img|iframe|source)\b[^>]*?\b(src|srcset|href)\s*=\s*[\x22\x27]?(https?:)?//'
PAT_IMPORT='@import\s+(url\(\s*)?[\x22\x27]?(https?:)?//'
PAT_URL='url\(\s*[\x22\x27]?(https?:)?//'

for path in "$TEMPLATES_DIR" "$STATIC_DIR" "$CSP_FILE"; do
  if [[ ! -e "$path" ]]; then
    echo "external-origin check: scan target missing, refusing to pass vacuously: $path" >&2
    exit 2
  fi
done

status=0

# rg exits 0 on a match, 1 on no match, and >1 on an error. Treating "not 0" as
# clean would make a moved directory or a missing rg pass silently forever.
scan() {
  local description="$1" pattern="$2" rc
  shift 2
  rg -U -n --no-heading --color never -e "$pattern" "$@" && rc=0 || rc=$?
  case "$rc" in
    0) echo "external-origin check: $description" >&2; status=1 ;;
    1) ;;
    *) echo "external-origin check: scan failed (rg exit $rc): $description" >&2; exit 2 ;;
  esac
}

# CSS detectors also run over the templates so an inline <style> block or a
# style="…url(…)" attribute cannot smuggle in what the tag detector misses.
scan "external subresource in $TEMPLATES_DIR" "$PAT_TAG" "$TEMPLATES_DIR"
scan "external @import in $TEMPLATES_DIR" "$PAT_IMPORT" "$TEMPLATES_DIR"
scan "external url() in $TEMPLATES_DIR" "$PAT_URL" "$TEMPLATES_DIR"
scan "external @import in $STATIC_DIR" "$PAT_IMPORT" --glob '*.css' "$STATIC_DIR"
scan "external url() in $STATIC_DIR" "$PAT_URL" --glob '*.css' "$STATIC_DIR"
scan "external origin in $CSP_FILE" 'https?://' "$CSP_FILE"

if [[ "$status" -ne 0 ]]; then
  echo "external-origin check: every runtime dependency must be vendored under $STATIC_DIR" >&2
fi

exit "$status"
