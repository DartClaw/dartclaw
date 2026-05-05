# S18 — DartclawServer Dep-Group Structs + Builder Collapse

**Plan**: ../plan.md
**Story-ID**: S18

## Feature Overview and Goal

Collapse `DartclawServer.compose()` static factory into `DartclawServerBuilder` — single construction path. Replace the ~60 scalar `required` fields on `DartclawServer._` with **6 dep-group structs** that mirror the existing `DartclawServerBuilder` sections. Constructor takes 6 struct params instead of ~60 scalars. Drives `server.dart` from 1,115 LOC down to ≤800 LOC and lets `constructor_param_count_test.dart` (S10) drop the temporary `DartclawServer` allowlist entry.

> **Technical Research**: [.technical-research.md](../.technical-research.md) _(see "S18" entry under per-story File Map; Shared Decision #27; binding constraints #1, #2, #28, #29, #71, #75)_

## Required Context

### From `prd.md` — "FR4: Structural Decomposition of Remaining Hotspots"
<!-- source: ../prd.md#fr4-structural-decomposition-of-remaining-hotspots -->
<!-- extracted: e670c47 -->
> **S18-applicable Acceptance Criteria** (verbatim):
> - `DartclawServer` ctor takes 6 dep-group structs, not 60+ scalars; `compose()` removed.
> - `max_file_loc_test.dart` and `constructor_param_count_test.dart` fitness functions pass.

### From `plan.md` — "S18: DartclawServer Dep-Group Structs + Builder Collapse"
<!-- source: ../plan.md#p-s18-dartclawserver-dep-group-structs--builder-collapse -->
<!-- extracted: e670c47 -->
> **Risk**: Low — constructor-only refactor
> **Scope**: Collapse `DartclawServer.compose()` static factory into `DartclawServerBuilder` — single construction path. Replace the ~60 scalar required fields in the `DartclawServer._` private constructor with 6 dep-group structs (names TBD during implementation, suggested: `_ServerCoreDeps`, `_ServerTurnDeps`, `_ServerChannelDeps`, `_ServerTaskDeps`, `_ServerObservabilityDeps`, `_ServerWebDeps`). Each struct mirrors a section of `DartclawServerBuilder`'s existing groupings. Constructor takes 6 struct params instead of 60 scalars. Target: `server.dart` ≤800 LOC (from 1,063).
>
> **Acceptance Criteria**:
> - `DartclawServer._` constructor takes ≤6 parameters (must-be-TRUE)
> - `compose()` static factory removed; `DartclawServerBuilder` is the single construction path (must-be-TRUE)
> - 6 dep-group structs exist and are used (must-be-TRUE)
> - `server.dart` ≤800 LOC
> - `dart test packages/dartclaw_server` passes with zero test changes
> - `constructor_param_count_test.dart` (S10) passes for this file (without allowlist)

### From `.technical-research.md` — "Shared Decision #27" (and binding constraints)
<!-- source: ../.technical-research.md#shared-decisions-canonical-types--protocols -->
<!-- extracted: e670c47 -->
> **27. `DartclawServer` 6 dep-group structs (S18)** — `_ServerCoreDeps`, `_ServerTurnDeps`, `_ServerChannelDeps`, `_ServerTaskDeps`, `_ServerObservabilityDeps`, `_ServerWebDeps` (names finalised at FIS time). `compose()` removed; `DartclawServerBuilder` is single construction path. `server.dart` ≤800 LOC.
>
> #1 (Out of Scope / NFR Compatibility): "JSONL control protocol, REST API payload shapes, SSE envelope formats unchanged." — Applies to S18.
> #2 (Constraint): "No new dependencies in any package. Fitness functions use existing `test` + `analyzer` + `package_config`." — Applies to S18.
> #28 (FR4): "`DartclawServer` ctor takes 6 dep-group structs, not 60+ scalars; `compose()` removed." — Applies to S18.
> #29 (FR4): "`max_file_loc_test.dart` and `constructor_param_count_test.dart` fitness functions pass." — Applies to S10, S15, S16, S18.
> #71 (NFR Reliability): "Behavioural regressions post-decomposition: Zero — every existing test remains green." — Applies to S18 et al.
> #75 (FR8): "`SidebarDataBuilder` extracted; 6 call sites collapsed." — S24 owns SidebarDataBuilder. **In S18: do NOT pre-empt S24** — leave the inline sidebar wiring alone; only the ctor surface changes here.

### From S10 FIS — "constructor_param_count allowlist"
<!-- source: ./s10-level-1-governance-checks.md#success-criteria -->
<!-- extracted: e670c47 -->
> Allowlist `constructor_param_count.txt` lists `DartclawServer._` (in `packages/dartclaw_server/lib/src/server.dart`) with rationale "S18 dep-group struct refactor" — and only that entry (verify no other public ctor exceeds 12 params).

## Deeper Context

- `packages/dartclaw_server/CLAUDE.md` § "Architecture" / "Key files" — `DartclawServer` + `ServerBuilder` framed as the composition root. Naming the 6 structs `_ServerXxxDeps` keeps them private to `server.dart` (leading underscore) so they don't add public-API surface.
- `packages/dartclaw_server/lib/src/server_builder.dart:47-131` — existing `DartclawServerBuilder` already groups its mutable fields by domain (Required core / Turn management / Optional services / Channels / Runtime / Projects / Workflow / Tasks / Google Chat / Auth / Display params). The 6 dep-group structs mirror these sections (collapsing some adjacent groups; see Architecture Decision below).
- `packages/dartclaw_server/lib/src/server.dart:80-150` — current ~60 final fields on `DartclawServer` map 1:1 to ctor params. The 6 structs become 6 final fields on the class; per-field reads inside route mounts unwrap via `_core.sessions`, `_observability.eventBus`, etc.
- `packages/dartclaw_testing/test/fitness/constructor_param_count_test.dart` — S10 ships this with `DartclawServer._` on the allowlist. Drop the entry from `packages/dartclaw_testing/test/fitness/allowlist/constructor_param_count.txt` in this story.
- `apps/dartclaw_cli/lib/src/commands/service_wiring.dart` — sole external caller of `DartclawServerBuilder.build()`; never references `DartclawServer.compose()` or `DartclawServer._` directly. Confirms the builder is already the de-facto sole construction path; this story closes the loophole by deleting `compose()`.

## Success Criteria (Must Be TRUE)

> Each criterion has a proof path: a Scenario (S-n) or task Verify line (TI-n).

- [ ] `DartclawServer._` constructor takes **≤6 positional or named parameters**, each typed as one of the new dep-group structs (no scalar required fields remain on the ctor signature). **Proof**: TI03, S-Happy.
- [ ] `DartclawServer.compose(...)` static factory is **deleted** from `packages/dartclaw_server/lib/src/server.dart`; no production or test code references it (`rg "DartclawServer\.compose"` returns zero hits). **Proof**: TI05, S-SingleConstructionPath.
- [ ] Six private dep-group struct classes exist in `packages/dartclaw_server/lib/src/server.dart` (or a sibling `server_deps.dart` if extracted to keep `server.dart` ≤800 LOC), with the names finalised from Shared Decision #27's suggestions: `_ServerCoreDeps`, `_ServerTurnDeps`, `_ServerChannelDeps`, `_ServerTaskDeps`, `_ServerObservabilityDeps`, `_ServerWebDeps`. **Proof**: TI02.
- [ ] Every original `DartclawServer._` ctor param appears as a `final` field on exactly one of the six structs (no field dropped, no field duplicated across structs). **Proof**: TI02, TI03 mapping audit.
- [ ] `DartclawServerBuilder.build()` constructs the 6 dep-group struct instances and passes them to `DartclawServer._(...)`; no other code path constructs a `DartclawServer`. **Proof**: TI04, S-SingleConstructionPath.
- [ ] `packages/dartclaw_server/lib/src/server.dart` is **≤800 LOC** (down from 1,115 at `e670c47`). If the dep-group struct definitions push the file back up, extract them to `packages/dartclaw_server/lib/src/server_deps.dart` and re-import privately. **Proof**: TI07.
- [ ] `dart test packages/dartclaw_server` passes with **zero test changes** (no test source file under `packages/dartclaw_server/test/` is modified by this story). **Proof**: TI08, S-Happy.
- [ ] `dart analyze --fatal-warnings --fatal-infos` workspace-wide is clean. **Proof**: TI08.
- [ ] `dart test packages/dartclaw_testing/test/fitness/constructor_param_count_test.dart` passes **with the `DartclawServer._` line deleted** from `packages/dartclaw_testing/test/fitness/allowlist/constructor_param_count.txt`. **Proof**: TI06, S-FitnessGreen.
- [ ] `dart format --set-exit-if-changed packages/dartclaw_server` exits 0. **Proof**: TI08.

### Health Metrics (Must NOT Regress)
- [ ] All existing `dartclaw_server` route, turn-lifecycle, task-runtime, SSE, and webhook tests continue to pass without behavioural changes.
- [ ] `DartclawServerBuilder` public API surface is **unchanged** — same field names, same `build()` / `buildTurns()` signatures (a CLI build of `apps/dartclaw_cli` succeeds without source edits to `service_wiring.dart`).
- [ ] No new package added to `packages/dartclaw_server/pubspec.yaml` (PRD Constraint #2).
- [ ] No JSONL/REST/SSE wire-format change (Constraint #1).
- [ ] No public-API symbol added or removed in `package:dartclaw_server/dartclaw_server.dart` barrel (the 6 structs are leading-underscore private).

## Scenarios

### S-Happy: Server boots and serves identical traffic post-refactor
- **Given** the workspace at HEAD with S18 applied — `DartclawServer.compose` removed, `DartclawServer._` taking 6 dep-group structs, `DartclawServerBuilder.build()` constructing those structs internally
- **When** `apps/dartclaw_cli` runs `dartclaw serve --port 0` against an example config (e.g. `examples/dev.yaml`) and an integration suite hits `/health`, a session message round-trip, a workflow-run SSE stream, and a webhook POST
- **Then** every response payload, header, and SSE envelope is byte-equivalent to the pre-refactor baseline (`e670c47`); `dart test packages/dartclaw_server` is green with no test source edits; `dart test packages/dartclaw_server -t integration` is green.

### S-SingleConstructionPath: `compose()` deletion forces builder use
- **Given** S18 has landed and `DartclawServer.compose` is removed
- **When** a contributor naively writes `DartclawServer.compose(sessions: …, …)` in new code
- **Then** the compiler reports `The method 'compose' isn't defined for the type 'DartclawServer'`; the contributor must instead `DartclawServerBuilder()..sessions = …..build()`. `rg "DartclawServer\.compose" packages apps` returns no matches.

### S-FitnessGreen: Allowlist entry can be dropped
- **Given** S10's `constructor_param_count_test.dart` allowlist file at `packages/dartclaw_testing/test/fitness/allowlist/constructor_param_count.txt` contains exactly one effective line: `packages/dartclaw_server/lib/src/server.dart::DartclawServer._  # S18 dep-group struct refactor`
- **When** S18 lands and that single line is deleted from the allowlist file
- **Then** `dart test packages/dartclaw_testing/test/fitness/constructor_param_count_test.dart` passes; the allowlist file's only remaining lines are blank/comment lines (or the file is deleted entirely if empty).

### S-FutureContributor: New dep falls into an existing struct, not a new ctor scalar
- **Given** S18 has landed and a future story adds a new optional service `MyNewMetricsCollector` to the server
- **When** the contributor adds it
- **Then** they declare a field on the matching dep-group struct (e.g. `_ServerObservabilityDeps.myNewMetricsCollector`) and a setter on `DartclawServerBuilder`; the `DartclawServer._` ctor signature stays at 6 params; `constructor_param_count_test.dart` stays green without any allowlist entry. (Captured here as a contract scenario; verified the next time a dep is added.)

### S-Edge-StructExtraction: `server_deps.dart` sibling file if needed
- **Given** authoring the 6 struct classes inline pushes `server.dart` back over 800 LOC
- **When** TI07 measurement shows the inline placement violates the LOC ceiling
- **Then** extract the 6 structs to `packages/dartclaw_server/lib/src/server_deps.dart` (still using leading-underscore class names so they remain library-private to `server.dart` only via a `part`/`part of` directive, **OR** rename them to `_ServerCoreDeps`-style with the leading underscore preserved by keeping them in the same library via `part` — pick whichever the executor confirms compiles cleanly under strict-casts; record the choice in an Implementation Observation).

## Scope & Boundaries

### In Scope
- `packages/dartclaw_server/lib/src/server.dart` — ctor refactor; field unwrapping at every route-mount and helper call site; `compose()` deletion.
- `packages/dartclaw_server/lib/src/server_builder.dart` — `build()` constructs 6 structs and passes them to `DartclawServer._`. Public field surface (the mutable setters contributors use) unchanged.
- (Optional) new file `packages/dartclaw_server/lib/src/server_deps.dart` — only if needed to keep `server.dart` ≤800 LOC; if added, it is a `part of 'server.dart';` library part (not a separate library) so the underscore-prefixed names stay library-private to `server.dart`.
- `packages/dartclaw_testing/test/fitness/allowlist/constructor_param_count.txt` — drop the `DartclawServer._` entry.

### What We're NOT Doing
- **NOT** refactoring `DartclawServerBuilder`'s public field surface — preserve every named setter so `apps/dartclaw_cli/lib/src/commands/service_wiring.dart` keeps compiling unchanged.
- **NOT** changing route paths, request/response payloads, SSE envelopes, JSONL framing, or auth/middleware ordering (Constraint #1).
- **NOT** renaming `DartclawServer` itself or its dependency types — only the ctor signature and field-grouping change.
- **NOT** touching the server-side `ServiceWiring` decomposition (`SecurityWiring`/`ChannelWiring`/`TaskWiring`/`SchedulingWiring`/`StorageWiring`) — that pattern shipped in 0.12 and is independent.
- **NOT** extracting `SidebarDataBuilder` or collapsing the 6 sidebar call sites — that's S24's scope (binding constraint #75).
- **NOT** adding any new dependency to any pubspec (Constraint #2).
- **NOT** changing public exports in `package:dartclaw_server/dartclaw_server.dart`.

## Architecture Decision

We will **collapse `DartclawServer.compose()` into `DartclawServerBuilder`** (single construction path) and **group the ~60 scalar required fields into 6 dep-group structs** that mirror the existing `DartclawServerBuilder` sections. Final struct names finalised at FIS-execution time per the suggested set:

- `_ServerCoreDeps` — sessions, messages, worker, staticDir, authEnabled, gatewayToken, runtimeConfig, config, configWriter, configNotifier, kvService, restartService, healthService, tokenService, resetService, redactor, guardChain, webhookSecret.
- `_ServerTurnDeps` — turns, pool. (Behavior, lockManager, contextMonitor, explorationSummarizer, selfImprovement, usageTracker stay on the *builder* — they're inputs to `buildTurns()` not fields of `DartclawServer`.)
- `_ServerChannelDeps` — channelManager, whatsAppChannel, signalChannel, googleChatWebhookHandler, spaceEventsWiring, threadBindingStore.
- `_ServerTaskDeps` — projectService, goalService, taskService, taskReviewService, worktreeManager, taskFileGuard, agentObserver, mergeExecutor, mergeStrategy, baseRef, traceService, taskEventService, taskEventRecorder, progressTracker.
- `_ServerObservabilityDeps` — eventBus, sseBroadcast, providerStatus, memoryFile, memoryStatusService, memoryPruner, heartbeat, scheduleService, gitSync.
- `_ServerWebDeps` — canvasService, workflowService, workflowDefinitionSource, skillRegistry, contentGuardDisplay, heartbeatDisplay, schedulingDisplay, workspaceDisplay, appDisplay.

The exact partitioning above is the **defensible default** but is finalised by the executor during TI01 mapping — the only hard constraint is **6 structs**, **every field assigned exactly once**, and **the ctor takes ≤6 params**. If field-count balancing or call-site cohesion suggests a small reshuffle (e.g. moving `memoryFile` into `_ServerCoreDeps`), the executor records the deviation as an Implementation Observation. No re-grouping that changes count away from 6 is permitted (binding constraint #28).

**Rationale**: 6 structs match the cardinality the PRD already commits to (#28). The names and groupings mirror the builder's existing sections so a contributor reading both files sees the same mental model. Leading underscores keep the structs library-private — they are not part of the package's public API and don't need barrel exports. `compose()` deletion forecloses the silent second construction path that today lets the builder be bypassed.

## Code Patterns & External References

- `packages/dartclaw_server/lib/src/server.dart:80-275` — current `DartclawServer` field block + `_` ctor (the refactor target). 1,115 LOC at `e670c47`.
- `packages/dartclaw_server/lib/src/server.dart:281-440` — current `DartclawServer.compose(...)` static factory (the deletion target).
- `packages/dartclaw_server/lib/src/server_builder.dart:47-131` — existing builder section comments (`// Required core services`, `// Turn management`, `// Optional services`, `// Channels`, `// Runtime services`, `// Projects`, `// Workflow`, `// Tasks`, `// Google Chat`, `// Auth & gateway`, `// Display params`) — use as the source of truth for which field belongs in which dep-group struct.
- `packages/dartclaw_server/lib/src/server_builder.dart:175-252` — existing `build()` method (already the de-facto single construction path; just needs to construct 6 structs and pass them through after `compose()` is deleted).
- `packages/dartclaw_workflow/lib/src/workflow/workflow_executor.dart` — example of the in-codebase pattern for grouping ctor deps as a private struct (used during 0.16.4 S46 task-executor decomposition; mirror the style — `class _XxxDeps { final … ; const _XxxDeps({required this.…, …}); }`).
- `packages/dartclaw_testing/test/fitness/allowlist/constructor_param_count.txt` — file format (one entry per line, `# rationale` after `#`); per S10 FIS, only `DartclawServer._` is an effective entry — confirm before deletion.

## Tasks

> Order is mandatory; each task is small and independently verifiable. Each `Verify:` line maps to one or more Success Criteria.

1. **TI01 — Map every existing `DartclawServer._` ctor param into one of the 6 dep groups.** Walk the current ctor (lines 158-216 at `e670c47`) and produce an inline mapping table at the top of the FIS execution log: `<paramName> → <_ServerXxxDeps>`. Every param assigned exactly once; no orphans, no duplicates. Any param whose group is non-obvious gets a one-line rationale. **Verify**: mapping table covers all current ctor params (count = pre-refactor param count); each of the 6 groups is non-empty.

2. **TI02 — Author the 6 dep-group struct classes.** In `packages/dartclaw_server/lib/src/server.dart` (or in a `server_deps.dart` library part if file size demands per S-Edge-StructExtraction), declare `class _ServerCoreDeps`, `class _ServerTurnDeps`, `class _ServerChannelDeps`, `class _ServerTaskDeps`, `class _ServerObservabilityDeps`, `class _ServerWebDeps` — each with a `const` constructor taking `required` named params for every field, all fields `final`, types matching the original ctor signature exactly (preserve nullability). **Verify**: `dart analyze packages/dartclaw_server` is clean; the 6 classes exist with the expected field counts (per TI01 mapping).

3. **TI03 — Refactor `DartclawServer._` to take 6 struct params.** Replace the ~60 named scalar params with `required _ServerCoreDeps core`, `required _ServerTurnDeps turn`, `required _ServerChannelDeps channels`, `required _ServerTaskDeps tasks`, `required _ServerObservabilityDeps observability`, `required _ServerWebDeps web`. Convert the 60 `_field = field` initializers to `_core = core, _turn = turn, …` (6 fields total on the class). Update all internal field reads from `_sessions` → `_core.sessions`, `_eventBus` → `_observability.eventBus`, etc. **Verify**: `dart analyze` clean; ctor signature has ≤6 params.

4. **TI04 — Update `DartclawServerBuilder.build()` to construct + pass the 6 structs.** Replace the long `DartclawServer.compose(sessions: …, messages: …, …)` call with construction of the 6 struct instances followed by `DartclawServer._(core: _ServerCoreDeps(…), turn: _ServerTurnDeps(…), …)`. Preserve all existing setter-→-field plumbing on the builder; only the *call site* to construct the server changes. **Verify**: `dart analyze` clean; `apps/dartclaw_cli` builds without source edits.

5. **TI05 — Delete `DartclawServer.compose(...)` static factory.** Remove the entire static method (and its now-redundant doc comment). **Verify**: `rg "DartclawServer\.compose" packages apps` returns zero results; `dart analyze` clean.

6. **TI06 — Drop `DartclawServer._` from S10's constructor_param_count allowlist.** Edit `packages/dartclaw_testing/test/fitness/allowlist/constructor_param_count.txt` and remove the line referencing `DartclawServer._`. If that was the only effective (non-comment, non-blank) line, the file becomes empty (or comment-only). **Verify**: `dart test packages/dartclaw_testing/test/fitness/constructor_param_count_test.dart` passes.

7. **TI07 — Verify `server.dart` ≤800 LOC.** Run `wc -l packages/dartclaw_server/lib/src/server.dart`. If >800, extract the 6 dep-group structs into a `part of` library file `packages/dartclaw_server/lib/src/server_deps.dart` (with `part 'server_deps.dart';` declared in `server.dart`) and re-measure. Record the chosen layout in an Implementation Observation. **Verify**: `wc -l packages/dartclaw_server/lib/src/server.dart` ≤ 800.

8. **TI08 — Workspace-wide test, analyze, and format gate.** Run `dart format --set-exit-if-changed packages/dartclaw_server`, `dart analyze --fatal-warnings --fatal-infos` (workspace), `dart test packages/dartclaw_server` (no test files modified). **Verify**: all three exit 0; `git diff --stat packages/dartclaw_server/test/` shows no modified test source files.

> Estimated tasks: 8. No task introduces a new dependency, channel, route, or schema — the entire story is a constructor-shape refactor.

## Constraints & Gotchas

- **Behaviour change: zero.** Every observable surface (HTTP routes, SSE envelopes, JSONL frames, log formatters, auth middleware ordering) must be byte-equivalent before and after. Any divergence detected by an existing test is a regression — fix the refactor, not the test (PRD constraint #71; "zero test changes" is a Success Criterion, not a guideline).
- **No new deps.** PRD constraint #2 — the refactor must work with what's already in `pubspec.yaml`. The 6 structs are plain Dart classes; no `package:freezed`, no codegen, no `package:meta` `@immutable` (unless already imported — verify before adding).
- **Strict-casts + strict-raw-types stay on.** Constraint #75 — the struct types must spell out generics fully (`Map<String, Object?>`, `List<DartclawEvent>` etc.), no `dynamic` to elide a generic.
- **Builder public surface frozen.** `apps/dartclaw_cli/lib/src/commands/service_wiring.dart` and any other `DartclawServerBuilder()..xxx = …` callers must keep compiling unchanged. The dep-group structs are an *internal* refactor of the builder→server boundary; the builder→caller boundary stays identical.
- **`compose()` is the only second construction path.** A grep at `e670c47` shows `DartclawServer.compose(` referenced only at `server_builder.dart:192` and `server.dart:281,341`. Deleting it is safe. Re-grep before and after TI05 to confirm.
- **Underscore prefix preserves library-private scope.** `_ServerCoreDeps` inside `server.dart` is private to that library. If TI07 forces extraction to `server_deps.dart`, use `part of 'server.dart';` (a library part) — **not** a standalone library — so the underscore continues to mean library-private. A standalone `lib/src/server_deps.dart` library would expose `_ServerCoreDeps` only to `server.dart`'s siblings via the `lib/src/` import, which is fine if there are no other consumers, but the `part of` form keeps the contract crisper.
- **Ctor fields are ALL `final` and `required` (or nullable).** Match the existing ctor's nullability exactly — every `String?`, `MemoryFileService?`, `RestartService?` etc. stays nullable in the dep-group struct. Don't tighten nullability silently; that's a separate concern out of scope here.
- **`SkillRegistry?` is currently the only non-`required` ctor param** (line 211 / 334). Preserve that nuance: in `_ServerWebDeps`, `skillRegistry` is a nullable `final` field; when the builder passes the struct to `_(..., web: _ServerWebDeps(..., skillRegistry: skillRegistry))` the original `null` default still works.
- **Field rename safety.** Internal refs go from `_eventBus` to `_observability.eventBus`. The mechanical `Find&Replace` is the bulk of the diff — let the analyzer catch missed renames; do not rely on grep alone (an `_eventBus` substring inside a string literal must not be touched).
- **`compose()` does extra work after constructing `DartclawServer._`.** Lines 401-440-ish run `computeSidebarFeatureVisibility`, `registerSystemDashboardPages`, etc. — that work needs to move to `DartclawServerBuilder.build()` (post-construction). Verify no caller depended on this work happening *during* construction (it doesn't — these are post-init side effects).

## Verification Gates

- `dart format --set-exit-if-changed packages/dartclaw_server`
- `dart analyze --fatal-warnings --fatal-infos` (workspace-wide)
- `dart test packages/dartclaw_server`
- `dart test packages/dartclaw_testing/test/fitness/constructor_param_count_test.dart`
- `wc -l packages/dartclaw_server/lib/src/server.dart` (≤800)
- `rg "DartclawServer\.compose" packages apps` (zero hits)
- `git diff --stat packages/dartclaw_server/test/` (zero modified test files)

## Reverse Coverage

| Plan AC | FIS Surface |
|---|---|
| `DartclawServer._` constructor takes ≤6 parameters | Success Criterion #1; TI03; S-Happy |
| `compose()` removed; builder is single construction path | Success Criterion #2; TI05; S-SingleConstructionPath |
| 6 dep-group structs exist and are used | Success Criteria #3, #4, #5; TI02, TI04 |
| `server.dart` ≤800 LOC | Success Criterion #6; TI07; S-Edge-StructExtraction |
| `dart test packages/dartclaw_server` passes with zero test changes | Success Criterion #7; TI08; S-Happy |
| `constructor_param_count_test.dart` passes without allowlist | Success Criterion #9; TI06; S-FitnessGreen |

| Binding Constraint | FIS Surface |
|---|---|
| #1 (JSONL/REST/SSE unchanged) | Scope & Boundaries (What We're NOT Doing); Constraints & Gotchas; Health Metrics |
| #2 (no new deps) | Scope & Boundaries; Constraints & Gotchas; Health Metrics |
| #28 (6 dep-group structs, `compose()` removed) | Architecture Decision; Success Criteria #1, #2, #3; TI02-TI05 |
| #29 (max_file_loc + constructor_param_count fitness functions pass) | Success Criteria #6, #9; TI06, TI07 |
| #71 (zero behavioural regression) | Health Metrics; Success Criterion #7; S-Happy; Constraints & Gotchas |
| #75 (SidebarDataBuilder is S24, not S18) | Scope & Boundaries (What We're NOT Doing) |

## Self-Check

- Every Plan AC has a proof path (table above).
- Every binding constraint has a proof path (table above).
- Scenarios cover happy (S-Happy), structural-deletion path (S-SingleConstructionPath), fitness-green path (S-FitnessGreen), future-contributor contract (S-FutureContributor), and one operational edge (S-Edge-StructExtraction).
- Tasks are ordered, mechanical, each verifiable; estimated 8 tasks (within ≤18 budget).
- No new dependency, channel, route, or schema introduced.
- Public-API surface (server barrel, builder field surface, JSONL/REST/SSE wire formats) unchanged.
- Risk classification (Low — constructor-only refactor) consistent with the plan; the only failure mode is missing a field rename, caught by the analyzer + existing test suite.
