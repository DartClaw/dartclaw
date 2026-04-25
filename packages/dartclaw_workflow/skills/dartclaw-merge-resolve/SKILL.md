---
name: dartclaw-merge-resolve
description: Resolve a story-branch merge conflict against the integration branch via mechanical merge + LLM-driven semantic resolution + verification, committing all-or-nothing.
argument-hint: ""
user-invocable: false
workflow:
  default_prompt: "Run dartclaw-merge-resolve to resolve any merge conflicts on this story branch against the integration branch, verify the result, and commit all-or-nothing."
  default_outputs:
    merge_resolve.outcome:
      format: text
      description: "Outcome of the merge resolution attempt: one of 'resolved', 'failed', or 'cancelled'."
    merge_resolve.conflicted_files:
      format: json
      description: "JSON array of relative file paths that had conflict markers, sourced from `git diff --name-only --diff-filter=U` (sorted lexicographically). Empty array when the mechanical merge produced no markers."
    merge_resolve.resolution_summary:
      format: text
      description: "Prose summary of the resolution rationale and steps taken. Non-empty for all terminal outcomes; empty string only when zero reasoning was produced before termination."
    merge_resolve.error_message:
      format: text
      description: "Error or cancellation message. Null (emit the literal string 'null') when outcome is 'resolved'; a non-empty string for 'failed' or 'cancelled'."
---

# DartClaw Merge Resolve

LLM-driven merge conflict resolution for DartClaw story-branch worktrees. Runs exclusively via the bang (`!`) operator — no Dart-side git logic.

> **DC-NATIVE SKILL — SCOPE NOTE** (ADR-025): This skill implements DartClaw-internal plumbing (agent-resolved merge, FR1). It is workflow-internal and not user-invocable directly. Bang-operator (`!command`) semantics are identical on Claude Code and Codex — verified by S57 SPIKE-1.

## INPUTS — Environment Variables

The following env vars are injected by the S60 plumbing on process spawn. `$VAR` expands at runtime against the process environment via the bang operator.

### Required

- `MERGE_RESOLVE_INTEGRATION_BRANCH` — full branch name to merge into the story branch (e.g. `feat/0.16.4`)
- `MERGE_RESOLVE_STORY_BRANCH` — current story branch name (used in log/commit messages)
- `MERGE_RESOLVE_TOKEN_CEILING` — per-attempt token budget (informational; harness enforces the ceiling)

### Optional (absent or empty = skip that verification check)

- `MERGE_RESOLVE_VERIFY_FORMAT` — shell command to verify formatting (e.g. `dart format --set-exit-if-changed .`)
- `MERGE_RESOLVE_VERIFY_ANALYZE` — shell command to run static analysis (e.g. `dart analyze`)
- `MERGE_RESOLVE_VERIFY_TEST` — shell command to run tests (e.g. `dart test`)

## FAIL-FAST: Required Env Vars

Before doing anything else, check that the three required env vars are set:

```
!sh -c 'test -n "$MERGE_RESOLVE_INTEGRATION_BRANCH" && echo ENV_OK || echo ENV_MISSING_INTEGRATION_BRANCH'
!sh -c 'test -n "$MERGE_RESOLVE_STORY_BRANCH" && echo ENV_OK || echo ENV_MISSING_STORY_BRANCH'
!sh -c 'test -n "$MERGE_RESOLVE_TOKEN_CEILING" && echo ENV_OK || echo ENV_MISSING_TOKEN_CEILING'
```

If any required var is unset (output contains `ENV_MISSING_*`), terminate immediately with:
- `merge_resolve.outcome`: `"failed"`
- `merge_resolve.error_message`: `"MERGE_RESOLVE_INTEGRATION_BRANCH unset"` (or the appropriate var name)
- `merge_resolve.conflicted_files`: `[]`
- `merge_resolve.resolution_summary`: `""`
- **Do not proceed** to any git operations.

## STEP 1 — Detect Conflict State

Run both commands to understand the current state:

```
!git status --porcelain
!git diff --name-only --diff-filter=U
```

The output of `!git diff --name-only --diff-filter=U` is the **canonical source** for `merge_resolve.conflicted_files`. Collect those paths; sort them lexicographically. If no paths are returned, `conflicted_files` is `[]`.

## STEP 2 — Mechanical Merge

Attempt a mechanical merge of the integration branch:

```
!sh -c 'git merge "$MERGE_RESOLVE_INTEGRATION_BRANCH" --no-edit && echo MERGE_OK || echo MERGE_FAIL'
```

- If output is `MERGE_OK`: no conflict markers were produced — proceed directly to **STEP 4** (verification).
- If output is `MERGE_FAIL`: conflict markers were produced — proceed to **STEP 3** (semantic resolution).

**Note**: `!git merge "$MERGE_RESOLVE_INTEGRATION_BRANCH" --no-edit` is the canonical merge invocation. Do NOT use `git merge --abort`, `git reset --hard`, or `git clean -fd` — cleanup is plumbing's responsibility (BPC-29).

## STEP 3 — LLM-Driven Semantic Resolution

For each file listed by `!git diff --name-only --diff-filter=U`:

1. Read the file content to locate all conflict markers (`<<<<<<<`, `=======`, `>>>>>>>`).
2. For each conflict region, reason about which side's changes should be preserved, merged, or synthesized. Preserve both sides' intent where possible. Record the rationale for `merge_resolve.resolution_summary`.
3. Rewrite the file with all conflict markers (`<<<<<<<`, `=======`, `>>>>>>>`) removed and the resolved content in place.
4. After editing all files, run: `!git diff --name-only --diff-filter=U` — if any paths remain, repeat for those files.

Accumulate reasoning notes throughout; these become `merge_resolve.resolution_summary`.

