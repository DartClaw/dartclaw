# Feature Implementation Specification — S34: ClaudeSettingsBuilder + Token-Parse Helper Consolidation + Workflow Task-Config Typed Accessors

**Plan**: ../plan.md
**Story-ID**: S34

## Feature Overview and Goal

Four-part DRY consolidation across the harness/runner/workflow seam: (A) extract the ~100 LOC of byte-identical Claude-settings building from `claude_code_harness.dart` and `workflow_cli_runner.dart` into a shared `ClaudeSettingsBuilder` in `dartclaw_core`; (B) replace `_parseClaude`/`_parseCodex` inline `(x as num?)?.toInt()` casts with the existing `intValue`/`stringValue` helpers from `base_protocol_adapter.dart`; (C) extract a single canonical `normalizeDynamicMap` helper into a neutral `dartclaw_core/lib/src/util/` module and route all three current `_stringifyDynamicMap` / equivalent sites through it; (D) extend the existing `WorkflowTaskConfig` typed-accessor surface to cover the remaining cross-package, workflow-internal, and server-side `_workflow*` / `_dartclaw.internal.*` keys, migrate the two server-side reads (`task_config_view.dart:52,54` and `workflow_one_shot_runner.dart:77`), and drop those entries from the fitness allowlist. Zero behaviour change — JSON wire format byte-stable; existing test suites pass without modification.

> **Technical Research**: [.technical-research.md](../.technical-research.md) — Story-Scoped File Map § "S34 — Extract `ClaudeSettingsBuilder` + Token-Parse Helper Consolidation + Workflow task-config typed accessors" and Shared Decisions #22, #23, #24.


## Required Context

### From `dev/specs/0.16.5/plan.md` — "[P] S34: Extract `ClaudeSettingsBuilder` + Token-Parse Helper Consolidation"
<!-- source: dev/specs/0.16.5/plan.md#p-s34-extract-claudesettingsbuilder--token-parse-helper-consolidation -->
<!-- extracted: e670c47 -->
> **Scope**: Three related consolidations around `workflow_cli_runner.dart` and `claude_code_harness.dart`.
>
> **Part A — ClaudeSettingsBuilder**: Extract the 100 LOC of byte-identical helpers from `workflow_cli_runner.dart:497-627` and `claude_code_harness.dart:541-668` into a new `packages/dartclaw_core/lib/src/harness/claude_settings_builder.dart` (pure utility class, no Process I/O). Both call sites import it. Current duplicates already drifted on accepted `permissionMode` values (harness accepts all six; runner rejects the interactive four) — the shared parser becomes the canonical spec; the runner's stricter "reject interactive modes" validation stays as a second check layered on top, with an explicit comment explaining why.
>
> **Part B — Token-parse helper alignment**: `WorkflowCliRunner._parseClaude` at `:387-392` and `_parseCodex` at `:420-428` reinvent `(x as num?)?.toInt()` / `(x as String?)` casts when `base_protocol_adapter.dart` already exports `intValue(x)` / `stringValue(x)` helpers. Replace the inline casts. **Note on correctness**: the token-normalization bug itself (Codex `input_tokens` not subtracting `cached_input_tokens`) is already covered by private repo `docs/specs/0.16.4/fis/s43-token-tracking-cross-harness-consistency.md` — **this story does not re-fix the correctness issue**; it only closes the remaining DRY gap (inline casts → helper calls; shared normalize-dynamic-map utility with Part A).
>
> **Part C — Shared `normalizeDynamicMap` helper**: `_stringifyDynamicMap` in `claude_code_harness.dart:604-625`, `workflow_cli_runner.dart:561-598`, and `_normalizeWorkflowOutputs` in `workflow_executor.dart:2906-2992` all implement variants of "recursively walk a `Map<dynamic, dynamic>` → typed `Map<String, dynamic>`". Extract one canonical helper into `dartclaw_core/lib/src/util/dynamic_reader.dart` (or an equivalent neutral module) and route all three sites to it. Pair with S13's `YamlTypeSafeReader` (Part B) spiritually — this is the Process/JSON side of the same pattern.
>
> **Part D — Workflow task-config accessors/constants (TD-070 + TD-066 + TD-103 bridge)**: Centralise the private workflow task-config keys shared between workflow/server/core boundaries. **Cross-package surface**: `_workflowFollowUpPrompts`, `_workflowStructuredSchema`, `_workflowMergeResolveEnv`, `_dartclaw.internal.validationFailure`, and the token-metric keys currently tracked by TD-066. **Workflow-internal surface**: also include `_workflowGit`, `_workflowWorkspaceDir`, `_continueSessionId`, `_sessionBaselineTokens`, `_mapIterationIndex`. **Server-side reads (closes TD-103)**: also include `_workflowNeedsWorktree` and any other `_workflow*` literals enumerated in `dev/tools/fitness/check_no_workflow_private_config.sh` `ALLOWED_FILES`; migrate the two server reads at `task_config_view.dart:52,54` and `workflow_one_shot_runner.dart:77` to the typed accessor; drop those entries from `ALLOWED_FILES` once the migration is in place. The immediate goal is not a repository schema migration; it is to stop adding string literals by hand. Add a tiny typed/constant access surface in the owning package, route existing writers/readers through it, and document the rule: new underscored workflow task-config keys require extending the typed surface.
>
> **Acceptance Criteria**:
> - `ClaudeSettingsBuilder` exists in `dartclaw_core/harness/`; two call sites delete their private helpers and import it (must-be-TRUE)
> - `permissionMode` validation differences documented: shared parser accepts the full set; runner's "reject interactive" is a clearly-commented second-pass validation
> - `_parseClaude` / `_parseCodex` use `intValue` / `stringValue` from `base_protocol_adapter.dart` for all JSON extractions; zero inline `(x as num?)?.toInt()` remaining (must-be-TRUE)
> - `normalizeDynamicMap` helper exists in a neutral dartclaw_core (or equivalent) module; three call sites route through it (must-be-TRUE)
> - Workflow task-config keys listed in Part D — both cross-package and workflow-internal — have a central typed/constant accessor surface; no duplicated string literals remain at existing writer/reader call sites (must-be-TRUE)
> - A short comment or architecture note states that new underscored workflow task-config keys must be added to the typed surface rather than ad hoc literals
> - Net LOC reduction ≥150 across `workflow_cli_runner.dart` + `claude_code_harness.dart` + `workflow_executor.dart`
> - `dart test packages/dartclaw_core packages/dartclaw_server packages/dartclaw_workflow` all pass
> - `workflow_cli_runner_test.dart` continues to pass; no behavior change

### From `dev/specs/0.16.5/prd.md` — "Constraints"
<!-- source: dev/specs/0.16.5/prd.md#constraints -->
<!-- extracted: e670c47 -->
> - **No new user-facing features.** Any feature-shaped work defers to 0.16.6+.
> - **No breaking protocol changes.** JSONL control protocol, REST payloads, SSE envelope format all stable.
> - **No new dependencies** in any package.
> - **Workspace-wide strict-casts + strict-raw-types** must remain on throughout.

### From `dev/specs/0.16.5/prd.md` — Binding Constraints (Applies to S34)
<!-- source: dev/specs/0.16.5/prd.md#fr10-api-polish--readability-delta-review-additions -->
<!-- extracted: e670c47 -->
> - #2 — No new dependencies in any package.
> - #21 — `testing_package_deps_test.dart` + `no_cross_package_env_plan_duplicates_test.dart` fitness functions pass.
> - #48 — `ClaudeSettingsBuilder`: pure-utility class in `dartclaw_core/harness/`; both `claude_code_harness.dart` and `workflow_cli_runner.dart` delete their private helpers and import it (≥100 LOC duplication removed).
> - #49 — `_parseClaude` / `_parseCodex` use `intValue` / `stringValue` from `base_protocol_adapter.dart`; zero inline `(x as num?)?.toInt()` remaining.
> - #50 — Shared `normalizeDynamicMap` helper: 3 sites route through one canonical utility.
> - #51 — Workflow task-config accessors/constants: cross-package, workflow-internal, and server-side keys route through a central typed/constant surface.
> - #52 — Task-config policy enforcement note: "new underscored workflow task-config keys must be added to the typed surface rather than ad hoc literals".
> - #71 — Behavioural regressions post-decomposition: Zero — every existing test remains green.
> - #75 — `WorkflowCliRunner` ownership recorded as ADR-023 addendum (S31 — referenced; S34 must respect the boundary).
> - #77 — Slip candidates: S35, S36, S38. **S32/S33/S34 are NOT slip candidates**.

