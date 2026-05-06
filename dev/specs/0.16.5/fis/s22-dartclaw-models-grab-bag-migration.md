# S22 — dartclaw_models Grab-Bag Migration

**Plan**: ../plan.md
**Story-ID**: S22

## Feature Overview and Goal

Move five domain-model groupings out of `dartclaw_models` into their owning packages and shrink the `dartclaw_models` barrel to a true cross-package shared kernel (`Session`, `Message`, `SessionKey`, `ChannelType`, `AgentDefinition`, `MemoryChunk`). In the same commit chain, run the **TD-102 attractor**: identify non-runtime-primitive material in `dartclaw_core/lib/` that can move OUT (typically into `dartclaw_models` or `dartclaw_config`) so the `_coreLocCeiling` ratchet in `dev/tools/arch_check.dart` can be lowered back from the temporary 13,000 → 12,000 — keeping the constraint biting and closing TD-102. S10's L1 fitness functions act as the regression net for barrel-show, file-LOC, and package-cycles drift during the move. Net public-API break batches with S36 under a single CHANGELOG "Breaking API Changes" banner; pub.dev is placeholder-only today, so the move is safe with only a CHANGELOG migration note (one-release `@Deprecated` soft re-export from `dartclaw_models.dart` is on the table — recorded as a decision in this FIS).