## STEP 4 — Verification Chain

Run these checks in order. For each check, use output-encoded status (not bare exit-code branching):

### 4a. No remaining conflict markers

Scan every file that was in the conflict list (from STEP 1) for any remaining `<<<<<<<` marker, then run `git diff --check` via the bang operator:

```
!git diff --check
```

If the command exits non-zero (any output produced): there are unresolved whitespace/marker issues — enter the remediation loop (STEP 5). Use output-encoded status:

```
!sh -c 'git diff --check && echo DIFF_CHECK_OK || echo DIFF_CHECK_FAIL'
```

### 4b. Optional format verification

```
!sh -c 'test -z "$MERGE_RESOLVE_VERIFY_FORMAT" && echo FORMAT_SKIP || (eval "$MERGE_RESOLVE_VERIFY_FORMAT" && echo FORMAT_OK || echo FORMAT_FAIL)'
```

- `FORMAT_SKIP`: env var absent or empty — skip cleanly, no error.
- `FORMAT_OK`: format check passed.
- `FORMAT_FAIL`: format check failed — enter the remediation loop (STEP 5) for formatting.

### 4c. Optional static analysis

```
!sh -c 'test -z "$MERGE_RESOLVE_VERIFY_ANALYZE" && echo ANALYZE_SKIP || (eval "$MERGE_RESOLVE_VERIFY_ANALYZE" && echo ANALYZE_OK || echo ANALYZE_FAIL)'
```

- `ANALYZE_SKIP`: skip cleanly.
- `ANALYZE_OK`: analysis passed.
- `ANALYZE_FAIL`: analysis failed — enter the remediation loop (STEP 5).

### 4d. Optional test run

```
!sh -c 'test -z "$MERGE_RESOLVE_VERIFY_TEST" && echo TEST_SKIP || (eval "$MERGE_RESOLVE_VERIFY_TEST" && echo TEST_OK || echo TEST_FAIL)'
```

- `TEST_SKIP`: skip cleanly.
- `TEST_OK`: tests passed.
- `TEST_FAIL`: tests failed — enter the remediation loop (STEP 5).

If all checks pass (OK or SKIP), proceed to **STEP 6** (commit).

## STEP 5 — Internal Remediation Loop

When any verification check fails:

1. Identify the offending file(s) from the failure output.
2. Edit the file(s) to fix the issue (reformatting, resolving analysis errors, fixing test failures).
3. Re-run the **entire** verification chain (STEP 4a through 4d).
4. Repeat until all checks pass or the token budget (`MERGE_RESOLVE_TOKEN_CEILING`) is exhausted.

**Token ceiling exhaustion**: If you detect that you are approaching the token ceiling and verification is still failing, terminate with:
- `merge_resolve.outcome`: `"failed"`
- `merge_resolve.error_message`: `"token_ceiling exceeded at <stage>"` where `<stage>` is one of `format`, `analyze`, `test`, or `marker-resolution` (whichever was active when the budget ran out)
- `merge_resolve.conflicted_files`: the paths from STEP 1
- `merge_resolve.resolution_summary`: whatever partial reasoning was produced
- **Skip the commit step entirely — do not proceed to STEP 6.**

## STEP 6 — All-or-Nothing Commit

**Only reach this step after the entire verification chain (STEP 4) has passed without any FAIL output.**

Run exactly one commit:

```
!git add -A
!git commit -m "merge: resolve conflicts from $MERGE_RESOLVE_INTEGRATION_BRANCH into $MERGE_RESOLVE_STORY_BRANCH"
```

After a successful commit, emit the final output (STEP 7) with `outcome: "resolved"`.

**Absolute prohibition**: On any failure or cancellation path, do NOT invoke `git merge --abort`, `git reset` (any form), or `git clean` (any form) via the bang operator. These operations are plumbing's responsibility (BPC-29). The skill must never run them.

## STEP 7 — Emit Structured Output

Emit all four output fields on **every** terminal path:

### Success path (`outcome: "resolved"`)

```
merge_resolve.outcome: resolved
merge_resolve.conflicted_files: ["path/a.dart", "path/b.dart"]   ← sorted lexicographically from STEP 1; [] if mechanical merge was clean
merge_resolve.resolution_summary: <non-empty prose: what was resolved and why>
merge_resolve.error_message: null
```

### Failure path (`outcome: "failed"`)

```
merge_resolve.outcome: failed
merge_resolve.conflicted_files: ["..."]   ← from STEP 1
merge_resolve.resolution_summary: <whatever partial reasoning was produced; "" only if none>
merge_resolve.error_message: <non-empty: e.g. "token_ceiling exceeded at format", "MERGE_RESOLVE_INTEGRATION_BRANCH unset">
```

### Cancellation path (`outcome: "cancelled"`)

```
merge_resolve.outcome: cancelled
merge_resolve.conflicted_files: ["..."]   ← best available from STEP 1, or [] if cancelled before detection
merge_resolve.resolution_summary: <partial reasoning; "" only if none>
merge_resolve.error_message: cancelled by harness
```

## OPERATIONAL NOTES

- **Bang-operator semantics**: `$VAR` expands at runtime against the spawned-process environment on both Claude Code and Codex (verified S57 SPIKE-1). Do not template-substitute env-var values at manifest time.
- **Exit codes**: exit codes from `!command` are not directly readable in skill prompts. All branching uses output-encoded status (`&& echo OK || echo FAIL` pattern), never bare `if !cmd; then`.
- **Cross-harness**: this prompt uses only bang operator + `$VAR` expansion + structured-output declaration — constructs supported identically on Claude Code and Codex.
- **Per-attempt latency**: aim for decisive action; p95 < 2 minutes; hard cap via `MERGE_RESOLVE_TOKEN_CEILING`.