### From `dev/state/TECH-DEBT-BACKLOG.md` — "TD-103 — Refactor server-side `_workflow*` task-config reads behind a typed accessor"
<!-- source: dev/state/TECH-DEBT-BACKLOG.md#td-103 -->
<!-- extracted: e670c47 -->
> Two server-side files (`packages/dartclaw_server/lib/src/task/workflow_one_shot_runner.dart`, `packages/dartclaw_server/lib/src/task/task_config_view.dart`) read `_workflow*` keys directly out of `task.configJson`. The fitness function `dev/tools/fitness/check_no_workflow_private_config.sh` allowlists both. After S34, both reads route through `WorkflowTaskConfig` typed accessors and the allowlist entries are removed.


## Deeper Context

- `dev/specs/0.16.5/.technical-research.md#s34--extract-claudesettingsbuilder--token-parse-helper-consolidation--workflow-task-config-typed-accessors` — Story-scoped file map: target paths for `ClaudeSettingsBuilder`, `dynamic_reader.dart`, `WorkflowTaskConfig` extension; current line ranges for the three `_stringifyDynamicMap` sites and the two server-side reads.
- `dev/specs/0.16.5/.technical-research.md#shared-architectural-decisions` — Shared Decision #22 (`ClaudeSettingsBuilder` location + `permissionMode` validation policy), #23 (`normalizeDynamicMap` location), #24 (Workflow task-config typed-accessor surface scope and migration targets).
- `packages/dartclaw_core/CLAUDE.md` — package-scoped rules: pure-utility helpers under `lib/src/harness/` and `lib/src/util/` are sanctioned; no Process I/O; barrel exports use `show`.
- `packages/dartclaw_workflow/CLAUDE.md` — boundary rules; existing `WorkflowTaskConfig` lives in this package and stays there. Cross-package keys consumed from `dartclaw_server` route through this seam; workflow-internal keys also route through it.
- `packages/dartclaw_server/CLAUDE.md` — `WorkflowCliRunner` and `workflow_one_shot_runner.dart` stay in `dartclaw_server`; do not move down. `task_config_view.dart` is the typed wrapper around `Task` for server-side reads — extend it to defer `_workflow*` reads to `WorkflowTaskConfig`.
- `packages/dartclaw_workflow/lib/src/workflow/workflow_task_config.dart` — existing typed-accessor seam; this story extends it.


## Success Criteria (Must Be TRUE)

> Each criterion has a proof path: a Scenario (behavioral) or task Verify line (structural).

### Part A — ClaudeSettingsBuilder