> **Technical Research**: [.technical-research.md](../.technical-research.md) _(see "S22 — dartclaw_models Grab-Bag Migration" entry under Story-Scoped File Map; Shared Decisions #3, #6, #17; Binding PRD Constraints #1, #30, #31, #32, #33, #34, #35, #36, #71, #74, #86)_

## Required Context

### From `prd.md` — "FR5: Model Package Cleanup"
<!-- source: ../prd.md#fr5-model-package-cleanup -->
<!-- extracted: e670c47 -->
> **Description**: `dartclaw_models` shrinks to a true shared kernel (Session, Message, SessionKey, ChannelType, AgentDefinition, MemoryChunk). Domain models move to their owning packages. Migration also closes tech-debt TD-053 (convert `TaskEventKind` sealed class to enum while moving).
>
> **Acceptance Criteria**:
> - [ ] `WorkflowDefinition`, `WorkflowStep`, `WorkflowRun`, `WorkflowExecutionCursor` moved to `dartclaw_workflow`
> - [ ] `Project`, `CloneStrategy`, `PrStrategy`, `PrConfig` moved to `dartclaw_config` (or new `dartclaw_project` sub-module)
> - [ ] `TaskEvent` + 9 subtypes moved to `dartclaw_core` (where `Task` lives); `TaskEventKind` sealed class converted to enum (closes TD-053)
> - [ ] `TurnTrace`, `TurnTraceSummary`, `ToolCallRecord` moved to `dartclaw_core`
> - [ ] `SkillInfo` moved to `dartclaw_workflow`
> - [ ] `dartclaw_models` ≤1,200 LOC
> - [ ] CHANGELOG entry notes the public-API migration
>
> **Priority**: Must / P0 (gated by metrics table; tag upgraded from P1 to reflect release-gate requirement)

### From `plan.md` — "S22: dartclaw_models Grab-Bag Migration" (scope + 2026-05-04 reconciliation note)
<!-- source: ../plan.md#s22-dartclaw_models-grab-bag-migration -->
<!-- extracted: e670c47 -->
> **Scope**: Move domain-specific models out of `dartclaw_models` to their owning packages. (a) `WorkflowDefinition` (1,349 LOC alone), `WorkflowStep`, `WorkflowRun`, `WorkflowExecutionCursor` → `dartclaw_workflow`. (b) `Project`, `CloneStrategy`, `PrStrategy`, `PrConfig` → `dartclaw_config` (already hosts `ProjectConfig`/`ProjectDefinition`) or a new `dartclaw_project` sub-module (decision during implementation). (c) `TaskEvent` + 9 subtypes → `dartclaw_core` (where `Task` lives); **during the move, convert `TaskEventKind` sealed class with 6 empty subclasses → `enum`** with `String get name` — pattern matching with `switch` continues to work (closes TD-053). (d) `TurnTrace`, `TurnTraceSummary`, `ToolCallRecord` → `dartclaw_core`. (e) `SkillInfo` → `dartclaw_workflow`. Update all import sites. `dartclaw_models` ends ≤1,200 LOC as the true shared kernel (Session, Message, SessionKey, ChannelType, AgentDefinition, MemoryChunk). Decide whether to ship a one-release soft re-export from `dartclaw_models.dart` for external consumers (record decision in FIS). Update `CHANGELOG.md` with a migration note.
>
> **Note (2026-05-04 reconciliation)**: `dartclaw_models` total LOC has grown from the pre-audit 3,005 baseline to **3,555 LOC** as of `v0.16.4` (workflow_definition.dart alone is 1,349 LOC), so this story's migration surface is larger than originally scoped. Targets unchanged. Pair this with the **TD-102 attractor** decision (folded in 2026-05-04): `dartclaw_core/lib/` grew from 11,561 → 12,437 LOC during 0.16.4; the ratchet was temporarily raised from 12,000 → 13,000. Items (c) `TaskEvent` and (d) `TurnTrace`/`TurnTraceSummary`/`ToolCallRecord` migrate **into** `dartclaw_core` and would push it further over budget — so before/while landing those moves, identify non-runtime-primitive material in `dartclaw_core/lib/` that can move out (typically to `dartclaw_models` or `dartclaw_config`) to compensate. Net target: `dartclaw_core/lib/` returns ≤12,000 LOC, then lower the ratchet back down in `dev/tools/arch_check.dart` to keep the constraint biting. Closes TD-102 at the same commit chain.
>
> **Acceptance Criteria**:
> - [ ] `dartclaw_models` ≤1,200 LOC (must-be-TRUE)
> - [ ] Workflow/project/task-event/turn-trace/skill-info models live in their owning packages (must-be-TRUE)
> - [ ] `dart analyze` and `dart test` workspace-wide pass (must-be-TRUE)
> - [ ] CHANGELOG migration note added
> - [ ] Fitness functions from S10 remain green (model moves don't regress barrel hygiene or file size)
> - [ ] **TD-102**: `dartclaw_core/lib/` total LOC ≤12,000; `_coreLocCeiling` in `dev/tools/arch_check.dart` lowered back from 13,000 → 12,000 in the same commit chain (must-be-TRUE)
> - [ ] TD-102 entry deleted (or marked Resolved-by-S22) in public `dev/state/TECH-DEBT-BACKLOG.md`

### From `prd.md` — Edge Cases (external-consumer break)
<!-- source: ../prd.md#edge-cases -->
<!-- extracted: e670c47 -->
> External consumer pinned to `package:dartclaw_models/dartclaw_models.dart show WorkflowDefinition` after FR5 ships → Breaks; mitigated by CHANGELOG migration note and (optional) soft re-export. Risk low because pub.dev is placeholder-only today.

### From `prd.md` — Decisions Log (FR5 promoted, soft re-export option)
<!-- source: ../prd.md#decisions-log -->
<!-- extracted: e670c47 -->
> FR5 model migration promoted from stretch to planned target — Pub.dev is placeholder-only, no external consumers, safe window to ship the move; cascade-recompile cost worth removing now. Defer to 0.16.7 (rejected as the default — would require a second sprint to absorb the CHANGELOG migration note).
>
> Compatibility — Breaking change to public SDK API: FR5 model migration is visible; CHANGELOG documents and (optionally) one-release soft re-export from `dartclaw_models`.

### From `.technical-research.md` — Binding PRD Constraints (S22-applicable)
<!-- source: ../.technical-research.md#binding-prd-constraints -->
<!-- extracted: e670c47 -->
> #1 (Out of Scope / NFR Compatibility): "JSONL control protocol, REST API payload shapes, SSE envelope formats unchanged." — Applies to S22 (model relocations must not change wire formats).
> #2 (Constraint): "No new dependencies in any package." — No new pubspec deps; relocations only.
> #30 (FR5): "`WorkflowDefinition`, `WorkflowStep`, `WorkflowRun`, `WorkflowExecutionCursor` moved to `dartclaw_workflow`."
> #31 (FR5): "`Project`, `CloneStrategy`, `PrStrategy`, `PrConfig` moved to `dartclaw_config` (or new `dartclaw_project` sub-module)."
> #32 (FR5): "`TaskEvent` + 9 subtypes moved to `dartclaw_core`; `TaskEventKind` sealed class converted to enum (closes TD-053)."
> #33 (FR5): "`TurnTrace`, `TurnTraceSummary`, `ToolCallRecord` moved to `dartclaw_core`."
> #34 (FR5): "`SkillInfo` moved to `dartclaw_workflow`."
> #35 (FR5 / Success Metric): "`dartclaw_models` ≤1,200 LOC."
> #36 (FR5): "CHANGELOG entry notes the public-API migration." — Shared banner with S36.
> #71 (NFR Reliability): "Behavioural regressions post-decomposition: Zero — every existing test remains green."
> #74 (NFR Observability): not S22-load-bearing; sealed-event coverage is S01/S05.
> #86 (Edge Case): "External consumer pinned to `package:dartclaw_models/dartclaw_models.dart show WorkflowDefinition` after FR5 ships → Breaks; mitigated by CHANGELOG migration note and (optional) soft re-export."

### From `.technical-research.md` — Shared Architectural Decisions (S22-applicable)
<!-- source: ../.technical-research.md#shared-architectural-decisions -->
<!-- extracted: e670c47 -->
> **3. S10 → S22 — Fitness-test regression net** — S10's `max_file_loc_test.dart`, `package_cycles_test.dart`, `barrel_show_clauses_test.dart` operate as the model-migration regression net. Soft re-export shape from `dartclaw_models.dart` (one-release `@Deprecated`) is option, decision recorded in S22 FIS. PRODUCER: S10. CONSUMER: S22. WHY: S22 is High-risk public-API move; relies on mechanical checks.
>
> **6. S22 → S36 — Public-API CHANGELOG break batching** — Single "Breaking API Changes" CHANGELOG section housing both S22 model moves and S36 renames. PRODUCER: S22 (opens CHANGELOG section). CONSUMER: S36. WHY: One coherent migration entry per Decisions Log.
>
> **17. `dartclaw_models` shrink target** — only `Session`, `Message`, `SessionKey`, `ChannelType`, `AgentDefinition`, `MemoryChunk` survive (≤1,200 LOC). S22 migrates per its scope. Net: `dartclaw_core/lib/` returns ≤12,000 LOC (closes TD-102); `arch_check.dart` ratchet lowered 13,000→12,000 in same commit chain.

### From `packages/dartclaw_models/CLAUDE.md` — package boundaries (post-migration shape)
<!-- source: ../../../packages/dartclaw_models/CLAUDE.md -->
<!-- extracted: e670c47 -->
> Runtime dependencies: `collection` only. Do not add `path`, `yaml`, `sqlite3`, `dart:io`, or anything pulling them in transitively. These types must be importable from any environment (server, CLI, future Flutter clients). Services, repositories, parsers, validators, and persistence logic do **not** live here. Models own data shape + JSON/Map (de)serialization only. Do not import from any other `dartclaw_*` package. This is the bottom of the DAG.

> Note: this file's "Role" sentence and "Key files" enumeration both list `WorkflowDefinition`/`WorkflowRun`/`TaskEvent`/`TurnTrace`/`SkillInfo`/`Project` — those entries become stale once S22 lands and must be updated in the same edit (Boy-Scout rule + the per-package CLAUDE.md update mandate).

## Deeper Context

- `packages/dartclaw_models/lib/dartclaw_models.dart` — current barrel; 76 LOC; lists every migrating type via `show`. Survivor set after S22: only `Session`/`SessionType`/`Message`/`MemoryChunk`/`MemorySearchResult` (from `models.dart`), `AgentDefinition`, `ChannelConfig`/`GroupAccessMode`/`RetryPolicy`, `ChannelConfigProvider`, `ChannelType`, `ContainerConfig`, `SessionKey`, `SessionScopeConfig`/`ChannelScopeConfig`/`DmScope`/`GroupScope`, `TaskType`. Current full file: `lib/src/{models,agent_definition,channel_config,channel_config_provider,channel_type,container_config,session_key,session_scope_config,task_type}.dart` survive; `{project,task_event,tool_call_record,turn_trace,turn_trace_summary,workflow_definition,workflow_run,skill_info}.dart` move out.
- `packages/dartclaw_models/lib/src/workflow_definition.dart` — 1,349 LOC. Single-largest mover; carries every workflow node + step subtype + git/output strategy types. Whole file relocates to `packages/dartclaw_workflow/lib/src/workflow/workflow_definition.dart`.
- `packages/dartclaw_models/lib/src/workflow_run.dart` — 388 LOC. `WorkflowRun`, `WorkflowRunStatus`, `WorkflowExecutionCursor`, `WorkflowExecutionCursorNodeType`, `WorkflowWorktreeBinding`. Relocates to `packages/dartclaw_workflow/lib/src/workflow/workflow_run.dart`.
- `packages/dartclaw_models/lib/src/project.dart` — 333 LOC. `Project`, `ProjectAuthStatus`, `ProjectStatus`, `CloneStrategy`, `PrStrategy`, `PrConfig`. Decision required: collocate with `dartclaw_config`'s `ProjectConfig`/`ProjectDefinition`/`parseProjectConfig` at `packages/dartclaw_config/lib/src/project_runtime.dart` (or similar) **vs** create a new `dartclaw_project` sub-module. Plan note: `dartclaw_config` already hosts the configuration-shape twin → collocation is simpler and avoids a new package; pick collocation unless `dartclaw_models` survivors prove they cannot drop a transitive on `Project` cleanly.
- `packages/dartclaw_models/lib/src/task_event.dart` — 162 LOC. `TaskEvent` + sealed `TaskEventKind` with 6 empty subclasses (`StatusChanged`, `ToolCalled`, `ArtifactCreated`, `StructuredOutputInlineUsed`, `StructuredOutputFallbackUsed`, `PushBack`, `TokenUpdate`, `TaskErrorEvent`, `Compaction` — verified 9 subtypes). Move to `packages/dartclaw_core/lib/src/task/task_event.dart`. Convert `sealed class TaskEventKind` with empty subclass instances → `enum TaskEventKind { statusChanged, toolCalled, artifactCreated, structuredOutputInlineUsed, structuredOutputFallbackUsed, pushBack, tokenUpdate, taskError, compaction }` (Dart enums already provide `name`; preserve any case-mapping helpers; pattern-match `switch` over the enum stays compiler-exhaustive). Closes TD-053.
- `packages/dartclaw_models/lib/src/{turn_trace,turn_trace_summary,tool_call_record}.dart` — 163 + 71 + 49 LOC. Move to `packages/dartclaw_core/lib/src/turn/` (new directory; existing `dartclaw_core` has no `turn/` subdir today — match the convention from S11 which colocates `TurnManager`/`TurnRunner` interfaces in `src/turn/`).
- `packages/dartclaw_models/lib/src/skill_info.dart` — 128 LOC. `SkillInfo`, `SkillSource`. Move to `packages/dartclaw_workflow/lib/src/skills/skill_info.dart` (existing `skills/` subdir hosts `skill_registry.dart`/`skill_provisioner.dart`).
- `packages/dartclaw_core/lib/dartclaw_core.dart` — barrel adds new exports for migrated types: `TaskEvent` + subtypes (and the enum-ified `TaskEventKind`), `TurnTrace`/`TurnTraceSummary`/`ToolCallRecord`. Constraint #20 / S10 fitness: explicit `show` clauses required.
- `packages/dartclaw_workflow/lib/dartclaw_workflow.dart` — barrel adds `WorkflowDefinition` (+ all node + step + git/output strategy types — review the existing 76-LOC `dartclaw_models.dart` show-list for the full enumeration), `WorkflowRun`, `WorkflowExecutionCursor`, `WorkflowWorktreeBinding`, `SkillInfo`/`SkillSource`. ≤35-export soft cap from S25's L2 fitness — manage by collapsing fine-grained shows where possible (e.g. one re-export per file, `show Type1, Type2, …`).
- `packages/dartclaw_config/lib/dartclaw_config.dart` — barrel adds `Project`, `ProjectAuthStatus`, `ProjectStatus`, `CloneStrategy`, `PrStrategy`, `PrConfig` (≤50-export cap; well within budget today).
- `dev/tools/arch_check.dart:9` — `const _coreLocCeiling = 13000;` lowers to `12000` in the same commit that lands the TD-102 attractor moves.
- `dev/state/TECH-DEBT-BACKLOG.md#td-102--trim-dartclaw_corelib-back-below-the-12000-line-ratchet` — delete (or mark `**Status**: Resolved by S22 (0.16.5)`) per the "Open items only" backlog policy.
- `dev/state/TECH-DEBT-BACKLOG.md#td-053--taskeventkind-sealed-class-should-be-an-enum` — delete or mark Resolved-by-S22.
- `CHANGELOG.md` — single "Breaking API Changes" banner under the 0.16.5 section. S22 opens it; S36 (and S23 R-L2 deprecation removals) append. Migration table: `package:dartclaw_models/dartclaw_models.dart show WorkflowDefinition;` → `package:dartclaw_workflow/dartclaw_workflow.dart show WorkflowDefinition;` (etc., one row per migrated symbol grouping).
- `packages/dartclaw_workflow/CLAUDE.md` and `packages/dartclaw_core/CLAUDE.md` — "Role" sentence enumerates owned types; update both to add the migrated types (Boy-Scout rule + per-package CLAUDE.md mandate from root `CLAUDE.md`).
- `packages/dartclaw_testing/lib/src/fake_project_service.dart` and other fakes — import sites update from `package:dartclaw_models/dartclaw_models.dart` to the new owner barrel.
- 89 file imports of `package:dartclaw_models` exist across `packages/` + `apps/` (rg-counted at extraction time); these are the import-update universe for tasks TI07.

## Success Criteria (Must Be TRUE)

- [ ] `WorkflowDefinition`, `WorkflowStep`, all `WorkflowNode` subtypes (`ActionNode`/`ForeachNode`/`LoopNode`/`MapNode`/`ParallelGroupNode`), `WorkflowVariable`, `WorkflowLoop`, all `WorkflowGit*` strategy types, `MergeResolveEscalation`/`MergeResolveConfig`, `StepConfigDefault`, `OnFailurePolicy`, `ExtractionType`/`ExtractionConfig`, `OutputFormat`/`OutputMode`/`OutputConfig`, `WorkflowRun`, `WorkflowRunStatus`, `WorkflowExecutionCursor`, `WorkflowExecutionCursorNodeType`, `WorkflowWorktreeBinding` are exported from `package:dartclaw_workflow/dartclaw_workflow.dart` and not from `package:dartclaw_models/dartclaw_models.dart` — verify by inspecting both barrels (Constraint #30)
- [ ] `Project`, `ProjectAuthStatus`, `ProjectStatus`, `CloneStrategy`, `PrStrategy`, `PrConfig` are exported from `package:dartclaw_config/dartclaw_config.dart` (collocation chosen — see Architecture Decision) and not from `package:dartclaw_models/dartclaw_models.dart` (Constraint #31)
- [ ] `TaskEvent` and 9 subtypes (`StatusChanged`, `ToolCalled`, `ArtifactCreated`, `StructuredOutputInlineUsed`, `StructuredOutputFallbackUsed`, `PushBack`, `TokenUpdate`, `TaskErrorEvent`, `Compaction`) are exported from `package:dartclaw_core/dartclaw_core.dart`; `TaskEventKind` is now a Dart `enum` (not a sealed class) and pattern-matching `switch` over it remains compiler-exhaustive (closes TD-053; Constraint #32)
- [ ] `TurnTrace` (+ `computeEffectiveTokens`), `TurnTraceSummary`, `ToolCallRecord` are exported from `package:dartclaw_core/dartclaw_core.dart` and not from `package:dartclaw_models/dartclaw_models.dart` (Constraint #33)
- [ ] `SkillInfo`, `SkillSource` are exported from `package:dartclaw_workflow/dartclaw_workflow.dart` and not from `package:dartclaw_models/dartclaw_models.dart` (Constraint #34)
- [ ] `find packages/dartclaw_models/lib -name '*.dart' | xargs wc -l | tail -1` reports ≤1,200 total LOC; survivor set is exactly `{models.dart, agent_definition.dart, channel_config.dart, channel_config_provider.dart, channel_type.dart, container_config.dart, session_key.dart, session_scope_config.dart, task_type.dart, dartclaw_models.dart}` (Constraint #35)
- [ ] `dart analyze --fatal-warnings --fatal-infos` (workspace-wide) exits 0 (Constraint #73)
- [ ] `dart test` workspace-wide green; no test imports `package:dartclaw_models` for any migrated symbol (Constraint #71)
- [ ] `CHANGELOG.md` has a "## Breaking API Changes" subsection under the 0.16.5 entry; the subsection lists the import-path migration table for all migrated symbol groupings (workflow / project / task-event / turn-trace / skill-info). The same subsection becomes the home for S36 + S23 R-L2 entries when they land — do not create per-story banners (Constraint #36, Shared Decision #6)
- [ ] All six S10 fitness functions remain green (`barrel_show_clauses_test.dart`, `max_file_loc_test.dart`, `package_cycles_test.dart`, `constructor_param_count_test.dart`, `no_cross_package_env_plan_duplicates_test.dart`, `safe_process_usage_test.dart`) plus the format gate (Plan AC line 701)
- [ ] `find packages/dartclaw_core/lib -name '*.dart' | xargs wc -l | tail -1` reports ≤12,000 total LOC; `dev/tools/arch_check.dart` `const _coreLocCeiling` is `12000` (lowered from `13000` in the same commit chain). `dart run dev/tools/arch_check.dart` exits 0 (Plan AC line 702)
- [ ] `dev/state/TECH-DEBT-BACKLOG.md` no longer contains a TD-102 entry, OR contains a `**Status**: Resolved by S22 (0.16.5)` annotation per the "Open items only" backlog policy. Same treatment for TD-053 (Plan AC line 703)
- [ ] JSON wire formats for every migrated model are byte-identical pre/post migration — verify via `toJson()`/`fromJson` round-trip tests (existing or added) for `WorkflowDefinition`, `WorkflowRun`, `Project`, `TaskEvent`, `TurnTrace`, `SkillInfo` (Constraint #1)

### Health Metrics (Must NOT Regress)
- [ ] Existing test suite remains green (`dart test` workspace; integration suite under `dart test -t integration` not regressed)
- [ ] SQLite persistence: no schema migration triggered by this story; `dartclaw_storage` repo round-trips on `WorkflowRun`/`Task` payloads remain wire-compatible
- [ ] SSE/REST/JSONL envelope shapes unchanged — `task_sse_routes_test.dart`, `trace_routes_test.dart` stay green
- [ ] No new pubspec deps added in any package (Constraint #2); strict-casts + strict-raw-types remain on (Constraint #3)
- [ ] Per-package barrel-export soft caps (S25 L2 cap reference) not breached: `dartclaw_workflow ≤35`, `dartclaw_config ≤50`, `dartclaw_core ≤80`, `dartclaw_models ≤25`

## Scenarios

### Workflow code references owner-package types post-migration
- **Given** `packages/dartclaw_workflow/lib/src/workflow/approval_step_runner.dart` previously imported `package:dartclaw_models/dartclaw_models.dart show ActionNode, WorkflowRun, WorkflowStep`
- **When** S22 completes and `WorkflowDefinition`/`WorkflowRun` ship from `dartclaw_workflow`
- **Then** the file imports those types from a same-package `'workflow_definition.dart'` / `'workflow_run.dart'` (or a narrower internal entry-point) AND `dart analyze` exits 0 AND `approval_step_runner_test.dart` stays green AND no `package:dartclaw_workflow/...` file imports `package:dartclaw_models/dartclaw_models.dart` for any migrated symbol

### TaskEventKind is now an enum and switch coverage is compiler-checked
- **Given** post-migration `package:dartclaw_core/dartclaw_core.dart show TaskEventKind`
- **When** a developer writes `final r = switch (kind) { TaskEventKind.statusChanged => 'a', TaskEventKind.toolCalled => 'b' };` (deliberately omitting cases)
- **Then** `dart analyze` reports a `non_exhaustive_switch_expression` error pointing at the missing cases — the same exhaustiveness guarantee the sealed hierarchy provided is preserved by the enum (TD-053 closure verified by compile-time check, not a runtime test)

### S10 fitness functions stay green during the move
- **Given** all six L1 fitness tests currently pass on `main`
- **When** S22 commit chain lands (relocations + barrel updates + `_coreLocCeiling` flip)
- **Then** `dart test packages/dartclaw_testing/test/fitness/` exits 0 — `barrel_show_clauses_test.dart` (every new export uses `show`), `max_file_loc_test.dart` (no relocated file >1,500 LOC; `workflow_definition.dart` at 1,349 LOC stays under), `package_cycles_test.dart` (no new cycle introduced — `dartclaw_workflow → dartclaw_core` and `dartclaw_workflow → dartclaw_models` already exist; `Project` move from models → config does not create a config↔workflow cycle because `dartclaw_workflow` already depends on `dartclaw_config`)

### TD-102 attractor brings dartclaw_core back below 12,000 LOC
- **Given** `dartclaw_core/lib/` is currently 12,478 LOC; after additions (c)+(d) bring in ~445 LOC of `task_event` + `turn_trace*` + `tool_call_record`, raw delta would be ~12,923 LOC
- **When** S22 also migrates non-runtime-primitive material OUT of `dartclaw_core/lib/` (candidates surfaced during TI08 audit)
- **Then** `find packages/dartclaw_core/lib -name '*.dart' | xargs wc -l | tail -1` reports ≤12,000 AND `dev/tools/arch_check.dart`'s `_coreLocCeiling` is `12000` AND `dart run dev/tools/arch_check.dart` exits 0 — TD-102 closed

### External consumer pinned to old import path breaks loudly (CHANGELOG-mediated)
- **Given** a hypothetical external consumer with `import 'package:dartclaw_models/dartclaw_models.dart' show WorkflowDefinition;`
- **When** they upgrade to 0.16.5 without reading the CHANGELOG
- **Then** `dart pub get` succeeds but `dart analyze` fails with `Undefined name 'WorkflowDefinition'` — the breakage is loud, fast, and the CHANGELOG "Breaking API Changes" subsection contains a one-line migration row showing the new import path. **Soft re-export decision** (TI12): default = no soft re-exports (no measurable external consumers; pub.dev placeholder-only per ADR-008); option to ship one-release `@Deprecated('Moved to package:dartclaw_workflow/dartclaw_workflow.dart')` re-exports from `dartclaw_models.dart` is rejected as default to keep the migration loud and finite, but the door is left open if a beta tester surfaces a real consumer during 0.16.5 RC validation

### Wire-format compatibility round-trip
- **Given** a `WorkflowRun` payload persisted under 0.16.4 (e.g. an existing test fixture or an integration-test database)
- **When** 0.16.5 deserializes the payload via the relocated `WorkflowRun.fromJson`
- **Then** the resulting object is byte-identical (or equality-equivalent) to a fresh 0.16.4 deserialization — no field renames, no type changes, no JSON shape drift; same property holds for `WorkflowDefinition`, `Project`, `TaskEvent`, `TurnTrace`, `SkillInfo` (Constraint #1)

## Scope & Boundaries

### In Scope
- **Move (a) workflow domain** — relocate `workflow_definition.dart` + `workflow_run.dart` from `dartclaw_models/lib/src/` to `dartclaw_workflow/lib/src/workflow/`; update `dartclaw_workflow` barrel; remove from `dartclaw_models` barrel
- **Move (b) project domain** — relocate `project.dart` from `dartclaw_models/lib/src/` to `dartclaw_config/lib/src/` (collocation chosen; see Architecture Decision); update both barrels
- **Move (c) task-event domain + TaskEventKind enum-ification** — relocate `task_event.dart` to `dartclaw_core/lib/src/task/`; convert `TaskEventKind` sealed class with 6 empty subclasses to an `enum`; update barrels; closes TD-053
- **Move (d) turn-trace domain** — relocate `turn_trace.dart` + `turn_trace_summary.dart` + `tool_call_record.dart` to `dartclaw_core/lib/src/turn/` (new subdirectory)
- **Move (e) skill info** — relocate `skill_info.dart` to `dartclaw_workflow/lib/src/skills/`
- **Workspace-wide import-site updates** — all 89 importers of `package:dartclaw_models` retarget any migrated-symbol imports to the new owner barrel
- **TD-102 attractor** — audit `dartclaw_core/lib/` for non-runtime-primitive material; relocate enough to bring total LOC ≤12,000; lower `_coreLocCeiling` 13,000 → 12,000 in the same commit chain
- **CHANGELOG entry** — open the shared "Breaking API Changes" 0.16.5 subsection with the import-path migration table
- **Backlog hygiene** — delete or annotate TD-053 + TD-102 in `dev/state/TECH-DEBT-BACKLOG.md`
- **Per-package CLAUDE.md updates** — update `packages/dartclaw_models/CLAUDE.md` (remove migrated types from "Role" + "Key files"), `packages/dartclaw_workflow/CLAUDE.md` (add workflow models + `SkillInfo`), `packages/dartclaw_core/CLAUDE.md` (add task-event + turn-trace types)

### What We're NOT Doing
- **Behavioural changes / runtime semantics changes** — relocations are pure namespace moves; no method-signature changes; persistence shape unchanged. Renames belong to S36 (the next story under the same banner) — do not touch class or symbol names here. (Reason: keeps the migration's diff reviewable and the regression net's signal-to-noise high.)
- **JSON wire-format changes** — `toJson()`/`fromJson` shapes are byte-stable; no field renames, no type narrowing/widening. (Reason: persistence + REST/SSE/JSONL compatibility per Constraint #1.)
- **Touching `dartclaw_models` survivors** — `Session`/`Message`/`SessionKey`/`ChannelType`/`AgentDefinition`/`MemoryChunk` and the supporting `channel_config*`/`session_scope_config`/`container_config`/`task_type` files stay put. (Reason: they're the shared kernel that defines the bottom of the DAG.)
- **Creating a new `dartclaw_project` package** — collocate `Project` runtime types with `ProjectConfig` in `dartclaw_config` instead. (Reason: lighter — avoids a new pubspec, new workspace member, new boilerplate.) Reversible if the audit at TI03 surfaces a hard reason to split.
- **Soft re-exports as the default** — no `@Deprecated` re-exports from `dartclaw_models.dart`. (Reason: pub.dev is placeholder-only per ADR-008; no measurable external consumers; loud break is preferred. Reversible — TI12 can flip the decision if a real consumer surfaces during RC.)

### Agent Decision Authority
- **Autonomous**:
  - Choosing exact target file paths within the chosen owner package (e.g. one combined `workflow_models.dart` vs split files) — guided by existing package convention.
  - Deciding which `dartclaw_core/lib/` material is "non-runtime-primitive" enough to migrate out for the TD-102 attractor (preferred targets: pure data shapes, parsing helpers, constants — not interfaces, not orchestration).
  - Whether to fold `dartclaw_models/lib/src/` survivor files (e.g. inline `channel_type.dart` 14 LOC into `models.dart`) for cleanliness — only if it reduces total file count without breaking show-clause hygiene.
- **Escalate**:
  - If the TD-102 attractor cannot achieve `dartclaw_core/lib/` ≤12,000 LOC without sacrificing a load-bearing interface or service, stop and document — flipping `_coreLocCeiling` upward is not in scope for this FIS; raise to plan owner with concrete numbers and a candidate-cut list.
  - If a real external consumer surfaces during the work (any GitHub issue, pub.dev download metric flip, beta-tester report), flip the soft re-export decision and document in TI12.

## Architecture Decision

**We will**:
1. Move the five model groupings to their owning packages: workflow models → `dartclaw_workflow`, `Project`+strategies → `dartclaw_config` (collocated with `ProjectConfig`/`ProjectDefinition`), `TaskEvent`+subtypes + `TurnTrace`/`TurnTraceSummary`/`ToolCallRecord` → `dartclaw_core`, `SkillInfo` → `dartclaw_workflow`.
2. Convert `TaskEventKind` sealed class with 6 empty subclasses → Dart `enum` (closes TD-053). Pattern-match `switch (kind) { TaskEventKind.x => …, … }` continues to be compiler-exhaustive.
3. Default to **no soft re-exports** from `dartclaw_models.dart` (loud, finite break). Decision recorded as reversible: if a real external consumer surfaces during 0.16.5 RC validation, ship one-release `@Deprecated('Moved to package:<owner>/<owner>.dart')` re-exports.
4. Place `Project` runtime types in `dartclaw_config` (collocation) rather than create a new `dartclaw_project` package.
5. Run the **TD-102 attractor** in the same commit chain: identify and relocate non-runtime-primitive material out of `dartclaw_core/lib/` to balance the (c)+(d) inflows; lower `_coreLocCeiling` 13,000 → 12,000.

**Rationale**:
- **Pub.dev placeholder-only state (per ADR-008) means the visible-API break window is open**: no measurable external consumers depend on the import paths. Deferring to 0.16.7 would force a second sprint to absorb the migration note for no extra safety. (Confirmed by PRD Decisions Log row "FR5 model migration promoted from stretch to planned target".)
- **`Project` collocation with `ProjectConfig`** is lighter than a new package: `dartclaw_config` already hosts the YAML-config twin (`ProjectConfig`, `ProjectDefinition`, `parseProjectConfig`, `validateProjectLocalPath`); the runtime `Project` value type is the natural sibling. A new `dartclaw_project` package would add boilerplate (pubspec, barrel, workspace member, README) for ~333 LOC of model code.
- **Enum over sealed class for `TaskEventKind`** is the canonical Dart shape for fixed, payload-free variant sets; the original sealed-class encoding predates Dart 3 enums and is gratuitous OOP weight.
- **TD-102 attractor must run in the same commit chain** because (c)+(d) push `dartclaw_core/lib/` past the temporary 13,000 ratchet; without compensating moves, the ratchet would have to be permanently loosened — which contradicts the constraint's purpose. Bundling closes the loop in one coherent break.

**Alternatives considered**:
1. **Defer FR5 to 0.16.7** — rejected: would require a second sprint to absorb the CHANGELOG migration note and re-run the import-update sweep; pub.dev placeholder-only state means this is a now-or-pay-twice decision. (Per PRD Decisions Log.)
2. **Migrate models without the TD-102 attractor** — rejected: `dartclaw_core` ratchet would need permanent loosening to 13,000 to absorb the (c)+(d) inflows, defeating the constraint's purpose; the 12,000 ceiling has been the standing target since 0.16.4 baseline.
3. **Create a new `dartclaw_project` package** — rejected: adds workspace member + pubspec + README + barrel + dartdoc lint config for ~333 LOC; collocation with `ProjectConfig` (also a project-domain type) is simpler and reversible if a future story (e.g. SDK-level decoupling) surfaces a reason to split.
4. **Ship soft re-exports from `dartclaw_models.dart` by default** — rejected: pub.dev placeholder-only; no consumers to mitigate for; soft re-exports add a deprecation-removal task to 0.16.6 with no proven benefit. Decision is reversible if RC validation surfaces a real consumer.
5. **Convert `TaskEventKind` to enum in a separate story** — rejected: it lives inside the moved `task_event.dart` file; doing both in one move halves the diff churn (and TD-053 explicitly co-targets this story per plan line 15).

No ADR required; this is a packaging refactor with the rationale above. The "Breaking API Changes" CHANGELOG subsection serves as the durable artefact.

## Technical Overview

### Data Models (relocations only — shape unchanged)

The following types relocate by file with no signature changes. JSON `toJson`/`fromJson` round-trip is byte-stable.

- **Workflow → `dartclaw_workflow`**: `WorkflowDefinition`, `WorkflowStep`, `WorkflowNode` (sealed) + subtypes `ActionNode`/`ForeachNode`/`LoopNode`/`MapNode`/`ParallelGroupNode`, `WorkflowVariable`, `WorkflowLoop`, `WorkflowGitPublishStrategy`/`WorkflowGitCleanupStrategy`/`WorkflowGitArtifactsStrategy`/`WorkflowGitExternalArtifactMount`/`WorkflowGitWorktreeStrategy`/`WorkflowGitStrategy`, `MergeResolveEscalation`/`MergeResolveConfig`, `StepConfigDefault`, `OnFailurePolicy`, `ExtractionType`/`ExtractionConfig`, `OutputFormat`/`OutputMode`/`OutputConfig`, `WorkflowRun`, `WorkflowRunStatus`, `WorkflowExecutionCursor`, `WorkflowExecutionCursorNodeType`, `WorkflowWorktreeBinding`, `SkillInfo`, `SkillSource`.
- **Project → `dartclaw_config`**: `Project`, `ProjectAuthStatus`, `ProjectStatus`, `CloneStrategy`, `PrStrategy`, `PrConfig`.
- **Task event → `dartclaw_core`**: `TaskEvent`, `TaskEventKind` (now `enum`), `StatusChanged`, `ToolCalled`, `ArtifactCreated`, `StructuredOutputInlineUsed`, `StructuredOutputFallbackUsed`, `PushBack`, `TokenUpdate`, `TaskErrorEvent`, `Compaction`.
- **Turn trace → `dartclaw_core`**: `TurnTrace`, `computeEffectiveTokens`, `TurnTraceSummary`, `ToolCallRecord`.

### Integration Points

- **No new wire-format integration**. Persistence (`dartclaw_storage` SQLite repos), REST (`dartclaw_server/lib/src/api/`), SSE (`task_sse_routes.dart`, `trace_routes.dart`), and JSONL control-protocol envelopes are unchanged — only import paths shift.
- **Barrel re-exports**: `dartclaw_workflow.dart`, `dartclaw_core.dart`, `dartclaw_config.dart` gain `show`-clause exports for the migrated types; `dartclaw_models.dart` removes them. Barrel-export soft caps stay within S25 limits.
- **Fitness suite** (S10): `barrel_show_clauses_test.dart`, `max_file_loc_test.dart`, `package_cycles_test.dart`, `constructor_param_count_test.dart` operate as the regression net; `dev/tools/arch_check.dart` covers the LOC ratchet.

## Code Patterns & External References

```
# type | path/url | why needed
file   | packages/dartclaw_models/lib/dartclaw_models.dart                          | Current barrel surface — defines the migration universe; survivor set after S22 is the show-list with workflow/project/task-event/turn-trace/skill-info entries removed
file   | packages/dartclaw_models/lib/src/workflow_definition.dart                  | 1,349-LOC mover (whole file relocates); preserve every show entry in target barrel
file   | packages/dartclaw_models/lib/src/workflow_run.dart                         | 388 LOC mover
file   | packages/dartclaw_models/lib/src/project.dart                              | 333 LOC mover — collocates with ProjectConfig in dartclaw_config
file   | packages/dartclaw_models/lib/src/task_event.dart:4                         | sealed class TaskEventKind with 6 empty subclasses → convert to enum (TD-053)
file   | packages/dartclaw_models/lib/src/{turn_trace,turn_trace_summary,tool_call_record}.dart | 163+71+49 LOC; relocate to packages/dartclaw_core/lib/src/turn/ (new subdir)
file   | packages/dartclaw_models/lib/src/skill_info.dart                           | 128 LOC mover → packages/dartclaw_workflow/lib/src/skills/
file   | packages/dartclaw_workflow/lib/dartclaw_workflow.dart                      | Target barrel — add migrated types under explicit show clauses
file   | packages/dartclaw_core/lib/dartclaw_core.dart                              | Target barrel — add migrated types; keep within ≤80-export soft cap
file   | packages/dartclaw_config/lib/dartclaw_config.dart                          | Target barrel — add Project + strategies; ≤50-export soft cap
file   | packages/dartclaw_models/CLAUDE.md                                         | Update Role + Key files lists (Boy-Scout rule per root CLAUDE.md)
file   | packages/dartclaw_workflow/CLAUDE.md                                       | Update Role list to include workflow models + SkillInfo
file   | packages/dartclaw_core/CLAUDE.md                                           | Update Role list to include task-event + turn-trace types
file   | dev/tools/arch_check.dart:9                                                | const _coreLocCeiling = 13000 → 12000 (same commit chain)
file   | dev/state/TECH-DEBT-BACKLOG.md#td-053--taskeventkind-sealed-class-should-be-an-enum | Delete or mark Resolved-by-S22
file   | dev/state/TECH-DEBT-BACKLOG.md#td-102--trim-dartclaw_corelib-back-below-the-12000-line-ratchet | Delete or mark Resolved-by-S22
file   | CHANGELOG.md                                                               | Open shared "Breaking API Changes" 0.16.5 subsection with import-path migration table
file   | packages/dartclaw_workflow/lib/src/workflow/approval_step_runner.dart:5    | Reference import-update pattern (currently imports ActionNode/WorkflowRun/WorkflowStep from dartclaw_models)
file   | packages/dartclaw_testing/lib/src/fake_project_service.dart                | Test fake — import path retargets to dartclaw_config
doc    | dev/specs/0.16.5/.technical-research.md#shared-architectural-decisions     | Decisions #3 (S10→S22 net), #6 (S22→S36 banner), #17 (shrink target)
doc    | dev/specs/0.16.5/fis/s10-level-1-governance-checks.md                      | S10 fitness suite is this story's regression net
```

## Constraints & Gotchas

- **Constraint**: `dartclaw_models` may only depend on `collection` (per package CLAUDE.md). Survivor-set must not gain transitive deps. — Workaround: confirm by reading `pubspec.yaml` of the survivor package post-move; no dep should be added.
- **Constraint**: `dartclaw_core` may not import `package:sqlite3` (arch_check #2) and may only depend on `dartclaw_models`/`dartclaw_security`/`dartclaw_config` + a small allowed list (per package CLAUDE.md). The migrated `TaskEvent`/`TurnTrace`/`ToolCallRecord` types must remain pure data — Workaround: relocate verbatim; do not bring along any `dart:io` or sqlite-touching helpers.
- **Constraint**: `dartclaw_workflow` barrel ≤35 exports (post-S09 + S25 soft cap). Adding `WorkflowDefinition` + node subtypes + git/output strategies + `WorkflowRun` family + `SkillInfo` is ~30 named symbols — Workaround: collapse fine-grained `show` clauses where one re-export per relocated file is sufficient (e.g. `export 'src/workflow/workflow_definition.dart' show ActionNode, ForeachNode, LoopNode, MapNode, …;`); review against `barrel_export_count_test.dart` allowlist.
- **Critical**: `TaskEventKind` enum-ification must preserve any persisted `name` strings — Workaround: enum value identifiers must match the previous sealed-class subclass names in lower-camelCase (e.g. `StatusChanged` → `statusChanged`); add a `fromName(String)` factory if there's a JSON serializer that round-trips the kind by name; verify by running existing `task_event` round-trip tests.
- **Avoid**: Renaming any class, method, or field during this story. — Instead: rename batch belongs to S36; keep S22's diff to relocations + barrel updates + the `TaskEventKind` enum-ification (which is a structural, not naming, change).
- **Gotcha**: `package_cycles_test.dart` will fire if the `Project` move accidentally creates a `dartclaw_config → dartclaw_workflow` edge or similar. Verify the dependency direction stays `dartclaw_workflow → dartclaw_config → dartclaw_models` (existing) — Workaround: keep `Project` runtime types free of workflow-domain references; if anything pulls a `WorkflowDefinition` reference, refactor that reference into `dartclaw_workflow` or `dartclaw_server` instead.
- **Gotcha**: Consumers in `dartclaw_server` import `package:dartclaw_models` heavily for both moved and survivor types. The mechanical update is per-symbol, not per-line — a single import line may need to split into two (e.g. `dartclaw_models` for `Session`, `dartclaw_workflow` for `WorkflowRun`). — Workaround: rely on `dart analyze`'s `undefined_identifier` errors as a worklist; resolve top-down.
- **Critical**: TD-102 attractor candidates inside `dartclaw_core/lib/` must NOT be load-bearing interfaces or services that other packages depend on. Preferred relocate-out targets: pure data shapes, parsing helpers, constants files. — Workaround: TI08 produces a candidate list before any code moves; review the list before relocating.

## Implementation Plan

> **Vertical slice ordering**: Audit (TI01) → workflow move + workspace import sweep (TI02–TI07) → core moves with TaskEventKind enum-ification (TI04) → TD-102 attractor + ratchet flip (TI08–TI09) → verification + governance + CHANGELOG (TI10–TI16). The story is structurally large (5 moves + attractor) but each task is mechanical; ordering keeps the workspace compilable after each task except TI04 (which is atomic by design).

### Implementation Tasks

- [ ] **TI01** Audit produced: a checked-in working note (or task-comment table here in `Implementation Observations`) lists every named type currently exported from `package:dartclaw_models` for each of the 5 migration groupings (a)–(e) with target package + target file path; survivor set is named explicitly.
  - Confirm the 9 `TaskEventKind` subtypes via `grep -n 'extends TaskEventKind' packages/dartclaw_models/lib/src/task_event.dart`; confirm no migrated type imports a `dartclaw_models` survivor (else collocate the dependency in the move). Reference the current barrel at `packages/dartclaw_models/lib/dartclaw_models.dart` as the source of truth for the type universe.
  - **Verify**: `Manual: produced audit table covers every type currently exported by dartclaw_models barrel; agent can name target package + target file path for each migrated symbol`.

- [ ] **TI02** `WorkflowDefinition` family relocated to `dartclaw_workflow`: `packages/dartclaw_models/lib/src/workflow_definition.dart` → `packages/dartclaw_workflow/lib/src/workflow/workflow_definition.dart`; same for `workflow_run.dart` → `packages/dartclaw_workflow/lib/src/workflow/workflow_run.dart`. Source files no longer exist in `dartclaw_models/lib/src/`.
  - Move files verbatim — no signature edits. Update target package barrel to add explicit `show` exports for every type previously in the `dartclaw_models` barrel's workflow + workflow_run blocks. Pattern reference: existing `dartclaw_workflow.dart` `export 'src/workflow/...'` entries.
  - **Verify**: `Test: rg "package:dartclaw_models.*WorkflowDefinition|package:dartclaw_models.*WorkflowRun|package:dartclaw_models.*WorkflowStep|package:dartclaw_models.*WorkflowExecutionCursor" packages/ apps/ returns zero matches AND dart analyze on packages/dartclaw_workflow exits 0`.

- [ ] **TI03** `Project` family relocated to `dartclaw_config`: `packages/dartclaw_models/lib/src/project.dart` → `packages/dartclaw_config/lib/src/project_runtime.dart` (or `project.dart` if no name collision; current `dartclaw_config/lib/src/project_config.dart` is the YAML twin — choose a non-colliding filename). Update `dartclaw_config` barrel to add `Project, ProjectAuthStatus, ProjectStatus, CloneStrategy, PrStrategy, PrConfig` under one `export 'src/<filename>.dart' show …` clause.
  - Decision recorded in Architecture Decision: collocate, do not create `dartclaw_project` package.
  - **Verify**: `Test: rg "package:dartclaw_models.*\\bProject\\b|CloneStrategy|PrStrategy|PrConfig" packages/ apps/ returns matches only inside the new dartclaw_config file path AND dart analyze on packages/dartclaw_config exits 0 AND dartclaw_config barrel-export count ≤50`.

- [ ] **TI04** `TaskEvent` family relocated to `dartclaw_core` AND `TaskEventKind` converted from sealed class to `enum`: `packages/dartclaw_models/lib/src/task_event.dart` → `packages/dartclaw_core/lib/src/task/task_event.dart`. The 6-subclass-empty `sealed class TaskEventKind` becomes `enum TaskEventKind { … }` with values matching previous subclass names in lower-camelCase. Switch expressions in consumers stay compiler-exhaustive.
  - **Atomic** task — pre-edit, the workspace will not compile until both the move and the enum conversion land together. Carry any `name`-string round-trip expectations forward (Constraint #1: persistence shape unchanged; verify by running existing `task_event` JSON tests if present, else add a round-trip test).
  - Add `TaskEvent` + 9 subtypes + `TaskEventKind` to `dartclaw_core` barrel `show` clauses.
  - **Verify**: `Test: dart test packages/dartclaw_core packages/dartclaw_server -t TaskEvent green AND non_exhaustive_switch_expression analyzer error fires when a TaskEventKind case is omitted in any switch (verify by deliberately commenting one case in a unit test fixture and observing dart analyze; revert) AND TD-053 entry deleted/annotated in dev/state/TECH-DEBT-BACKLOG.md`.

- [ ] **TI05** Turn-trace family relocated to `dartclaw_core/lib/src/turn/` (new subdirectory): `turn_trace.dart` + `turn_trace_summary.dart` + `tool_call_record.dart`. `dartclaw_core` barrel exports `TurnTrace`, `computeEffectiveTokens`, `TurnTraceSummary`, `ToolCallRecord` under `show` clauses.
  - Pattern reference: existing `packages/dartclaw_core/lib/src/task/` and `lib/src/events/` subdirectories — keep one file per top-level type group.
  - **Verify**: `Test: rg "package:dartclaw_models.*(TurnTrace|TurnTraceSummary|ToolCallRecord|computeEffectiveTokens)" packages/ apps/ returns zero matches AND dart analyze on packages/dartclaw_core exits 0`.

- [ ] **TI06** `SkillInfo` relocated to `dartclaw_workflow`: `packages/dartclaw_models/lib/src/skill_info.dart` → `packages/dartclaw_workflow/lib/src/skills/skill_info.dart`. `dartclaw_workflow` barrel exports `SkillInfo`, `SkillSource` (existing `skills/` subdir already hosts `skill_registry.dart` / `skill_provisioner.dart`).
  - **Verify**: `Test: rg "package:dartclaw_models.*(SkillInfo|SkillSource)" packages/ apps/ returns zero matches AND dart analyze workspace exits 0`.

- [ ] **TI07** All workspace import sites updated: every previously-imported `package:dartclaw_models` migrated symbol is now imported from its owner package. The `dartclaw_models` barrel `show` list contains only the survivor set.
  - The 89-file import universe is the worklist. Mechanical: split single `dartclaw_models` imports that mixed survivor + migrated symbols into two imports. Use `dart analyze` errors as the worklist driver — resolve until 0 errors.
  - **Verify**: `Test: rg "package:dartclaw_models" packages/ apps/ shows imports only for survivor types (Session, Message, SessionKey, ChannelType, AgentDefinition, MemoryChunk, plus channel_config*/session_scope_config/container_config/task_type families) AND dart analyze --fatal-warnings --fatal-infos workspace exits 0`.

- [ ] **TI08** TD-102 attractor candidate list produced and applied: a list of non-runtime-primitive material in `dartclaw_core/lib/` is identified (data shapes, parsing helpers, constants) with target package + LOC delta. Enough material is migrated OUT to bring `dartclaw_core/lib/` ≤12,000 LOC. Audit recorded under `Implementation Observations` (or as a working note) so reviewers can confirm the chosen cuts.
  - Heuristic: `find packages/dartclaw_core/lib -name '*.dart' | xargs wc -l | sort -rn | head -20` surfaces the biggest files; cross-reference against package boundaries (data → models, parsing → config). Avoid load-bearing interfaces (e.g. `TurnManager`, `HarnessPool`) — those are explicitly here per S11 boundary correction.
  - **Verify**: `Test: find packages/dartclaw_core/lib -name '*.dart' | xargs wc -l | tail -1 reports ≤12000 AND audit list of moved-out items is recorded with rationale`.

- [ ] **TI09** `_coreLocCeiling` lowered 13,000 → 12,000 in `dev/tools/arch_check.dart` in the same commit chain as TI08; `dart run dev/tools/arch_check.dart` exits 0.
  - **Verify**: `Test: rg "_coreLocCeiling = 12000" dev/tools/arch_check.dart matches AND rg "_coreLocCeiling = 13000" dev/tools/arch_check.dart returns zero AND dart run dev/tools/arch_check.dart exits 0`.

- [ ] **TI10** `dartclaw_models` survivor set verified: `find packages/dartclaw_models/lib -name '*.dart' | xargs wc -l | tail -1` reports ≤1,200 LOC; surviving src files are exactly `{models, agent_definition, channel_config, channel_config_provider, channel_type, container_config, session_key, session_scope_config, task_type}.dart` plus the `dartclaw_models.dart` barrel.
  - The barrel `show` list reflects only the survivor set; no `@Deprecated` re-exports for migrated types (per default decision in TI12).
  - **Verify**: `Test: find packages/dartclaw_models/lib -name '*.dart' reports ≤10 files AND total LOC ≤1200 AND barrel show clauses cover only survivor types`.

- [ ] **TI11** S10 fitness suite + `arch_check.dart` green end-to-end after all relocations: `dart test packages/dartclaw_testing/test/fitness/` exits 0; `dart run dev/tools/arch_check.dart` exits 0; `dart format --set-exit-if-changed packages apps` exits 0.
  - If `barrel_show_clauses_test.dart` flags a new wholesale export, fix at the offending barrel — never mass-edit allowlist entries. If `package_cycles_test.dart` fires, the dependency direction is wrong; revert the offending cross-package edge.
  - **Verify**: `Test: dart test packages/dartclaw_testing/test/fitness/ exits 0 AND dart run dev/tools/arch_check.dart exits 0 AND dart format --set-exit-if-changed packages apps exits 0`.

- [ ] **TI12** Soft re-export decision recorded: the default decision (no soft re-exports from `dartclaw_models.dart`) is documented inline in this FIS's `Implementation Observations` with rationale. If 0.16.5 RC validation surfaces a real external consumer (any signal beyond pub.dev placeholder state), the decision flips and one-release `@Deprecated('Moved to package:<owner>/<owner>.dart')` re-exports ship from `dartclaw_models.dart` for the affected groupings.
  - Default: no re-exports. (See Architecture Decision.)
  - **Verify**: `Manual: Implementation Observations contains the decision record; if flipped, dartclaw_models barrel contains @Deprecated re-exports for the named groupings only`.

- [ ] **TI13** CHANGELOG updated: `CHANGELOG.md` 0.16.5 section gains a `### Breaking API Changes` subsection (single banner — S36 + S23 R-L2 will append here when they land). Subsection contains an import-path migration table covering every migrated symbol grouping.
  - Format reference: rows of the form ``` `WorkflowDefinition`, `WorkflowStep`, `WorkflowRun`, `WorkflowExecutionCursor` (and node subtypes, output/git strategies) — moved from `package:dartclaw_models/dartclaw_models.dart` to `package:dartclaw_workflow/dartclaw_workflow.dart` ```.
  - **Verify**: `Test: rg "Breaking API Changes" CHANGELOG.md returns a match under the 0.16.5 section AND every migrated symbol grouping has a row`.

- [ ] **TI14** Per-package `CLAUDE.md` files updated: `packages/dartclaw_models/CLAUDE.md` "Role" sentence and "Key files" list drop the migrated types. `packages/dartclaw_workflow/CLAUDE.md` "Role" gains workflow models + `SkillInfo`. `packages/dartclaw_core/CLAUDE.md` "Role" gains task-event + turn-trace types. Drift would make these files actively misleading.
  - **Verify**: `Test: rg "WorkflowDefinition|WorkflowRun|TaskEvent|TurnTrace|SkillInfo|Project " packages/dartclaw_models/CLAUDE.md returns zero matches in the Role + Key files sections AND the workflow + core CLAUDE.md files mention them in their Role lists`.

- [ ] **TI15** TD-053 + TD-102 backlog hygiene: both entries in `dev/state/TECH-DEBT-BACKLOG.md` are deleted (or annotated `**Status**: Resolved by S22 (0.16.5)`) per the "Open items only" backlog policy.
  - **Verify**: `Test: rg "TD-053|TD-102" dev/state/TECH-DEBT-BACKLOG.md returns zero matches OR matches only the Resolved-by-S22 annotation`.

- [ ] **TI16** Workspace-wide validation: `dart analyze --fatal-warnings --fatal-infos` workspace exits 0; `dart test` workspace green; integration suite (`dart test -t integration`) not regressed; `dart format --set-exit-if-changed packages apps` green; `bash dev/tools/release_check.sh --quick` exits 0.
  - **Verify**: `Test: dart analyze workspace + dart test workspace + dart format --set-exit-if-changed all exit 0 AND release_check.sh --quick exits 0`.

### Testing Strategy
- [TI02,TI07] Workflow move scenario → unit-level: existing `packages/dartclaw_workflow/test/workflow/*.dart` suite remains green (≥30 test files exercising `WorkflowDefinition`/`WorkflowStep`/`WorkflowRun`).
- [TI04] TaskEventKind enum-ification → exhaustive switch scenario: confirm `non_exhaustive_switch_expression` analyzer diagnostic via deliberate one-case omission in a fixture (revert before commit).
- [TI04] JSON wire-format compatibility scenario → existing `task_event` round-trip tests stay green; add one if absent.
- [TI02,TI03,TI04,TI05,TI06] Wire-format compatibility scenario → integration: `dart test -t integration` green (catches any regression in persistence round-trip via existing fixtures).
- [TI08,TI09,TI11] TD-102 attractor scenario → `arch_check.dart` enforcement: ratchet flip + `dartclaw_core/lib/` ≤12,000 verified by the same script that gates the constraint.
- [TI11] S10 fitness regression net scenario → all six L1 fitness tests + format gate exit 0 against the post-S22 tree.
- [TI12,TI13] External-consumer break scenario → manual: simulate a `package:dartclaw_models show WorkflowDefinition` import in a scratch test file; confirm `Undefined name 'WorkflowDefinition'` analyzer error; CHANGELOG row matches the new import path. (Discard scratch.)

### Validation
> Standard validation (build/test/lint-analysis + visual + 1-pass remediation) is handled by exec-spec.
- High-risk story: after TI16, run `bash dev/tools/release_check.sh --quick` to validate against the standing release gate set (`dart format`/`dart analyze`/`dart test` + spec-cleanup state). Failure aborts the story; fix-forward.

### Execution Contract
- Implement tasks in listed order. Each **Verify** line must pass before proceeding to the next task.
- TI04 is atomic (move + enum conversion together) — do NOT split it across commits; the workspace is uncompilable mid-task by design.
- TI08 + TI09 are paired (attractor + ratchet flip) — land in the same commit chain so the constraint never goes slack on `main`.
- TI13 (CHANGELOG) opens the shared "Breaking API Changes" 0.16.5 subsection — do NOT create a per-story banner; S36 + S23 R-L2 will append here.
- After all tasks: `dart analyze --fatal-warnings --fatal-infos` workspace, `dart test` workspace, `dart format --set-exit-if-changed packages apps`, `dart run dev/tools/arch_check.dart`, `dart test packages/dartclaw_testing/test/fitness/`, `bash dev/tools/release_check.sh --quick` — all must exit 0.
- Keep `rg "TODO|FIXME|placeholder|not.implemented" <changed-files>` clean.
- Mark task checkboxes immediately on completion — do not batch.

## Final Validation Checklist

- [ ] **All success criteria** met (every "Must Be TRUE" line above checked)
- [ ] **All tasks** TI01–TI16 fully completed, verified, checkboxes checked
- [ ] **No regressions** — `dart test` workspace + `dart test -t integration` (smoke at minimum) green; SSE/REST/JSONL envelope shapes byte-identical
- [ ] **Plan-spec alignment** — every plan AC (line 697–703) maps to a Success Criterion or task Verify line above; nothing dropped silently
- [ ] **Reverse coverage** — every Success Criterion above appears in plan AC line 697–703 OR is a derived structural assertion required to satisfy a plan AC (e.g. wire-format round-trip → "behavioural-zero-regression")
- [ ] **TD-053 + TD-102 closure** — backlog entries deleted/annotated; closure mentioned in CHANGELOG migration note
- [ ] **CLAUDE.md drift** — `packages/dartclaw_models/CLAUDE.md` no longer lists migrated types; target packages' CLAUDE.md files updated

## Implementation Observations

> _Managed by exec-spec post-implementation — append-only. Tag semantics: see [`data-contract.md`](${CLAUDE_PLUGIN_ROOT}/references/data-contract.md) (FIS Mutability Contract, tag definitions). AUTO_MODE assumption-recording: see [`automation-mode.md`](${CLAUDE_PLUGIN_ROOT}/references/automation-mode.md). Spec authors: leave this section empty._

_No observations recorded yet._

---

## Plan-format migration addendum (2026-05-06)

> Migrated from the pre-template `plan.md` story body during the plan-template reformat. Verbatim copy of the plan's `**Acceptance Criteria**`, `**Key Scenarios**`, and any detailed `**Scope**` paragraphs not already represented above. Authoritative spec content lives in this FIS; the plan now carries only a 1-2 sentence Scope summary plus catalog metadata.

### From plan.md — Scope detail (migrated from old plan format)

**Scope**: Move domain-specific models out of `dartclaw_models` to their owning packages. (a) `WorkflowDefinition` (1,349 LOC alone), `WorkflowStep`, `WorkflowRun`, `WorkflowExecutionCursor` → `dartclaw_workflow`. (b) `Project`, `CloneStrategy`, `PrStrategy`, `PrConfig` → `dartclaw_config` (already hosts `ProjectConfig`/`ProjectDefinition`) or a new `dartclaw_project` sub-module (decision during implementation). (c) `TaskEvent` + 9 subtypes → `dartclaw_core` (where `Task` lives); **during the move, convert `TaskEventKind` sealed class with 6 empty subclasses → `enum`** with `String get name` — pattern matching with `switch` continues to work (closes [TD-053](../../state/TECH-DEBT-BACKLOG.md#td-053--taskeventkind-sealed-class-should-be-an-enum)). (d) `TurnTrace`, `TurnTraceSummary`, `ToolCallRecord` → `dartclaw_core`. (e) `SkillInfo` → `dartclaw_workflow`. Update all import sites. `dartclaw_models` ends ≤1,200 LOC as the true shared kernel (Session, Message, SessionKey, ChannelType, AgentDefinition, MemoryChunk). Decide whether to ship a one-release soft re-export from `dartclaw_models.dart` for external consumers (record decision in FIS). Update `CHANGELOG.md` with a migration note.


### From plan.md — Note (2026-05-04 reconciliation)

**Note (2026-05-04 reconciliation)**: `dartclaw_models` total LOC has grown from the pre-audit 3,005 baseline to **3,555 LOC** as of `v0.16.4` (workflow_definition.dart alone is 1,349 LOC), so this story's migration surface is larger than originally scoped. Targets unchanged. Pair this with the **TD-102 attractor** decision (folded in 2026-05-04): `dartclaw_core/lib/` grew from 11,561 → 12,437 LOC during 0.16.4; the ratchet was temporarily raised from 12,000 → 13,000. Items (c) `TaskEvent` and (d) `TurnTrace`/`TurnTraceSummary`/`ToolCallRecord` migrate **into** `dartclaw_core` and would push it further over budget — so before/while landing those moves, identify non-runtime-primitive material in `dartclaw_core/lib/` that can move out (typically to `dartclaw_models` or `dartclaw_config`) to compensate. Net target: `dartclaw_core/lib/` returns ≤12,000 LOC, then lower the ratchet back down in `dev/tools/arch_check.dart` to keep the constraint biting. Closes [TD-102](../../state/TECH-DEBT-BACKLOG.md#td-102--trim-dartclaw_corelib-back-below-the-12000-line-ratchet) at the same commit chain.

### From plan.md — Acceptance Criteria addendum (migrated from old plan format)

**Acceptance Criteria**:
- [ ] `dartclaw_models` ≤1,200 LOC (must-be-TRUE)
- [ ] Workflow/project/task-event/turn-trace/skill-info models live in their owning packages (must-be-TRUE)
- [ ] `dart analyze` and `dart test` workspace-wide pass (must-be-TRUE)
- [ ] CHANGELOG migration note added
- [ ] Fitness functions from S10 remain green (model moves don't regress barrel hygiene or file size)
- [ ] **TD-102**: `dartclaw_core/lib/` total LOC ≤12,000; `_coreLocCeiling` in `dev/tools/arch_check.dart` lowered back from 13,000 → 12,000 in the same commit chain (must-be-TRUE)
- [ ] TD-102 entry deleted (or marked Resolved-by-S22) in public `dev/state/TECH-DEBT-BACKLOG.md`
