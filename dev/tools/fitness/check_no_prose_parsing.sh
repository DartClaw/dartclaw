#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$ROOT_DIR"

# Asserts that the prose-parsing, repair-ladder and sentinel constructs the 0.25
# milestone deleted stay deleted (ADR-054's model-first rule; governance level 2
# beside dev/tools/arch_check.dart, ADR-033).
#
# Scan scope: every workspace member's production `lib/`, apps included,
# excluding generated asset data.
#
# This gate ships NO allowlist, deliberately. It does not ask "is this a prose
# parser?" — that question cannot be answered by a pattern without exempting
# the legitimate string handling the milestone keeps (code-fence and prefix
# work in text_chunking.dart and standard_markdown_converter.dart, Signal
# byte-offset formatting, cron validation, the `/stop` reserved-command fast
# path, protocol framing). It asks the narrower question a pattern CAN answer:
# has one of the named retired constructs come back? Every pattern below was
# measured at zero on the tree before it entered the set, which is what makes an
# empty allowlist honest rather than aspirational.
#
# Adding a pattern: measure it at zero first, and name the construct it retires.
# A pattern that already matches is evidence a deletion did not land — that is a
# finding against the story that owned the deletion, never an exemption here.

rg_scan() {
  local description="$1" output rc
  shift
  output="$(rg "$@" 2>&1)" && rc=0 || rc=$?
  case "$rc" in
    0) printf '%s' "$output" ;;
    1) ;;
    *)
      echo "Fitness function failed: rg scan error (exit $rc): $description" >&2
      [[ -z "$output" ]] || echo "$output" >&2
      return 2
      ;;
  esac
}

fail() {
  echo "Fitness function failed: $1"
  echo "$2"
  echo
  echo "Each construct above was deleted by the 0.25 milestone because it derived a"
  echo "value from model or user prose instead of from a declared contract. Take the"
  echo "value from the schema, the envelope or the typed field that replaced it."
  exit 1
}

lib_globs=(-g 'packages/*/lib/**/*.dart' -g 'apps/*/lib/**/*.dart' -g '!**/generated/*')

# 1. Retired workflow-output recovery, claim repair and review-count derivation.
#    Deleted with the execution envelope: outputs come from the validated
#    envelope, never from fenced JSON, tool-output lines or assistant prose.
retired_symbols='safeChangedFileSystemMatches|changedFileSystemOutputClaims|safeFileSystemOutputClaims'
retired_symbols+='|relativeClaimCandidates|resolveExistingPathOrParent|isReviewArtifactPathOutput'
retired_symbols+='|hasReviewArtifactPattern|declaresReviewCounts|payloadHasReviewCounts'
retired_symbols+='|deriveReviewCountFromStructuredOutputs|deriveReviewFindingCountFromMap'
retired_symbols+='|deriveReviewFindingCountFromVerdict|deriveReviewFindingCount|asVerdictMap'
retired_symbols+='|isReviewFindingCountKey|findIntegerValue|isGatingFinding|isValidReviewFindingSeverity'
# 2. Retired chat grammars: the review command grammar and the advisor mention
#    detector, both replaced by tool surfaces with closed schemas.
retired_symbols+='|ReviewCommandParser|ReviewCommandDispatcher|ReviewCommand|AdvisorMentionEvent|AdvisorInsightEvent'

# Not `-w`: `_` is a word character, so a word-boundary match cannot see
# `_deriveReviewFindingCount` — a private rename under `lib/src`, which is the
# idiomatic way to reintroduce a helper that used to be library-level public.
# The explicit left boundary admits the leading underscore and still refuses a
# longer identifier that merely ends in one of these names (`TasksReviewCommand`).
symbol_pattern="(?:^|[^A-Za-z0-9])_?(?:$retired_symbols)\\b"
symbol_matches="$(rg_scan 'retired prose-parsing symbols' "$symbol_pattern" "${lib_globs[@]}" --with-filename -n .)"
symbol_matches="$(printf '%s' "$symbol_matches" | sed '/^$/d')"
[[ -z "$symbol_matches" ]] || fail 'a retired prose-parsing / repair-ladder symbol is back in production source.' "$symbol_matches"

mention_matches="$(rg_scan 'retired advisor mention' '@advisor' "${lib_globs[@]}" --with-filename -n .)"
mention_matches="$(printf '%s' "$mention_matches" | sed '/^$/d')"
[[ -z "$mention_matches" ]] || fail 'the retired @advisor channel-mention detector is back in production source.' "$mention_matches"

# 3. The literal string 'null' as a path sentinel on the artifact-claim path.
#    Scoped to the two files that carried it: repo-wide, `'null'` is legitimate
#    as a JSON Schema type name (execution_envelope_schema.dart) and as the
#    authored `== null` gate grammar (gate_evaluator.dart), and excluding those
#    would be the allowlist this gate refuses to ship. A missing file fails
#    rather than silently scanning nothing.
#
#    The reach is those two files, not claim resolution in general: a third file
#    doing the same thing would escape. That is the price of the empty
#    allowlist, and it is the narrower half of this gate.
claim_files=(
  packages/dartclaw_workflow/lib/src/workflow/context_extractor.dart
  packages/dartclaw_workflow/lib/src/workflow/produced_artifact_resolver.dart
)
missing=()
for file in "${claim_files[@]}"; do
  [[ -f "$file" ]] || missing+=("$file")
done
if (( ${#missing[@]} > 0 )); then
  echo "Fitness function failed: the artifact-claim sentinel scan names files that no longer exist:"
  printf '  %s\n' "${missing[@]}"
  echo "Re-key the scan to where claim resolution now lives, or drop it with the code."
  exit 1
fi

sentinel_matches="$(rg_scan 'null path sentinel' "[!=]=\s*'null'|'null'\s*[!=]=" "${claim_files[@]}" --with-filename -n)"
sentinel_matches="$(printf '%s' "$sentinel_matches" | sed '/^$/d')"
[[ -z "$sentinel_matches" ]] || fail "the literal string 'null' is a path sentinel again on the artifact-claim path." "$sentinel_matches"

# The globs above are hand-written, while the workspace's member set is declared
# in the root pubspec. Compare the two, so a member added outside packages/ or
# apps/ fails here rather than going unscanned.
scanned_count="$(rg --files "${lib_globs[@]}" . | wc -l | tr -d ' ')"
declared_count=0
while IFS= read -r member; do
  [[ -d "$member/lib" ]] || continue
  declared_count=$((declared_count + $(find "$member/lib" -name '*.dart' -not -path '*/generated/*' | wc -l | tr -d ' ')))
done < <(sed -n '/^workspace:/,/^[^ ]/p' pubspec.yaml | sed -n 's/^[[:space:]]*-[[:space:]]*\(.*\)$/\1/p')

if [[ "$scanned_count" != "$declared_count" ]]; then
  echo "Fitness function failed: the scan reached $scanned_count production files, but the root pubspec's"
  echo "workspace members hold $declared_count. A member outside packages/ or apps/ is invisible to this gate."
  echo "Widen lib_globs to cover it."
  exit 1
fi

echo "Fitness function passed: no retired prose-parsing, repair-ladder or sentinel construct in $scanned_count production files."