- [ ] **`ClaudeSettingsBuilder` pure-utility class exists** at `packages/dartclaw_core/lib/src/harness/claude_settings_builder.dart` with a `build(...)` static method (or equivalent stable surface) that returns the assembled settings map; **no Process I/O, no `dart:io` imports** (proof: TI01 Verify; binding constraint #48)
- [ ] **`claude_code_harness.dart` deletes its private builder block** at the current `_claudeSettings` / `_claudePermissionMode` / `_deepMergeInto` / `_stringifyDynamicMap` cluster and imports `ClaudeSettingsBuilder` (proof: TI02 Verify)
- [ ] **`workflow_cli_runner.dart` deletes its private builder block** at the current `_claudeSettings` / `_claudePermissionMode` / `_deepMergeInto` / `_stringifyDynamicMap` cluster and imports `ClaudeSettingsBuilder` (proof: TI03 Verify)
- [ ] **`permissionMode` validation differences documented**: the shared `ClaudeSettingsBuilder` parses the full canonical set (`acceptEdits`, `bypassPermissions`, `default`, `plan`, `ask`, `deny`); the runner's stricter "reject interactive modes" check lives as a clearly-commented second-pass validation in `workflow_cli_runner.dart` and is invoked **after** `ClaudeSettingsBuilder` produces its result (proof: TI03 Verify; Scenario "Edge — interactive `permissionMode: 'ask'` rejected by runner second-pass")

### Part B — Token-Parse Helper Alignment

- [ ] **`WorkflowCliRunner._parseClaude` and `_parseCodex` use `intValue`/`stringValue`** from `package:dartclaw_core/dartclaw_core.dart` (re-exported via the existing `base_protocol_adapter.dart` surface) for every numeric/string extraction from JSON maps; **zero inline `(x as num?)?.toInt()` or `(x as String?)` remain anywhere in `workflow_cli_runner.dart`** (proof: TI04 Verify; binding constraint #49)

### Part C — Shared `normalizeDynamicMap`

- [ ] **`normalizeDynamicMap` helper exists** at `packages/dartclaw_core/lib/src/util/dynamic_reader.dart` (new file or new function in an existing util module if one is already present after S13). Function signature: `Map<String, dynamic> normalizeDynamicMap(Map<dynamic, dynamic> source)`; recursively walks nested maps and lists, returning a fully `String`-keyed map with non-`Map`/non-`List` values passed through unchanged (proof: TI05 Verify; binding constraint #50)
- [ ] **Three call sites route through `normalizeDynamicMap`**:
  - `claude_code_harness.dart:652-660` (current `_stringifyDynamicMap`) deleted; calls replaced (proof: TI06 Verify)
  - `workflow_cli_runner.dart:719-727` (current `_stringifyDynamicMap`) deleted; calls replaced (proof: TI07 Verify)
  - The closest `_normalizeWorkflowOutputs`-equivalent in `dartclaw_workflow` (after the 0.16.4 S45 decomposition the helper has migrated; the agent must locate the current home — likely one of `step_outcome_normalizer.dart`, `produced_artifact_resolver.dart`, `context_output_defaults.dart`, or `workflow_executor_helpers.dart` — and replace its inline `Map<dynamic, dynamic> => dynamicMap.map(...)` walk with a call to the shared helper) (proof: TI08 Verify)

### Part D — Workflow Task-Config Typed Accessors

- [ ] **`WorkflowTaskConfig` extended to cover the full key set listed in Shared Decision #24** — cross-package (`_workflowFollowUpPrompts`, `_workflowStructuredSchema`, `_workflowMergeResolveEnv`, `_dartclaw.internal.validationFailure`, token-metric keys), workflow-internal (`_workflowGit`, `_workflowWorkspaceDir`, `_continueSessionId`, `_sessionBaselineTokens`, `_mapIterationIndex`), server-side (`_workflowNeedsWorktree`). Each key has either a typed accessor method or a `static const String` constant on `WorkflowTaskConfig` so callers reference the constant rather than a literal (proof: TI09 Verify; binding constraint #51)
- [ ] **`task_config_view.dart` migrated**: lines 52,54 (the two `_workflowNeedsWorktree` reads in `needsWorktree`) read through `WorkflowTaskConfig` (constant or accessor) — no string literal `'_workflowNeedsWorktree'` remains in `task_config_view.dart` (proof: TI10 Verify)
- [ ] **`workflow_one_shot_runner.dart` migrated**: line 77 (the `_workflowMergeResolveEnv` read for `mergeResolveEnvRaw`) reads through `WorkflowTaskConfig` (constant or accessor) — no string literal `'_workflowMergeResolveEnv'` remains in `workflow_one_shot_runner.dart` for that read (proof: TI11 Verify)
- [ ] **Fitness allowlist tightened**: `dev/tools/fitness/check_no_workflow_private_config.sh` `ALLOWED_FILES` array no longer contains `packages/dartclaw_server/lib/src/task/workflow_one_shot_runner.dart` or `packages/dartclaw_server/lib/src/task/task_config_view.dart`; the script's TD-103 follow-up note in the header comment is updated to read "Resolved by 0.16.5 S34" (proof: TI12 Verify; runs `bash dev/tools/fitness/check_no_workflow_private_config.sh` exit 0)
- [ ] **Architecture note documenting the typed-surface rule** added — either as a class-level dartdoc paragraph on `WorkflowTaskConfig` or as a one-line entry in `packages/dartclaw_workflow/CLAUDE.md` under **Conventions**, stating: "New underscored workflow task-config keys (`_workflow*`, `_dartclaw.internal.*`) must be added to `WorkflowTaskConfig`'s typed surface rather than referenced as ad-hoc literals." (proof: TI13 Verify; binding constraint #52)

### Cross-Cutting

- [ ] **Net LOC reduction ≥150** across the touched files measured as `(before-after)` summed over `workflow_cli_runner.dart`, `claude_code_harness.dart`, plus the workflow-package file housing the third `_stringifyDynamicMap`-equivalent. New file LOC (`claude_settings_builder.dart`, `dynamic_reader.dart`, additions to `workflow_task_config.dart`) **does not count against** the reduction — the goal is callsite weight, not workspace weight (proof: TI14 Verify)
- [ ] **All affected test suites pass byte-identically**: `dart test packages/dartclaw_core`, `dart test packages/dartclaw_server`, `dart test packages/dartclaw_workflow` all green; `packages/dartclaw_server/test/task/workflow_cli_runner_test.dart` passes with **zero edits to existing assertions** (proof: TI15 Verify; Scenario "Existing test suites pass byte-identically")

### Health Metrics (Must NOT Regress)

- [ ] `dart analyze --fatal-warnings --fatal-infos` workspace-wide clean (binding constraint #3 — strict-casts/strict-raw-types maintained)
- [ ] `dart format --set-exit-if-changed` clean for every touched file
- [ ] No new package dependencies in any `pubspec.yaml` (binding constraint #2)
- [ ] JSON wire format byte-stable: Claude settings JSON emitted by `ClaudeSettingsBuilder` matches the pre-refactor output for identical inputs; `WorkflowCliTurnResult` token field shape unchanged
- [ ] Public API barrel of `dartclaw_core` adds at most `ClaudeSettingsBuilder` and `normalizeDynamicMap` (with `show` clauses); no other re-export changes
- [ ] `WorkflowTaskConfig` public API stays additive — existing methods unchanged in signature; new methods/constants are pure additions
- [ ] `dev/tools/fitness/check_no_workflow_private_config.sh` exits 0 with the tightened allowlist (no new references to the migrated files leak in)
- [ ] `bash dev/tools/release_check.sh --quick` passes (or the equivalent gates run individually)


## Scenarios

> Scenarios as proof-of-work for behavioral criteria; structural criteria use task Verify lines.

### Workflow one-shot invokes Claude — settings byte-identical (happy path)

- **Given** a workflow run dispatches a Claude one-shot via `WorkflowCliRunner.executeTurn(provider: 'claude', ...)` with a `WorkflowCliProviderConfig` whose `options` contain `permissionMode: 'acceptEdits'`, a `settings` map with nested `permissions` and `sandbox` sub-maps, and an `extraSettingsFile` pointing at a JSON file
- **When** the runner builds the Claude settings via the shared `ClaudeSettingsBuilder`
- **Then** the resulting JSON-encoded settings string is byte-identical to the pre-refactor baseline captured by `workflow_cli_runner_test.dart` (deep-merge order, key ordering, and value types all preserved); the `--settings <json>` argument passed to the `claude` CLI binary is unchanged

### Interactive `permissionMode: 'ask'` rejected by runner second-pass (edge case — drift preservation)

- **Given** the workflow CLI runner is invoked with `options: {permissionMode: 'ask'}` (one of the four interactive modes the runner historically rejects: `ask`, `prompt`, `interactive`, `confirm`)
- **When** `executeTurn` builds the settings via `ClaudeSettingsBuilder`
- **Then** the shared builder accepts `'ask'` (no exception — it is a valid Claude permission mode); the runner's second-pass validation immediately raises a clearly-messaged exception (same exception type and message as the pre-refactor implementation) explaining that interactive permission modes are unsupported in workflow one-shot mode; the harness path (which legitimately accepts interactive modes) continues to accept `'ask'` unchanged

### Claude harness path accepts all six `permissionMode` values (boundary — drift preservation)

- **Given** an interactive Claude harness session that builds settings via the shared `ClaudeSettingsBuilder` with `options: {permissionMode: 'plan'}`
- **When** the harness applies the settings to the spawned `claude` process
- **Then** the builder accepts `'plan'` and includes it in the emitted settings JSON; no second-pass rejection fires (the rejection lives only in `workflow_cli_runner.dart`, not on the shared builder); behaviour matches pre-refactor harness behaviour byte-identically

### `_parseClaude` token extraction unchanged (regression)

- **Given** a stream-json `result` event from the Claude CLI containing `usage: {input_tokens: 1234, cache_read_input_tokens: 567, output_tokens: 89}` and `total_cost_usd: 0.0042`
- **When** `WorkflowCliRunner._parseClaude` (now using `intValue`/`stringValue`) parses the event
- **Then** `WorkflowCliTurnResult.totalInputTokens == 1234`, `cacheReadTokens == 567`, `outputTokens == 89`, `totalCostUsd == 0.0042` — byte-identical to the pre-refactor baseline; the token-correctness fix from 0.16.4 S43 (Codex `input_tokens` minus `cached_input_tokens`) is **not re-applied** by this story

### `normalizeDynamicMap` round-trip preserves nested structure

- **Given** a `Map<dynamic, dynamic>` produced by `jsonDecode` of `{"a": {"b": [1, {"c": "d"}]}, "e": null}` (which Dart represents as `Map<String, dynamic>` already, so no-op fast path applies)
- **When** `normalizeDynamicMap` walks the input
- **Then** the returned `Map<String, dynamic>` is structurally equal to the input; the nested list contains the original `int` and a recursively-normalized `Map<String, dynamic>` for the inner `{"c": "d"}`; non-`Map`/non-`List` values (`null`, `int`, `String`) pass through identity-equal

### `normalizeDynamicMap` on YAML-decoded input — non-string keys coerced

- **Given** a `Map<dynamic, dynamic>` produced by `package:yaml` decoding of `{1: "one", "nested": {2: "two"}}` (YAML allows non-string keys)
- **When** `normalizeDynamicMap` walks the input
- **Then** the returned map is `{"1": "one", "nested": {"2": "two"}}` — non-string keys converted via `key.toString()`, behaviour matching the pre-refactor `_stringifyDynamicMap` exactly

### Server-side `needsWorktree` reads through typed accessor (Part D — happy path)

- **Given** a workflow-orchestrated task whose `configJson` carries `_workflowNeedsWorktree: true`
- **When** server-side code accesses `TaskConfigView.needsWorktree`
- **Then** the boolean returns `true`; the read goes through `WorkflowTaskConfig` (constant or accessor) — `task_config_view.dart` contains no `'_workflowNeedsWorktree'` string literal; behaviour identical to pre-refactor

### Server-side `mergeResolveEnv` reads through typed accessor (Part D — happy path)

- **Given** a workflow-orchestrated task whose `configJson` carries `_workflowMergeResolveEnv: {'TOKEN': 'redacted'}`
- **When** `WorkflowOneShotRunner` resolves the merge-resolve env at task start
- **Then** the resulting `Map<String, String>` is `{'TOKEN': 'redacted'}`; `workflow_one_shot_runner.dart` contains no `'_workflowMergeResolveEnv'` literal at line 77; behaviour identical to pre-refactor

### Fitness allowlist rejects new `_workflow*` reads (negative path)

- **Given** the post-S34 `dev/tools/fitness/check_no_workflow_private_config.sh` allowlist no longer permits `task_config_view.dart` or `workflow_one_shot_runner.dart`
- **When** a hypothetical future change re-introduces a string-literal `_workflow*` read in either file
- **Then** the fitness check exits non-zero, naming the offending file and matched line — proving the typed-surface rule is enforced

### Existing test suites pass byte-identically (regression)

- **Given** the pre-refactor test suites for `dartclaw_core`, `dartclaw_server`, `dartclaw_workflow`
- **When** `dart test` runs against each package after the refactor
- **Then** every existing test passes with **zero edits** to existing assertions; only **additions** are allowed (new tests for `ClaudeSettingsBuilder` and `normalizeDynamicMap` direct-unit coverage are net-new)


## Scope & Boundaries

### In Scope

_Every scope item maps to at least one task with a Verify line._

- New file `packages/dartclaw_core/lib/src/harness/claude_settings_builder.dart` with `class ClaudeSettingsBuilder` — pure utility, no `dart:io`, no Process I/O (TI01)
- Delete the duplicated `_claudeSettings` / `_claudePermissionMode` / `_deepMergeInto` cluster from `claude_code_harness.dart:541-668` and replace with `ClaudeSettingsBuilder` calls (TI02)
- Delete the duplicated `_claudeSettings` / `_claudePermissionMode` / `_deepMergeInto` cluster from `workflow_cli_runner.dart:611-714` (current line range; plan referenced `:497-627` against an earlier commit) and replace with `ClaudeSettingsBuilder` calls; preserve the runner's stricter "reject interactive modes" check as a clearly-commented second-pass validation invoked after the shared builder (TI03)
- Replace inline `(x as num?)?.toInt()` / `(x as String?)` casts in `_parseClaude` (`workflow_cli_runner.dart:411+`) and `_parseCodex` (`workflow_cli_runner.dart:552+`) with `intValue` / `stringValue` from `base_protocol_adapter.dart` (TI04)
- New file `packages/dartclaw_core/lib/src/util/dynamic_reader.dart` (or extend an existing util module if S13 created one) exporting `normalizeDynamicMap(Map<dynamic, dynamic>)` (TI05)
- Re-export `normalizeDynamicMap` and `ClaudeSettingsBuilder` from the `dartclaw_core` barrel with `show` clauses (TI05, TI01)
- Migrate the three current `_stringifyDynamicMap` / equivalent sites in `claude_code_harness.dart`, `workflow_cli_runner.dart`, and the workflow-package owner of the third site (TI06, TI07, TI08)
- Extend `packages/dartclaw_workflow/lib/src/workflow/workflow_task_config.dart` with the remaining keys from Shared Decision #24, expressing each as either a typed accessor or a `static const String` constant — whichever fits the existing pattern in that file (TI09)
- Migrate `task_config_view.dart:52,54` to read through `WorkflowTaskConfig` (TI10)
- Migrate `workflow_one_shot_runner.dart:77` to read through `WorkflowTaskConfig` (TI11)
- Tighten `dev/tools/fitness/check_no_workflow_private_config.sh` `ALLOWED_FILES` array (TI12)
- Add architecture note (TI13)
- LOC verification (TI14) and full validation (TI15)

### What We're NOT Doing

- **Not re-fixing the token-normalization correctness bug** — the Codex `input_tokens` vs `cached_input_tokens` semantics are already covered by 0.16.4 S43 (private repo `docs/specs/0.16.4/fis/s43-token-tracking-cross-harness-consistency.md`). S34 closes only the DRY gap (inline casts → helper calls), not the correctness gap.
- **Not rewriting `claude_code_harness.dart` or `workflow_cli_runner.dart` structurally** — only the duplicated builder block and the inline parse-casts move. Process I/O, lifecycle, error handling, and the public surface stay byte-identical.
- **Not redesigning Claude settings semantics** — the canonical `permissionMode` set, the deep-merge order, and the JSON output shape all match pre-refactor behaviour. The drift between harness-accepts-six and runner-rejects-four is preserved as documented (shared parser canonical; runner second-pass).
- **Not refactoring `base_protocol_adapter.dart`** — the existing `intValue` / `stringValue` helpers are consumed as-is. Their location and signatures are stable.
- **Not migrating the full workflow-task-config schema to a side table** — TD-103 explicitly says "the immediate goal is not a repository schema migration; it is to stop adding string literals by hand". `Task.configJson` continues to carry the `_workflow*` keys for now; the typed accessor layer is the seam, not the storage. Full side-table migration is deferred to a future milestone.
- **Not changing the JSON wire format** — Claude settings JSON, `WorkflowCliTurnResult` shape, and SSE envelope formats are all byte-stable (binding constraint #1).
- **Not promoting `WorkflowTaskConfig` to `dartclaw_core`** — it stays in `dartclaw_workflow` per the package-boundary rule (workflow keys originate here; cross-package consumers depend on `dartclaw_workflow` already). Architecture decision section explains this choice.
- **Not deleting the `_workflow*` keys from `task.configJson`** — only the read sites move behind the typed accessor. The keys themselves remain in storage; storage migration is out of scope.

### Agent Decision Authority

- **Autonomous**:
  - Whether each Part D key gets a typed accessor method or a `static const String` constant on `WorkflowTaskConfig` — pick whichever matches the existing pattern in the file (read-only constant for keys that are simple-typed and read in one place; full accessor for keys with non-trivial coercion or multiple call sites).
  - Whether `normalizeDynamicMap` lives as a top-level function or as a static method on a `DynamicReader` class in `dynamic_reader.dart` — prefer the top-level function for symmetry with the existing `intValue`/`stringValue` shape in `base_protocol_adapter.dart`.
  - Whether `ClaudeSettingsBuilder` exposes a single `build(...)` method with named parameters or a small set of small methods (`buildPermissionMode`, `buildSettings`, `mergeExtra`) — pick whichever cleanly captures the current `_claudeSettings` / `_claudePermissionMode` / `_deepMergeInto` cluster's responsibility split. Mirror the call-site shape preserved in both the harness and the runner.
  - Where exactly the third `_stringifyDynamicMap`-equivalent lives in the post-0.16.4-decomposition `dartclaw_workflow` codebase. The plan reference (`workflow_executor.dart:2906-2992`) is stale; the agent must locate the current home (search candidates: `step_outcome_normalizer.dart`, `produced_artifact_resolver.dart`, `context_output_defaults.dart`, `workflow_executor_helpers.dart`) and migrate the closest equivalent. If multiple sites exist, migrate each.
  - Whether the architecture note for Part D lives as class-level dartdoc on `WorkflowTaskConfig` or as a `## Conventions` bullet in `packages/dartclaw_workflow/CLAUDE.md` — prefer the dartdoc location (closer to the surface) but add a one-liner pointer in `CLAUDE.md` if precedent supports it.
- **Escalate**:
  - Any change to the public signature of `WorkflowCliRunner.executeTurn` or the Claude/Codex harness public API.
  - Any change to the `WorkflowCliTurnResult` shape, `WorkflowCliProviderConfig` shape, or `WorkflowStepExecution` shape.
  - Any change that requires editing existing tests beyond pure additions.
  - Any decision to promote `WorkflowTaskConfig` (or its keys) to `dartclaw_core` — that's a future milestone's call.
  - Any change to `base_protocol_adapter.dart` itself (re-export shape, `intValue` / `stringValue` semantics).


## Architecture Decision

**We will**: Keep the workflow task-config typed surface inside the owning package (`dartclaw_workflow`) where most of the keys originate, with the existing `WorkflowTaskConfig` class extended in place. `dartclaw_server` continues to depend on `dartclaw_workflow` (via `WorkflowTaskConfig` import) for the typed access, which matches the existing dependency direction.

**Rationale**: All `_workflow*` keys originate in workflow code (`workflow_task_factory.dart` is the source of truth for building the task config map per `dev/tools/fitness/check_no_workflow_private_config.sh` header). Promoting `WorkflowTaskConfig` to `dartclaw_core` would pull workflow-specific concerns (follow-up prompts, structured-schema, merge-resolve env, git lifecycle metadata) into core, which is purpose-built for cross-package primitives. The existing `WorkflowTaskConfig` already holds the cross-package surface; adding the workflow-internal and server-side keys to the same class is a continuation of the established pattern, not a new architecture.

**Alternatives considered**:
1. **Promote `WorkflowTaskConfig` to `dartclaw_core`** — rejected: violates the package-boundary rule that workflow concerns belong in `dartclaw_workflow`; pulls in `WorkflowStepExecutionRepository` dependency to core; adds a Storage-shaped interface to a primitives package. The existing class already imports `WorkflowStepExecutionRepository` from `dartclaw_core` — that's the clean direction.
2. **Split into two classes — `CoreWorkflowTaskKeys` (constants only) in `dartclaw_core` + `WorkflowTaskConfig` (accessors) in `dartclaw_workflow`** — rejected: doubles the surface area, splits the rule across two files, and introduces a new abstraction with no current consumer. If a second non-workflow consumer appears later, this split can be done incrementally.
3. **Skip Part D entirely** — rejected: TD-103 was explicitly absorbed into S34's scope on 2026-05-04; the plan AC requires the migration and the fitness allowlist tightening. Slip would leave the typed-surface rule undocumented and the literal reads continuing to multiply.

For Part A: `ClaudeSettingsBuilder` lives in `dartclaw_core/lib/src/harness/` (Shared Decision #22) — both call sites already depend on `dartclaw_core` for harness primitives, so `core` is the natural home for the shared builder. No new dependency edges.

For Part C: `normalizeDynamicMap` lives in `dartclaw_core/lib/src/util/` (Shared Decision #23) — neutral utility module, mirrors the existing `intValue` / `stringValue` shape in `base_protocol_adapter.dart`. No package ownership ambiguity.

See ADR: `dev/state/UBIQUITOUS_LANGUAGE.md` for `WorkflowTaskConfig` term canonicalisation; `packages/dartclaw_workflow/CLAUDE.md` § Boundaries for the dependency-direction rule that pins `WorkflowTaskConfig` to `dartclaw_workflow`.


## Technical Overview

### Data Models (if applicable)

**`ClaudeSettingsBuilder`** (new, `dartclaw_core`) — pure-utility class. No state. Method `build(...)` (or equivalent) takes the same inputs the current `_claudeSettings` private helper takes (`Map<String, dynamic> options`, `String? extraSettingsFilePath`, optional sandbox / permissions overrides) and returns the assembled `Map<String, dynamic>`. The `permissionMode` parser inside accepts the canonical Claude set (`acceptEdits`, `bypassPermissions`, `default`, `plan`, `ask`, `deny`); unknown values produce the same `FormatException`-style error message the harness path produces today.

**`normalizeDynamicMap`** (new, `dartclaw_core`) — top-level function `Map<String, dynamic> normalizeDynamicMap(Map<dynamic, dynamic> source)`. Recursively walks: nested `Map<dynamic, dynamic>` → `normalizeDynamicMap(...)`; `List` → `.map((item) => item is Map<dynamic, dynamic> ? normalizeDynamicMap(item) : item).toList(growable: false)`; other values pass through. Non-string keys coerced via `'$key'`. Behaviour matches the current `_stringifyDynamicMap` exactly.

**`WorkflowTaskConfig`** (extended, `dartclaw_workflow`) — adds:
- Cross-package additions to existing surface: `_workflowMergeResolveEnv` (typed reader returning `Map<String, String>?`), `_dartclaw.internal.validationFailure` (typed reader returning `String?` or a small DTO if the existing payload shape warrants it).
- Workflow-internal keys: typed accessors or `static const String` constants for `_workflowGit`, `_workflowWorkspaceDir`, `_continueSessionId`, `_sessionBaselineTokens`, `_mapIterationIndex`. Where the workflow-internal call sites are read-only and the value is a primitive, prefer a `static const String kWorkflowGit = '_workflowGit'` (etc.) and let callers do `task.configJson[WorkflowTaskConfig.kWorkflowGit]` — this is the lightest seam that still passes the fitness check (which greps for `'_workflow` literals, so the literal lives in one file only).
- Server-side: `_workflowNeedsWorktree` constant or typed accessor consumed by `task_config_view.dart`.

### Integration Points (if applicable)

- **`packages/dartclaw_core/lib/dartclaw_core.dart`** (barrel) — adds `export 'src/harness/claude_settings_builder.dart' show ClaudeSettingsBuilder;` and `export 'src/util/dynamic_reader.dart' show normalizeDynamicMap;`. No other changes.
- **`packages/dartclaw_core/lib/src/harness/claude_code_harness.dart`** — deletes `_claudeSettings`, `_claudePermissionMode`, `_deepMergeInto`, `_stringifyDynamicMap` (lines ~541-668 + 652-660); imports `ClaudeSettingsBuilder` and `normalizeDynamicMap`; the public methods that previously called the privates now call the shared utilities.
- **`packages/dartclaw_server/lib/src/task/workflow_cli_runner.dart`** — deletes the corresponding privates (lines ~611-714 + 719-727 + 313-352 builder fragments + 387-392 + 420-428 inline casts); imports the shared utilities; preserves the runner's second-pass `permissionMode` interactive-mode rejection as a clearly-commented validation step.
- **`packages/dartclaw_workflow/lib/src/workflow/workflow_task_config.dart`** — extended in place per the data model section above.
- **`packages/dartclaw_workflow/lib/src/workflow/<owner-of-third-stringify-site>.dart`** — agent locates the current home of the third `_stringifyDynamicMap`-equivalent (search hits suggest `step_outcome_normalizer.dart:165-171`, `produced_artifact_resolver.dart:88-92` and `:104-108`, `context_output_defaults.dart:128-132`, `workflow_executor_helpers.dart:71-74` are all candidates — migrate every site whose body matches the pattern "`Map<dynamic, dynamic> dynamicMap => dynamicMap.map((key, value) => MapEntry('$key', value))`").
- **`packages/dartclaw_server/lib/src/task/task_config_view.dart`** — lines 52, 54: replace `task.configJson['_workflowNeedsWorktree']` with the typed accessor or the `WorkflowTaskConfig.kWorkflowNeedsWorktree` constant lookup.
- **`packages/dartclaw_server/lib/src/task/workflow_one_shot_runner.dart`** — line 77: replace `task.configJson['_workflowMergeResolveEnv']` with the typed accessor.
- **`dev/tools/fitness/check_no_workflow_private_config.sh`** — drops two entries from `ALLOWED_FILES`; updates the header comment to mark TD-103 as resolved by 0.16.5 S34.


## Code Patterns & External References

```
# type | path/url                                                                                          | why needed
file   | packages/dartclaw_server/lib/src/task/workflow_cli_runner.dart:159-285                            | Source — current `executeTurn` body that calls `_buildClaudeCommand` → `_claudePermissionMode` → `_claudeSettings` → `_deepMergeInto` → `_stringifyDynamicMap`; the cluster collapses behind `ClaudeSettingsBuilder.build(...)` (Part A)
file   | packages/dartclaw_server/lib/src/task/workflow_cli_runner.dart:313-352                            | Source — `_buildClaudeCommand` calling the soon-to-be-shared cluster; keep the runner-level second-pass `permissionMode` interactive-mode rejection here with an explicit comment
file   | packages/dartclaw_server/lib/src/task/workflow_cli_runner.dart:387-392 :420-428                   | Source — `_parseClaude` and `_parseCodex` inline `(x as num?)?.toInt()` / `(x as String?)` casts (Part B); replace with `intValue` / `stringValue`
file   | packages/dartclaw_server/lib/src/task/workflow_cli_runner.dart:611-714                            | Source — current private cluster `_claudePermissionMode` (`:611`) + `_claudeSettings` (`:633`) + `_deepMergeInto` + `_stringifyDynamicMap` (`:719`); delete and route through `ClaudeSettingsBuilder` + `normalizeDynamicMap`
file   | packages/dartclaw_core/lib/src/harness/claude_code_harness.dart:541-668                           | Source — duplicated `_claudeSettings` / `_claudePermissionMode` / `_deepMergeInto` cluster on the harness side (Part A); delete and route through `ClaudeSettingsBuilder`
file   | packages/dartclaw_core/lib/src/harness/claude_code_harness.dart:652-660                           | Source — duplicated `_stringifyDynamicMap` on harness side (Part C); delete and route through `normalizeDynamicMap`
file   | packages/dartclaw_core/lib/src/harness/base_protocol_adapter.dart:34-49                           | Pattern — existing `stringValue(Object?)` and `intValue(Object?)` helpers; reuse for Part B; mirror the function-shape for Part C's `normalizeDynamicMap`
file   | packages/dartclaw_workflow/lib/src/workflow/workflow_task_config.dart:1-190                       | Source — existing `WorkflowTaskConfig` typed-accessor seam (Part D extends in place); pattern to mirror for new accessors / constants
file   | packages/dartclaw_workflow/lib/src/workflow/step_outcome_normalizer.dart:165-171                  | Candidate — third `_stringifyDynamicMap`-equivalent site (Part C); confirm and migrate
file   | packages/dartclaw_workflow/lib/src/workflow/produced_artifact_resolver.dart:88-92 :104-108        | Candidate — additional `Map<dynamic, dynamic> => MapEntry('$key', value)` site (Part C); confirm and migrate if its body matches
file   | packages/dartclaw_workflow/lib/src/workflow/context_output_defaults.dart:128-132                  | Candidate — additional site (Part C); confirm and migrate if it matches
file   | packages/dartclaw_workflow/lib/src/workflow/workflow_executor_helpers.dart:71-74                  | Candidate — additional site (Part C); confirm and migrate if it matches
file   | packages/dartclaw_server/lib/src/task/task_config_view.dart:50-58                                 | Source — `needsWorktree` getter reading `_workflowNeedsWorktree` literally at lines 52 and 54 (Part D migration target)
file   | packages/dartclaw_server/lib/src/task/workflow_one_shot_runner.dart:70-85                        | Source — `mergeResolveEnvRaw` reading `_workflowMergeResolveEnv` literally at line 77 (Part D migration target)
file   | dev/tools/fitness/check_no_workflow_private_config.sh                                             | Source — `ALLOWED_FILES` array; drop the two server-side entries; update header comment marking TD-103 resolved by 0.16.5 S34
file   | packages/dartclaw_server/test/task/workflow_cli_runner_test.dart                                  | Constraint — existing assertions must pass byte-identically; reference for `permissionMode`-rejection negative-path coverage
file   | dev/specs/0.16.5/.technical-research.md (Shared Decisions #22, #23, #24)                          | Reference — `ClaudeSettingsBuilder` location, `normalizeDynamicMap` location, `WorkflowTaskConfig` extension scope
file   | dev/state/TECH-DEBT-BACKLOG.md#td-103                                                             | Reference — typed-accessor rule + the two server-side reads + allowlist tightening
url    | (private) docs/specs/0.16.4/fis/s43-token-tracking-cross-harness-consistency.md                   | Reference — token-correctness fix (already shipped); explicitly NOT re-fixed by S34
```


## Constraints & Gotchas

- **Critical (binding constraint #2)**: No new package dependencies. `ClaudeSettingsBuilder`, `normalizeDynamicMap`, and `WorkflowTaskConfig` extensions use only `dart:async`, `dart:convert`, plus existing imports from the touched packages.
- **Critical (binding constraint #71 — zero behaviour change)**: Existing test suites are the proof-of-work. Do **not** edit existing test assertions in `workflow_cli_runner_test.dart`, `claude_code_harness_test.dart`, or any workflow test. New tests are additions only. If any existing test fails after the refactor, the refactor is wrong — fix the implementation, not the test.
- **Critical (Part A drift preservation)**: The current duplicates have **drifted** on `permissionMode` validation — the harness accepts six values; the runner rejects four "interactive" ones (`ask`, `prompt`, `interactive`, `confirm`). The shared `ClaudeSettingsBuilder` accepts the full canonical set (matches the harness's broader contract); the runner's stricter rejection lives as a clearly-commented second-pass validation invoked **after** `ClaudeSettingsBuilder.build(...)` returns. Comment must explain why the runner rejects modes the builder accepts. **Do not narrow the shared builder's contract** to the runner's stricter set — that would silently break harness behaviour for `'plan'` / `'ask'` callers.
- **Critical (Part B — do NOT re-fix correctness)**: The token-normalization correctness bug (Codex `input_tokens` not subtracting `cached_input_tokens`) is **already covered** by 0.16.4 S43. S34 closes only the DRY gap. If the agent notices token math anomalies during the inline-cast → helper migration, do **not** "fix" them — preserve the current arithmetic byte-for-byte. Any apparent discrepancy is either expected (S43 already fixed it) or out of S34's scope.
- **Critical (Part D scope)**: TD-103's note is unambiguous: "the immediate goal is not a repository schema migration; it is to stop adding string literals by hand". `Task.configJson` continues to carry the `_workflow*` keys. The typed accessor is the read/write seam, not a new storage backend. Do not migrate the persisted shape.
- **Constraint (third-site location is stale)**: The plan's reference to `workflow_executor.dart:2906-2992` predates the 0.16.4 S45 decomposition. The agent must locate the current home(s) of the `Map<dynamic, dynamic> => dynamicMap.map((key, value) => MapEntry('$key', value))` pattern in `dartclaw_workflow`. Search candidates listed in the Code Patterns section. Migrate every site whose body matches the pattern; don't migrate sites with subtly different semantics (e.g. ones that filter or transform values).
- **Constraint (`WorkflowTaskConfig` evolution)**: The existing class uses `WorkflowStepExecutionRepository` for repository-backed reads and `Task.configJson` for legacy mirror keys. New Part D additions must follow the same pattern: if the key is read from `task.configJson`, expose either a typed accessor or a `static const String` so the call site references the constant; if the key is repository-backed and not in `task.configJson`, follow the existing async accessor pattern.
- **Constraint (`task_config_view.dart` is sync-only)**: `TaskConfigView` exposes synchronous getters. The Part D migration for `_workflowNeedsWorktree` must use a synchronous accessor or constant on `WorkflowTaskConfig`, not the existing repository-backed async pattern. Lift a `static const String kWorkflowNeedsWorktree = '_workflowNeedsWorktree'` if needed; the `TaskConfigView` getter can do `task.configJson[WorkflowTaskConfig.kWorkflowNeedsWorktree] == true`.
- **Avoid**: Inventing a new "ConfigKey" enum or DSL. **Instead**: extend the existing `WorkflowTaskConfig` class with `static const String` constants (or async accessors where the current pattern uses them). Match the existing file's idiom.
- **Avoid**: Re-routing the harness's call sites through the runner's second-pass validation, or vice versa. **Instead**: each call site keeps its own validation policy; `ClaudeSettingsBuilder` is the shared core, validation layers stay at each call site.
- **Avoid**: Touching the JSON encoding pathway in `ClaudeSettingsBuilder`. **Instead**: keep encoding (`jsonEncode(settings)`) at each call site exactly where it is today. The shared builder returns a `Map<String, dynamic>`; encoding stays at the consumer.
- **Avoid**: Changing the order of map merges, key insertion order, or null-handling in the deep-merge logic. **Instead**: lift `_deepMergeInto` verbatim into the shared builder. Any apparent simplification is risky — JSON wire-format byte-stability depends on insertion order in many Dart `Map` implementations.


## Implementation Plan

> **Vertical slice ordering**: Part A first (TI01-TI03) — establishes the shared builder and migrates both call sites in lockstep so neither file diverges mid-PR. Part B (TI04) — independent quick win. Part C (TI05-TI08) — establishes `normalizeDynamicMap` and migrates all sites. Part D (TI09-TI13) — extends `WorkflowTaskConfig`, migrates server reads, tightens fitness allowlist, adds policy note. Final: TI14 (LOC verification) and TI15 (full validation).

### Implementation Tasks

- [ ] **TI01** New file `packages/dartclaw_core/lib/src/harness/claude_settings_builder.dart` exists with `class ClaudeSettingsBuilder` (or top-level functions if simpler) — pure utility, **no `dart:io` import**, **no Process I/O**. Surface mirrors the current `_claudeSettings` / `_claudePermissionMode` / `_deepMergeInto` cluster's responsibilities: parse `permissionMode` (accepting the canonical set: `acceptEdits`, `bypassPermissions`, `default`, `plan`, `ask`, `deny`), assemble settings from `options` + optional `extraSettingsFilePath` (reading the file is the call-site's job — pass the parsed `Map<dynamic, dynamic>` in), deep-merge nested keys (`permissions`, `sandbox`). Internal helper `_deepMergeInto` lifted verbatim. Re-exported via `packages/dartclaw_core/lib/dartclaw_core.dart` barrel with `show ClaudeSettingsBuilder`.
  - Pattern reference: `packages/dartclaw_core/lib/src/harness/claude_code_harness.dart:541-668` for the canonical builder body (the runner's version is byte-identical bar the `permissionMode` rejection).
  - **Verify**: `rg -n "^class ClaudeSettingsBuilder" packages/dartclaw_core/lib/src/harness/claude_settings_builder.dart` returns 1; `rg -n "import 'dart:io'" packages/dartclaw_core/lib/src/harness/claude_settings_builder.dart` returns 0; `rg -n "ClaudeSettingsBuilder" packages/dartclaw_core/lib/dartclaw_core.dart` returns ≥1; `dart analyze packages/dartclaw_core` clean.

- [ ] **TI02** `claude_code_harness.dart` deletes its private builder cluster (current `_claudeSettings` at `:633`, `_claudePermissionMode` at `:611`, `_deepMergeInto`, `_stringifyDynamicMap` at `:652`) — total ~100 LOC removed. Imports `ClaudeSettingsBuilder` from `package:dartclaw_core/dartclaw_core.dart` (already imported; this is a `show` addition, not a new import line). Call sites that previously invoked `_claudeSettings(...)` now invoke `ClaudeSettingsBuilder.build(...)` (or whichever surface TI01 chose). The harness's `permissionMode` acceptance stays unchanged (full canonical set — no second-pass rejection on this side).
  - Pattern reference: pre-refactor body at `packages/dartclaw_core/lib/src/harness/claude_code_harness.dart:541-668`.
  - **Verify**: `rg -n "_claudeSettings|_claudePermissionMode|_deepMergeInto" packages/dartclaw_core/lib/src/harness/claude_code_harness.dart` returns 0; `rg -n "ClaudeSettingsBuilder" packages/dartclaw_core/lib/src/harness/claude_code_harness.dart` returns ≥1; `dart test packages/dartclaw_core` (or at minimum `packages/dartclaw_core/test/harness/claude_code_harness_test.dart` if it exists) passes byte-identically.

- [ ] **TI03** `workflow_cli_runner.dart` deletes its private builder cluster (current `_claudePermissionMode` at `:611`, `_claudeSettings` at `:633`, `_deepMergeInto`, `_stringifyDynamicMap` at `:719`) — total ~100 LOC removed. Imports `ClaudeSettingsBuilder`. The runner's stricter `permissionMode` interactive-mode rejection is **preserved** as a small private validator (e.g. `_rejectInteractivePermissionMode(String? mode) { if (const {'ask','prompt','interactive','confirm'}.contains(mode)) throw ...; }`) invoked **after** `ClaudeSettingsBuilder` produces its result, with a clearly-commented header explaining the drift: "Workflow one-shot mode does not support interactive permission modes (would block the non-interactive process); the shared `ClaudeSettingsBuilder` accepts these modes for the harness path, so the runner enforces this stricter contract as a second-pass validation."
  - Pattern reference: pre-refactor body at `packages/dartclaw_server/lib/src/task/workflow_cli_runner.dart:611-727`.
  - **Verify**: `rg -n "_claudeSettings|_claudePermissionMode|_deepMergeInto|_stringifyDynamicMap" packages/dartclaw_server/lib/src/task/workflow_cli_runner.dart` returns 0; `rg -n "ClaudeSettingsBuilder" packages/dartclaw_server/lib/src/task/workflow_cli_runner.dart` returns ≥1; the runner's interactive-mode rejection has a comment explaining the drift; `dart test packages/dartclaw_server/test/task/workflow_cli_runner_test.dart` passes with zero edits.

- [ ] **TI04** `_parseClaude` and `_parseCodex` in `workflow_cli_runner.dart` use `intValue` / `stringValue` from the existing `dartclaw_core` re-export of `base_protocol_adapter.dart` for every numeric / string extraction from JSON maps. Zero inline `(x as num?)?.toInt()` or `(x as String?)` casts remain. The token-correctness arithmetic stays byte-identical (do not re-fix S43's bug).
  - Pattern reference: existing helpers at `packages/dartclaw_core/lib/src/harness/base_protocol_adapter.dart:34-49`; existing call sites at `workflow_cli_runner.dart:387-392` (`_parseClaude`) and `:420-428` (`_parseCodex`).
  - **Verify**: `rg -n '\(.*\bas num\?\)\?.toInt\(\)|\(.*\bas String\?\)' packages/dartclaw_server/lib/src/task/workflow_cli_runner.dart` returns 0; `rg -n "intValue|stringValue" packages/dartclaw_server/lib/src/task/workflow_cli_runner.dart` returns ≥4; existing token-extraction tests in `workflow_cli_runner_test.dart` pass byte-identically.

- [ ] **TI05** New file `packages/dartclaw_core/lib/src/util/dynamic_reader.dart` exists with top-level function `Map<String, dynamic> normalizeDynamicMap(Map<dynamic, dynamic> source)`. Body lifts the canonical `_stringifyDynamicMap` body verbatim (recursive descent over nested `Map<dynamic, dynamic>` → `normalizeDynamicMap(...)`; `List` mapped element-wise with the same recursion; non-`Map`/non-`List` values pass through; non-string keys coerced via `'$key'`). Re-exported via the `dartclaw_core` barrel with `show normalizeDynamicMap`. Add a small unit test file `packages/dartclaw_core/test/util/dynamic_reader_test.dart` covering: identity for already-`String`-keyed input; non-string-key coercion; nested map recursion; list-of-maps recursion; null / int / String passthrough.
  - Pattern reference: any of the three current bodies — they're byte-identical bar location. Use `claude_code_harness.dart:652-660` as the canonical lift.
  - **Verify**: `rg -n "^Map<String, dynamic> normalizeDynamicMap" packages/dartclaw_core/lib/src/util/dynamic_reader.dart` returns 1; `rg -n "normalizeDynamicMap" packages/dartclaw_core/lib/dartclaw_core.dart` returns ≥1; `dart test packages/dartclaw_core/test/util/dynamic_reader_test.dart` passes; `dart analyze packages/dartclaw_core` clean.

- [ ] **TI06** `claude_code_harness.dart` migrates to `normalizeDynamicMap`: every call site previously calling `_stringifyDynamicMap(...)` now calls `normalizeDynamicMap(...)`; the private `_stringifyDynamicMap` (already removed in TI02 along with the rest of the cluster) stays gone. Verify TI02's deletion was complete.
  - **Verify**: `rg -n "_stringifyDynamicMap|stringifyDynamicMap" packages/dartclaw_core/lib/src/harness/claude_code_harness.dart` returns 0; `rg -n "normalizeDynamicMap" packages/dartclaw_core/lib/src/harness/claude_code_harness.dart` returns ≥1.

- [ ] **TI07** `workflow_cli_runner.dart` migrates to `normalizeDynamicMap`: every call site previously calling `_stringifyDynamicMap(...)` (currently at lines 670, 696, 703, 710) now calls `normalizeDynamicMap(...)`; the private (already removed in TI03) stays gone.
  - **Verify**: `rg -n "_stringifyDynamicMap|stringifyDynamicMap" packages/dartclaw_server/lib/src/task/workflow_cli_runner.dart` returns 0; `rg -n "normalizeDynamicMap" packages/dartclaw_server/lib/src/task/workflow_cli_runner.dart` returns ≥1.

- [ ] **TI08** Locate and migrate the third `_stringifyDynamicMap`-equivalent site(s) in `dartclaw_workflow`. The plan's `workflow_executor.dart:2906-2992` reference is stale (file is now 891 LOC after 0.16.4 S45). Run `rg -n "Map<dynamic, dynamic> dynamicMap => dynamicMap.map\(\(key, value\) => MapEntry\('\\\$key'" packages/dartclaw_workflow/lib/src/` to find candidates. Confirmed candidates from research: `step_outcome_normalizer.dart:165-171`, `produced_artifact_resolver.dart:88-92` and `:104-108`, `context_output_defaults.dart:128-132`, `workflow_executor_helpers.dart:71-74`. For each site whose body matches the canonical pattern (recursive walk producing `Map<String, dynamic>` from `Map<dynamic, dynamic>`), replace with `normalizeDynamicMap(...)`. Sites with subtly different semantics (e.g. that filter, transform, or short-circuit) stay untouched and are recorded in the implementation observations as "intentionally not migrated" with a one-line reason.
  - Pattern reference: confirmed canonical body at `claude_code_harness.dart:652-660` (pre-deletion).
  - **Verify**: `rg -n "Map<dynamic, dynamic> dynamicMap => dynamicMap.map" packages/dartclaw_workflow/lib/src/` shows only sites the agent intentionally left alone (each documented in observations); migrated sites import `normalizeDynamicMap` from `package:dartclaw_core/dartclaw_core.dart`; `dart test packages/dartclaw_workflow` passes byte-identically.

- [ ] **TI09** Extend `packages/dartclaw_workflow/lib/src/workflow/workflow_task_config.dart` with the remaining keys per Shared Decision #24. Required additions (each as a typed accessor or a `static const String` — match the existing pattern for repository-backed vs `task.configJson`-backed reads):
  - **Cross-package** (already partially covered by existing accessors): add typed accessor or constant for `_workflowMergeResolveEnv`; add typed accessor for `_dartclaw.internal.validationFailure`.
  - **Workflow-internal**: add `static const String` constants (or typed accessors where current call sites do non-trivial coercion) for `_workflowGit`, `_workflowWorkspaceDir`, `_continueSessionId`, `_sessionBaselineTokens`, `_mapIterationIndex`. Naming: `kWorkflowGit`, `kWorkflowWorkspaceDir`, `kContinueSessionId`, `kSessionBaselineTokens`, `kMapIterationIndex` — follow the existing constant-naming convention if there is one; otherwise pick the cleanest. (Note: S36 retires `k`-prefix on public consts; `WorkflowTaskConfig`'s constants are class-static so the rule may not apply — match what S36's plan section directs; if uncertain, drop the `k`-prefix proactively to avoid an immediate S36 follow-up.)
  - **Server-side**: add `static const String kWorkflowNeedsWorktree = '_workflowNeedsWorktree'` (or its `k`-less equivalent per S36 alignment) so synchronous server-side callers can reference it (see TI10 — `task_config_view.dart` is sync-only).
  - Add a class-level dartdoc paragraph stating the typed-surface rule (Part D's Acceptance Criterion 5 — see TI13).
  - **Verify**: `rg -n "_workflowMergeResolveEnv|_workflowGit|_workflowWorkspaceDir|_continueSessionId|_sessionBaselineTokens|_mapIterationIndex|_workflowNeedsWorktree" packages/dartclaw_workflow/lib/src/workflow/workflow_task_config.dart` returns ≥7; `dart analyze packages/dartclaw_workflow` clean; `dart test packages/dartclaw_workflow` passes.

- [ ] **TI10** Migrate `task_config_view.dart` lines 52, 54: replace each literal `'_workflowNeedsWorktree'` lookup with `WorkflowTaskConfig.kWorkflowNeedsWorktree` (or whichever constant TI09 chose). The `needsWorktree` getter remains synchronous; the change is purely removing the literal in favour of a constant reference.
  - Pattern reference: `packages/dartclaw_server/lib/src/task/task_config_view.dart:50-58` for the current shape.
  - **Verify**: `rg -n "'_workflowNeedsWorktree'" packages/dartclaw_server/lib/src/task/task_config_view.dart` returns 0; `rg -n "WorkflowTaskConfig\.kWorkflowNeedsWorktree" packages/dartclaw_server/lib/src/task/task_config_view.dart` returns ≥2; `dart test packages/dartclaw_server/test/task` passes.

- [ ] **TI11** Migrate `workflow_one_shot_runner.dart` line 77: replace `task.configJson['_workflowMergeResolveEnv']` with the typed accessor or `WorkflowTaskConfig.k...` constant chosen in TI09. Since this is async-context but the `task.configJson` shape itself is synchronous, the simplest migration is a constant lookup; consider a typed `Map<String, String>?`-returning helper on `WorkflowTaskConfig` if it cleanly absorbs the existing inline coercion (`mergeResolveEnvRaw is Map ? Map<String, String>.fromEntries(...)` — that's exactly the kind of repetition a typed accessor exists to encapsulate).
  - Pattern reference: `packages/dartclaw_server/lib/src/task/workflow_one_shot_runner.dart:70-85` for current shape.
  - **Verify**: `rg -n "'_workflowMergeResolveEnv'" packages/dartclaw_server/lib/src/task/workflow_one_shot_runner.dart` returns 0; the call site references `WorkflowTaskConfig` (constant or typed helper); `dart test packages/dartclaw_server/test/task` passes.

- [ ] **TI12** Tighten `dev/tools/fitness/check_no_workflow_private_config.sh` `ALLOWED_FILES` array: remove `packages/dartclaw_server/lib/src/task/workflow_one_shot_runner.dart` and `packages/dartclaw_server/lib/src/task/task_config_view.dart` from the array. Update the header comment block: replace the "TD-103 tracks moving the two server-side reads ... slated for 0.16.5 S34" line with "TD-103 resolved by 0.16.5 S34 — both server-side reads now route through `WorkflowTaskConfig`."
  - **Verify**: `rg -n "workflow_one_shot_runner.dart|task_config_view.dart" dev/tools/fitness/check_no_workflow_private_config.sh` returns 0 in `ALLOWED_FILES`-array context; `bash dev/tools/fitness/check_no_workflow_private_config.sh` exits 0 (proves the migration is complete and no stray `_workflow*` literals leaked into other files).

- [ ] **TI13** Architecture note added documenting the typed-surface rule. Two acceptable locations (pick one — see Agent Decision Authority): (a) class-level dartdoc paragraph on `WorkflowTaskConfig` (preferred — closer to the surface) reading approximately: "New underscored workflow task-config keys (`_workflow*`, `_dartclaw.internal.*`) must be added to this class as a typed accessor or `static const String` constant. Direct string-literal access to `task.configJson['_workflow*']` from outside this class is enforced against by `dev/tools/fitness/check_no_workflow_private_config.sh`." (b) one-line entry in `packages/dartclaw_workflow/CLAUDE.md` under **Conventions** mirroring the same rule. If (a) is chosen, also add a one-line cross-reference in `CLAUDE.md` so contributors discover it via the package-rules surface. If (b) is chosen exclusively, the dartdoc on `WorkflowTaskConfig` still gets a one-line reference to the `CLAUDE.md` entry.
  - **Verify**: `rg -n "underscored workflow task-config|new underscored.*key" packages/dartclaw_workflow/lib/src/workflow/workflow_task_config.dart packages/dartclaw_workflow/CLAUDE.md` returns ≥1.

- [ ] **TI14** LOC verification: `wc -l` snapshot of the three primary files — `packages/dartclaw_server/lib/src/task/workflow_cli_runner.dart`, `packages/dartclaw_core/lib/src/harness/claude_code_harness.dart`, plus the workflow-package file(s) housing migrated `_stringifyDynamicMap`-equivalents. Compute `(before-after)` summed across these files; the sum must be ≥150. Record in implementation observations: `runner_before=806 runner_after=<N> harness_before=1105 harness_after=<M> workflow_before=<X> workflow_after=<Y> net_reduction=<Σ>`. New file LOC (`claude_settings_builder.dart`, `dynamic_reader.dart`, additions to `workflow_task_config.dart`) does **not** count against the reduction — the goal is callsite weight.
  - **Verify**: `(806 + 1105 + workflow_before) - (runner_after + harness_after + workflow_after) >= 150`; record the math in observations or commit message.

- [ ] **TI15** Full validation: `dart format packages/dartclaw_core packages/dartclaw_server packages/dartclaw_workflow` produces no changes; `dart analyze --fatal-warnings --fatal-infos` workspace-wide clean (binding constraint #3); `dart test packages/dartclaw_core` green; `dart test packages/dartclaw_server` green (specifically `test/task/workflow_cli_runner_test.dart` with zero edits to existing assertions); `dart test packages/dartclaw_workflow` green; `bash dev/tools/fitness/check_no_workflow_private_config.sh` exits 0; `rg "TODO|FIXME|placeholder|not.implemented" packages/dartclaw_core/lib/src/harness/claude_settings_builder.dart packages/dartclaw_core/lib/src/util/dynamic_reader.dart packages/dartclaw_workflow/lib/src/workflow/workflow_task_config.dart` empty.
  - **Verify**: All commands exit 0; PR diff shows zero edits to existing test assertions; net LOC reduction recorded per TI14.

### Testing Strategy

- [TI01,TI05] Unit tests for `ClaudeSettingsBuilder` + `normalizeDynamicMap` — net-new direct-unit coverage in `dartclaw_core` (covers the canonical-set `permissionMode` parser, deep-merge order, dynamic-map recursion, non-string-key coercion). These are additions, not replacements.
- [TI02,TI03] Scenario "Workflow one-shot invokes Claude — settings byte-identical" → existing `workflow_cli_runner_test.dart` Claude tests + existing `claude_code_harness_test.dart` (if present) pass byte-identically. No new assertions; existing tests are the proof.
- [TI03] Scenario "Interactive `permissionMode: 'ask'` rejected by runner second-pass" → existing `workflow_cli_runner_test.dart` permission-mode rejection test continues to pass; verify the exception type and message are unchanged.
- [TI02] Scenario "Claude harness path accepts all six `permissionMode` values" → existing harness tests for each accepted mode pass byte-identically.
- [TI04] Scenario "`_parseClaude` token extraction unchanged" → existing token-extraction tests in `workflow_cli_runner_test.dart` pass; cross-reference 0.16.4 S43 token-correctness tests for assurance the arithmetic wasn't perturbed.
- [TI06,TI07,TI08] Scenarios "`normalizeDynamicMap` round-trip preserves nested structure" + "non-string keys coerced" → covered by TI05's new unit tests + integration-level proof from existing `claude_code_harness_test.dart` / `workflow_cli_runner_test.dart` / workflow tests passing byte-identically after migration.
- [TI10] Scenario "Server-side `needsWorktree` reads through typed accessor" → existing `task_config_view_test.dart` (or equivalent) passes byte-identically — the read is now via `WorkflowTaskConfig.kWorkflowNeedsWorktree` but the observable behaviour is identical.
- [TI11] Scenario "Server-side `mergeResolveEnv` reads through typed accessor" → existing `workflow_one_shot_runner_test.dart` (or equivalent) passes byte-identically.
- [TI12] Scenario "Fitness allowlist rejects new `_workflow*` reads" → run `bash dev/tools/fitness/check_no_workflow_private_config.sh`, exit 0; the negative-path assurance is structural (the allowlist is tighter; any future violation in the now-unallowlisted files fires).
- [TI15] Scenario "Existing test suites pass byte-identically" → `dart test` exit 0 across the three packages with zero diff to existing assertions.

### Validation

Standard validation (build/test, analyze, format, code review) is sufficient. No feature-specific validation needed — this is a four-part DRY refactor with the existing test suites as the proof-of-work.

### Execution Contract

- Implement tasks in listed order. Each **Verify** line must pass before proceeding to the next task.
- Prescriptive details (file paths, error messages, identifier names, key constants) are exact — implement them verbatim.
- Proactively use sub-agents for non-coding needs (none expected for this story; possibly a documentation-lookup sub-agent if any external API doc is needed for Claude `permissionMode` semantics, but the existing implementation is the reference).
- After all tasks: `dart format packages/dartclaw_core packages/dartclaw_server packages/dartclaw_workflow`, `dart analyze --fatal-warnings --fatal-infos` workspace-wide, `dart test packages/dartclaw_core packages/dartclaw_server packages/dartclaw_workflow`, `bash dev/tools/fitness/check_no_workflow_private_config.sh` all green; `rg "TODO|FIXME|placeholder|not.implemented" <new-files>` empty.
- Mark task checkboxes immediately upon completion — do not batch.


## Final Validation Checklist

- [ ] **All success criteria** met (each one mapped to a Scenario or Verify line)
- [ ] **All tasks** TI01–TI15 fully completed, verified, and checkboxes checked
- [ ] **No regressions**: zero edits to existing test assertions in `workflow_cli_runner_test.dart`, `claude_code_harness_test.dart`, `task_config_view_test.dart`, or any workflow test; only additions allowed
- [ ] **Net LOC reduction ≥150** across `workflow_cli_runner.dart` + `claude_code_harness.dart` + the workflow-package `_stringifyDynamicMap`-equivalent owner(s); recorded in observations
- [ ] **`ClaudeSettingsBuilder` + `normalizeDynamicMap`** present in `dartclaw_core` with `show`-clause re-exports; no `dart:io` import in either
- [ ] **`WorkflowTaskConfig` extended** with the full Part D key set; both server-side reads migrated; fitness allowlist tightened; architecture note added
- [ ] **`permissionMode` validation drift documented**: shared parser canonical; runner second-pass clearly commented
- [ ] **Workspace `dart analyze` + `dart format` + `dart test` (three packages)** all green; `bash dev/tools/fitness/check_no_workflow_private_config.sh` exit 0


## Implementation Observations

> _Managed by exec-spec post-implementation — append-only._

_No observations recorded yet._
