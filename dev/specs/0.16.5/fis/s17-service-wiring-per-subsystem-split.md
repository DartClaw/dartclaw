# S17 — service_wiring.dart + cli_workflow_wiring.dart Per-Subsystem Split

**Plan**: ../plan.md
**Story-ID**: S17

## Feature Overview and Goal

Mirror the 0.12 Phase 0 server-side decomposition pattern on the CLI side: split the two CLI god-method `wire()` functions into per-subsystem private methods backed by a small context struct. Primary target is `apps/dartclaw_cli/lib/src/commands/service_wiring.dart` (1,415 LOC; `wire()` ~678 LOC); secondary is `apps/dartclaw_cli/lib/src/commands/workflow/cli_workflow_wiring.dart` (945 LOC; `wire()` ~700 LOC). Mechanical refactor — zero behaviour change, no protocol change, no new dependencies. **Not in scope**: the server-side `packages/dartclaw_server/lib/src/service_wiring.dart` (already decomposed in 0.12 Phase 0 — `StorageWiring`/`SecurityWiring`/`HarnessWiring`/`ChannelWiring`/`TaskWiring`/`SchedulingWiring`/`ProjectWiring` files already exist under `apps/dartclaw_cli/lib/src/commands/wiring/` and are imported and used by the CLI `ServiceWiring` thin coordinator already; this story tightens the coordinator and the standalone workflow wiring twin).

> **Technical Research**: [.technical-research.md](../.technical-research.md) _(see "S17 — service_wiring.dart + cli_workflow_wiring.dart Per-Subsystem Split"; Shared Decision #26 — `WiringContext` / `CliWorkflowWiringContext` structs)_

## Required Context

### From `prd.md` — "FR4: Structural Decomposition of Remaining Hotspots"
<!-- source: ../prd.md#fr4-structural-decomposition-of-remaining-hotspots -->
<!-- extracted: e670c47 -->
> **Description**: The post-0.16.4 baseline already split `workflow_executor.dart` and `task_executor.dart`; this sprint now shrinks the remaining over-threshold/configuration and execution hotspots along their natural ownership boundaries. … the CLI's `service_wiring.dart#wire()` (678-line method) splits per subsystem, and the server's composition root collapses `compose()` into the builder with grouped dep structs.
>
> **S17-applicable Acceptance Criteria** (verbatim):
> - `service_wiring.dart#wire()` (in `apps/dartclaw_cli/`) split into per-subsystem `_wireXxx()` methods with a `WiringContext` struct
> - `max_file_loc_test.dart` and `constructor_param_count_test.dart` fitness functions pass

### From `plan.md` — "[P] S17: service_wiring.dart + cli_workflow_wiring.dart Per-Subsystem Split"
<!-- source: ../plan.md#p-s17-service_wiring.dart--cli_workflow_wiring.dart-per-subsystem-split -->
<!-- extracted: e670c47 -->
> **Risk**: Low — mechanical refactor, no behaviour change
>
> **Scope**: Two sibling god-method splits. **Primary target**: CLI-side wiring at `apps/dartclaw_cli/lib/src/commands/service_wiring.dart` (1,415 LOC total as of 2026-05-04, grew from 1,235; `wire()` method still ~678 LOC) — NOT the server-side `ServiceWiring` that was already decomposed in 0.12 Phase 0 into `SecurityWiring`/`ChannelWiring`/`TaskWiring`/`SchedulingWiring`/`StorageWiring`. This story mirrors that 0.12 pattern for the CLI: split `wire()` into per-subsystem private methods. Based on the file's own numbered comment sections: `_wireStorage`, `_wireSecurity`, `_wireHarness`, `_wireChannels`, `_wireTasks`, `_wireScheduling`, `_wireObservability`, `_wireWebUi`, etc. Introduce a small `WiringContext` struct (or similar) for cross-cutting deps (eventBus, configNotifier, dataDir) rather than ambient closure capture. Target: `service_wiring.dart` ≤800 LOC, `wire()` ≤100 LOC.
>
> **Secondary target**: `apps/dartclaw_cli/lib/src/commands/workflow/cli_workflow_wiring.dart` is now 945 LOC total, `wire()` ~700 LOC. Same numbered-section structure (storage → task layer → harness → behaviour → artifact collector → workflow service → task executor). Apply the same treatment: per-section `_wireXxx()` methods, `CliWorkflowWiringContext` struct, target `cli_workflow_wiring.dart` ≤600 LOC.
>
> **Acceptance Criteria** (verbatim):
> - `service_wiring.dart#wire()` ≤100 LOC (must-be-TRUE)
> - `service_wiring.dart` total ≤800 LOC (must-be-TRUE)
> - `cli_workflow_wiring.dart#wire()` ≤100 LOC (must-be-TRUE)
> - `cli_workflow_wiring.dart` total ≤600 LOC (must-be-TRUE)
> - `WiringContext` / `CliWorkflowWiringContext` (or equivalents) encapsulate cross-cutting deps (must-be-TRUE)
> - `dart test apps/dartclaw_cli` passes; `dart run dartclaw_cli:dartclaw serve --port 3333` starts and serves identical endpoints
> - `dartclaw workflow run` standalone path works identically before/after (regression guard for CLI wiring)
> - `server_builder_integration_test.dart` (which imports `service_wiring.dart` via `src/`) still passes

### From `.technical-research.md` — Shared Decision #26
<!-- source: ../.technical-research.md#shared-decisions-and-conventions -->
<!-- extracted: e670c47 -->
> **26. `WiringContext` / `CliWorkflowWiringContext` structs (S17)** — encapsulate cross-cutting deps (`eventBus`, `configNotifier`, `dataDir`) for CLI-side `service_wiring.dart` (≤800 LOC, `wire()` ≤100) and `cli_workflow_wiring.dart` (≤600 LOC, `wire()` ≤100). Per-subsystem `_wireXxx()` private methods.

### From `.technical-research.md` — "Binding PRD Constraints" (S17-applicable)
<!-- source: ../.technical-research.md#binding-prd-constraints -->
<!-- extracted: e670c47 -->
> #1 (Out of Scope / NFR Compatibility): "JSONL control protocol, REST API payload shapes, SSE envelope formats unchanged." — S17.
> #2 (Constraint): "No new dependencies in any package." — S17 adds none.
> #27 (FR4): "`service_wiring.dart#wire()` (CLI-side) split into per-subsystem `_wireXxx()` methods with a `WiringContext` struct." — S17.
> #71 (NFR Reliability): "Behavioural regressions post-decomposition: Zero — every existing test remains green." — S17.

### From `prd.md` — "Constraints" (workspace lint)
<!-- source: ../prd.md#constraints -->
<!-- extracted: e670c47 -->
> Workspace-wide strict-casts + strict-raw-types must remain on throughout.

## Deeper Context

- `apps/dartclaw_cli/CLAUDE.md` § "Boundaries" / "Conventions" — registration-only `bin/dartclaw.dart`, all command code under `lib/src/commands/`, AOT-safety (no `dart:mirrors`/reflection), tests drive commands through `DartclawRunner.run([...])` with constructor-injected fakes; new wiring split-out tests live under `test/commands/wiring/` matching `lib/src/commands/wiring/`.
- `apps/dartclaw_cli/lib/src/commands/wiring/` — pre-existing per-subsystem wiring helper files (`storage_wiring.dart`, `security_wiring.dart`, `harness_wiring.dart`, `channel_wiring.dart`, `task_wiring.dart`, `scheduling_wiring.dart`, `project_wiring.dart`). The current `ServiceWiring` already delegates construction to these; what remains in `wire()` is the cross-cutting glue (eventBus creation, restart-pending sniff, `DartclawServerBuilder` field assignments, post-server hooks, registry materialization, MCP tool registration, alert routing, group-session init, return assembly). Glue is what S17 must split.
- `dev/state/STATE.md` § Active milestone — references this sprint's structural-decomposition wave; Block E parallel-friendly.
- `dev/specs/0.16.5/fis/s18-...` (peer story) — `DartclawServer` dep-group struct collapse, runs in parallel; do not collide on `server.dart`.
- `apps/dartclaw_cli/test/e2e/server_builder_integration_test.dart:7` — direct importer of `package:dartclaw_cli/src/commands/service_wiring.dart`; constructs `ServiceWiring` and asserts the `WiringResult` it returns. Public surface (`ServiceWiring(...)` constructor named params, `wire()` signature, `WiringResult` field set) MUST stay identical.
- `dev/guidelines/DART-EFFECTIVE-GUIDELINES.md` § Proportionality & Anti-Rot — comment policy: rationale only, never narration; numbered-section comments existing in `wire()` today get hoisted into method names rather than re-narrated inside the new methods.

## Success Criteria (Must Be TRUE)

> Each criterion has a proof path: a Scenario (S-n) or task Verify line (TI-n).

- [ ] `apps/dartclaw_cli/lib/src/commands/service_wiring.dart`: `ServiceWiring.wire()` body is ≤100 LOC (counting from method signature `Future<WiringResult> wire() async {` to its closing `}`, exclusive of trailing blank lines). **Proof**: TI03, TI04 Verify; S-Happy-Serve.
- [ ] `apps/dartclaw_cli/lib/src/commands/service_wiring.dart` total ≤800 LOC (file LOC, including imports, doc comments, `WiringResult`, `ServiceWiring`, `_dropLegacySessionCostEntries`, `_configureBudgetWarningNotifiers`, `_configureLoopDetectionNotifiers`, the new `WiringContext` and `_wireXxx` methods, and `teardown`). **Proof**: TI04 Verify.
- [ ] `apps/dartclaw_cli/lib/src/commands/workflow/cli_workflow_wiring.dart`: `CliWorkflowWiring.wire()` body is ≤100 LOC. **Proof**: TI07 Verify; S-Happy-Workflow-Run.
- [ ] `apps/dartclaw_cli/lib/src/commands/workflow/cli_workflow_wiring.dart` total ≤600 LOC. **Proof**: TI08 Verify.
- [ ] A `WiringContext` value type (private `class _WiringContext` or `final class WiringContext`, or a record alias) lives in or alongside `service_wiring.dart` and carries — at minimum — `eventBus`, `configNotifier`, `dataDir`, plus any cross-section refs the split surfaces (e.g. `assetResolver`, `resolvedAssets`, `skillRegistry`, `serverRefGetter`). It is the parameter passed between `_wireXxx` methods rather than ambient closure capture. **Proof**: TI01, TI03; S-NewSubsystemPattern.
- [ ] A `CliWorkflowWiringContext` value type lives in or alongside `cli_workflow_wiring.dart` with the equivalent role (eventBus, dataDir, environment, runtimeCwd, credentialRegistry, harnessConfig, skillRegistry, etc.). **Proof**: TI05, TI07; S-NewSubsystemPattern.
- [ ] `dart test apps/dartclaw_cli` (default tags, integration tag NOT included) passes with zero test edits beyond mechanical-import or symbol-rename adjustments. **Proof**: TI09 Verify; S-Happy-Serve, S-Happy-Workflow-Run.
- [ ] `dart run dartclaw_cli:dartclaw serve --port 3333` starts cleanly against a known config and the printed startup banner + the listed REST/SSE endpoints + `/health` payload + MCP tool list match the pre-refactor baseline byte-for-byte (or with whitespace-only diff). **Proof**: TI10; S-Happy-Serve.
- [ ] `dartclaw workflow run <built-in workflow> --standalone` against a fixture project produces the same artifacts, the same workflow-run-ID format, the same exit code, and the same task-event sequence as the pre-refactor baseline. **Proof**: TI10; S-Happy-Workflow-Run.
- [ ] `dart test --run-skipped -t integration apps/dartclaw_cli/test/e2e/server_builder_integration_test.dart` passes — the test imports `service_wiring.dart` from `lib/src/` and asserts on `WiringResult`. **Proof**: TI11 Verify.

### Health Metrics (Must NOT Regress)

- [ ] Public surface unchanged: `class WiringResult` field set; `class ServiceWiring` ctor named params; `ServiceWiring.wire()` return type; `class CliWorkflowWiring` ctor named params; `CliWorkflowWiring.wire()` return type; `CliWorkflowWiring.dispose()`. **Proof**: TI12.
- [ ] Workspace-wide `dart analyze --fatal-warnings --fatal-infos` clean (no new warnings/infos). Strict-casts + strict-raw-types unchanged. **Proof**: TI09.
- [ ] `dart format` clean on the two changed files. **Proof**: TI09.
- [ ] No new `package:` dependency added to `apps/dartclaw_cli/pubspec.yaml`. **Proof**: TI09 Verify.
- [ ] JSONL/REST/SSE protocol surfaces unchanged (Constraint #1).
- [ ] Server-side `packages/dartclaw_server/lib/src/service_wiring.dart` is NOT modified by this story.

## Scenarios

### S-Happy-Serve — `dartclaw serve` end-to-end matches pre-refactor baseline
- **Given** a valid `dartclaw.yaml` (e.g. `examples/dev.yaml`) and a writable data dir
- **When** the operator runs `dart run dartclaw_cli:dartclaw serve --port 3333`
- **Then** the server starts; the startup banner is identical to the pre-refactor capture; `GET /health` returns the same JSON shape; the SSE endpoint streams a `connected` envelope with the same fields; `GET /v1/sessions` and `GET /tasks` respond with the same status codes and payload shape; the registered MCP tool list includes `sessions_send`, `sessions_spawn`, `memory_save`, `memory_search`, `memory_read`, `web_fetch`, plus any conditionally enabled tools (canvas, brave/tavily search) gated by config — same gating as before.

### S-Happy-Workflow-Run — `dartclaw workflow run --standalone` reproduces baseline behaviour
- **Given** a fixture project, the built-in `code-review` workflow, a fake harness, and identical config + environment
- **When** the operator runs `dartclaw workflow run code-review --standalone --project <id>`
- **Then** `CliWorkflowWiring.wire()` provisions skills via `bootstrapAndthenSkills`, opens search + task DBs, materializes built-in workflows, registers the workflow, executes it, and emits the same task-event sequence and the same exit code as the pre-refactor baseline; the same `publish.pr_url` contract holds (empty when no PR creator is injected); `dispose()` tears down in reverse order without errors.

### S-NewSubsystemPattern — Future contributor adds a new subsystem
- **Given** an engineer needs to wire a new subsystem (e.g. a hypothetical `BillingService`) into `ServiceWiring`
- **When** they read `service_wiring.dart`
- **Then** they discover the established pattern: declare deps on `_WiringContext` (or extend it), add a `Future<_BillingWiring> _wireBilling(_WiringContext ctx)` private method that returns a small named-deps struct, and append a single `await _wireBilling(ctx)` call in `wire()`'s ≤100-LOC dispatcher block — without needing to add a new top-level helper file, refactor neighbours, or thread new closure captures.

### S-NoBehaviourChange-EmergencyPaths — Channel notification + alert routing unchanged
- **Given** a session crosses the budget warning threshold OR a loop is detected OR an `AlertRouter`-routed sealed event fires during a `serve` session
- **When** the budget/loop/alert path runs through `_configureBudgetWarningNotifiers`, `_configureLoopDetectionNotifiers`, or `AlertRouter`
- **Then** the channel notification is delivered identically (same template, same recipient resolution via `_resolveChannelRoute`, same redaction); the `lookupAlertChannel` closure resolves alert channels by `type.name` exactly as before; refactor introduces no extra round-trip or message duplication. Existing tests under `apps/dartclaw_cli/test/commands/` for these paths pass without changes.

### S-NoBehaviourChange-Restart — Restart-pending sentinel still consumed
- **Given** a `restart.pending` file exists in `dataDir` from a prior graceful restart
- **When** `wire()` runs
- **Then** the file is parsed, the message `Restarted after config change (pending: …)` is written via `stderrLine`, and the file is deleted — exactly once, in the same `_wireXxx` method (or shared restart-init helper), regardless of which other subsystems wire successfully or fail subsequently.

### S-Skip-AndthenBootstrap — `runAndthenSkillsBootstrap = false` still skips network
- **Given** `ServiceWiring(runAndthenSkillsBootstrap: false, …)` constructed by a test
- **When** `wire()` runs
- **Then** `bootstrapAndthenSkills(...)` is NOT invoked (no clone, no network call, no `~/.agents` mutation), and the surrounding subsystems still wire correctly using the user-supplied `skillProvisionerEnvironment` for skill-root resolution. Same gate semantics for `CliWorkflowWiring`.

## Scope & Boundaries

### In Scope
_Every scope item is covered by at least one scenario or task with a Verify line._
- Refactor `apps/dartclaw_cli/lib/src/commands/service_wiring.dart` `ServiceWiring.wire()` into a ≤100-LOC dispatcher that calls per-subsystem private methods (`_wireStorage`, `_wireSecurity`, `_wireHarness`, `_wireChannels`, `_wireTasks` (pre+post split where the existing `wirePreServer`/`wirePostServer` boundary already exists in `TaskWiring`), `_wireScheduling`, `_wireObservability`, `_wireWebUi` / MCP-tool-registration, plus the cross-cutting `_wireRestartSentinel`, `_wireWorkflowRegistry`, `_wireAlertRouting`, `_wireGroupSessionInit`, `_assembleWiringResult`). Exact method names finalised during implementation against the in-file numbered sections.
- Introduce a `_WiringContext` value type (private to the file unless a test seam needs it) carrying cross-cutting deps and lazily-resolvable getters (`serverRefGetter`, `turnManagerGetter`).
- Refactor `apps/dartclaw_cli/lib/src/commands/workflow/cli_workflow_wiring.dart` `CliWorkflowWiring.wire()` into a ≤100-LOC dispatcher with per-section private methods (`_wireSkillRegistry`, `_wireStorage`, `_wireTaskLayer`, `_wireHarness`, `_wireBehaviour`, `_wireRunnerPool`, `_wireArtifactCollector`, `_wireWorkflowService`, `_wireTaskExecutor`, `_wireWorkflowRegistry`).
- Introduce a `_CliWorkflowWiringContext` (or similarly named) value type for cross-cutting deps. Expand the existing `late final` field set onto the context where it is conceptually internal-to-`wire()`-only; keep public-API `late final` fields unchanged.
- Mechanical comment-policy cleanup on the two files: numbered-section comments inside `wire()` are deleted (their content is now the method name); rationale comments survive.

### What We're NOT Doing
- **Not refactoring** `packages/dartclaw_server/lib/src/service_wiring.dart` — already decomposed in 0.12 Phase 0; out of scope by binding-decision-explicit. Touching it risks colliding with S18 on `server.dart`.
- **Not refactoring** the per-subsystem helper files under `apps/dartclaw_cli/lib/src/commands/wiring/` (`storage_wiring.dart`, etc.) — they are already focused. This story only restructures their callers.
- **Not changing** the public surface of `WiringResult`, `ServiceWiring(...)` ctor, `CliWorkflowWiring(...)` ctor, or any field name read by tests / `serve_command.dart` — preserving call-site compatibility.
- **Not introducing** a dependency-injection framework (`get_it`, `riverpod`, etc.) — would violate Constraint #2 (no new deps) and Project Philosophy (lean deps, no reflection).
- **Not changing** any endpoint route, SSE envelope, MCP tool registration order in a user-observable way, or any CLI command surface — would violate Constraint #1.

### Agent Decision Authority
- **Autonomous**:
  - Final method-name list (e.g. whether `_wireWorkflowRegistry` and `_wireWorkflowService` collapse into one or stay split) — choose what keeps `wire()` ≤100 LOC and each `_wireXxx` method cohesive.
  - Whether `_WiringContext` is a `final class`, a `record`, or a private `class _WiringContext` — pick the lowest-ceremony variant that compiles cleanly with strict-casts/raw-types.
  - Whether to extract a tiny named-deps return type per `_wireXxx` (e.g. `_StorageHandles`, `_HarnessHandles`) when the caller needs ≥3 handles back, vs. assigning into the context. Prefer named records or small private final classes — no `Map<String, Object>` shotguns.
  - Whether the two big inline closures inside `WorkflowTurnAdapter(...)` (the `resolveStartContext`, `bootstrapWorkflowGit`, `promoteWorkflowBranch`, `publishWorkflowBranch`, `cleanupWorkflowGit`, `cleanupWorktreeForRetry`, `captureWorkflowBranchSha`, `captureAndCleanWorktreeForRetry`, `runResolverAttemptUnderLock` blocks) are extracted into separate `_buildXxxAdapter()` private builder methods. **Strongly recommended yes** — these are ~200 LOC each and dominate the current `wire()` budget. If extracting, keep behaviour byte-identical; do not refactor inside the closures.
- **Escalate** (stop with `BLOCKED:` and ask):
  - Any case where a `late final` field on `CliWorkflowWiring` is read by an external caller you cannot match to the current public surface — surfaces would be unsafe to move.
  - Any test failure that cannot be traced to a renamed symbol or a missed import — likely indicates a real behaviour regression.

## Architecture Decision

**We will**: Mirror the existing 0.12 Phase 0 server-side split pattern (`SecurityWiring`/`ChannelWiring`/`TaskWiring`/`SchedulingWiring`/`StorageWiring`) on the CLI side: per-subsystem private `_wireXxx()` methods on the existing `ServiceWiring` and `CliWorkflowWiring` classes, named per the numbered comment sections that already exist in each file's `wire()` body, with a `_WiringContext` / `_CliWorkflowWiringContext` value type for cross-cutting deps (`eventBus`, `configNotifier`/`runtimeCwd`/`environment`, `dataDir`, `assetResolver`, `skillRegistry`, lazy server/turn getters) instead of ambient closure capture.

**Rationale**: (a) The pattern is already proven in this codebase (0.12 Phase 0). (b) The per-subsystem helper files under `commands/wiring/` already exist; the story is mechanical glue-tightening, not a new architecture. (c) An explicit context struct localises what is currently implicit closure capture across an 800-LOC method, which is the actual readability problem. (d) A struct-with-named-fields is strictly less ceremony than a DI container and respects Constraint #2 (no new deps).

**Alternatives considered**:
1. **New per-subsystem files mirroring `commands/wiring/`** for `cli_workflow_wiring.dart` (e.g. `commands/workflow/wiring/workflow_storage_wiring.dart`, etc.) — rejected: would dilute the value of `cli_workflow_wiring.dart` as the single composition root for standalone runs and roughly doubles file count for no observable gain. Per-section private methods on the existing class deliver the same readability win at lower disruption and keep the tests under `test/commands/workflow/` aligned to one wiring entry.
2. **Pass each subsystem its own narrow record** of just the deps it needs (no shared context) — rejected: the current `wire()` body shows ~6 cross-cutting handles that flow through ≥4 subsystems each (`eventBus`, `configNotifier`, `dataDir`, `harness.pool`, `serverRef`-getter, `turns`-getter). A shared context is cheaper than ≥4 narrow records.
3. **Introduce a DI container (`get_it` / `kiwi`)** — rejected: violates Constraint #2 and the project's lean-deps philosophy; is reflective in some impls (AOT-hostile).

## Technical Overview

### Data Models

- `_WiringContext` (private to `service_wiring.dart`): immutable named-deps holder. Fields (final): `eventBus`, `configNotifier`, `dataDir`, `port`, `assetResolver`, `resolvedAssets`, `builtInSkillsSourceDir`, `skillRegistry`, `messageRedactor`, `serverRefGetter` (`DartclawServer Function()`), `turnManagerGetter` (`TurnManager Function()`). Constructed once at the top of `wire()`. Late getters wired via setter pattern (`setServerRef(server)`, `setTurns(turns)`) to remain compatible with the existing late-binding closures.
- `_CliWorkflowWiringContext` (private to `cli_workflow_wiring.dart`): immutable named-deps holder. Fields (final): `eventBus`, `dataDir`, `runtimeCwd`, `environment`, `assetResolver`, `builtInSkillsSourceDir`, `credentialRegistry`, `harnessConfig`, `roleDefaults`, `skillRegistry`. The existing `late final` instance fields on `CliWorkflowWiring` (e.g. `pool`, `taskService`, `workflowService`) remain — they are public-style accessors used by `dispose()` and by external callers / tests. Internal-only handles (e.g. `taskRepository`, `agentExecutionRepository`, `taskEventRecorder`, `primaryRunner`, `taskRunners`) move from local `wire()` variables onto the context or onto small `_wireXxx`-return records.
- Optional small `_StorageHandles`, `_TaskLayerHandles`, `_HarnessHandles`, `_WorkflowAdapterClosures` records — private named records, used only when a `_wireXxx` returns ≥3 handles. Avoid for single-return cases.

### Integration Points

- `serve_command.dart` constructs `ServiceWiring(...)` with named params and calls `await wiring.wire()`; it reads `WiringResult` fields. Untouched.
- `apps/dartclaw_cli/test/e2e/server_builder_integration_test.dart:7` imports `package:dartclaw_cli/src/commands/service_wiring.dart` and constructs `ServiceWiring(...)`. Same call site stays valid.
- `WorkflowCommand` (and child commands) constructs `CliWorkflowWiring(...)` for `--standalone` runs. Same construction surface preserved.
- Existing `apps/dartclaw_cli/test/commands/wiring/*_test.dart` tests target individual `XxxWiring` modules — untouched by this story.

## Code Patterns & External References

```
# type | path/url | why needed
file   | apps/dartclaw_cli/lib/src/commands/wiring/storage_wiring.dart      | Reference: per-subsystem `class XxxWiring` with `wire()` returning when done; mirror its "dataclass-with-method" shape inside `_wireXxx` methods (without creating new files).
file   | apps/dartclaw_cli/lib/src/commands/wiring/security_wiring.dart     | Reference: per-subsystem named-deps surface (`agentDefs:` pass-through), late getters for cross-cutting refs.
file   | apps/dartclaw_cli/lib/src/commands/wiring/harness_wiring.dart      | Reference: late `serverRefGetter` pattern — same lazy-binding seam to preserve.
file   | apps/dartclaw_cli/lib/src/commands/service_wiring.dart:173-936     | TARGET: existing `wire()` body; the numbered comments (`// 0.`, `// 0.5.`, `// 1.`, … `// 8.`) are the section boundaries that map onto `_wireXxx` method names.
file   | apps/dartclaw_cli/lib/src/commands/service_wiring.dart:354-399     | TARGET: `DartclawServerBuilder` first batch of field assignments (pre-server build) — extract into `_wireServerBuilderPreServer` (or fold into `_assembleServer`).
file   | apps/dartclaw_cli/lib/src/commands/service_wiring.dart:765-797     | TARGET: `DartclawServerBuilder` second batch (post-server-deps) — extract into `_wireServerBuilderPostServer` (or fold into `_assembleServer`).
file   | apps/dartclaw_cli/lib/src/commands/service_wiring.dart:802-891     | TARGET: MCP-tool registration (sessions_send/spawn, memory_*, web_fetch, canvas, advisor subscribers, search providers) — extract into `_registerMcpTools(ctx, server)`.
file   | apps/dartclaw_cli/lib/src/commands/service_wiring.dart:898-935     | TARGET: `WiringResult` assembly + shutdownExtras closure — extract into `_assembleWiringResult` returning the result.
file   | apps/dartclaw_cli/lib/src/commands/workflow/cli_workflow_wiring.dart:175-601 | TARGET: existing `CliWorkflowWiring.wire()` body; the storage / task layer / harness / behaviour / artifact collector / workflow service / task executor / registry sections map onto `_wireXxx` methods.
file   | apps/dartclaw_cli/lib/src/commands/workflow/cli_workflow_wiring.dart:414-578 | TARGET: huge `WorkflowTurnAdapter(...)` literal with ≥10 closures — strongly recommend extracting via `_buildWorkflowTurnAdapter(ctx, turns, taskService, projectService, ...)` returning the adapter; without this, `wire()` cannot reach ≤100 LOC.
file   | apps/dartclaw_cli/test/e2e/server_builder_integration_test.dart    | Regression guard — public `ServiceWiring(...)` ctor + `WiringResult` field set must stay compatible.
```

## Constraints & Gotchas

- **Constraint**: Behaviour change is forbidden (Constraint #1, #71). — Workaround: refactor in small, test-validated steps. After each `_wireXxx` extraction, re-run `dart analyze` and the targeted unit tests. Use `git diff -w` to confirm the only meaningful changes are control-flow re-shaping (method calls instead of inline statements) — never reordering of statements that touched IO/streams/event ordering.
- **Critical**: `late DartclawServer serverRef;` and `late TurnManager serverTurns;` are bound mid-method (after harness wires, after server builds, after tasks post-server wire). Closures from `harness.wire(serverRefGetter: () => serverRef)`, `channel.wire(serverRefGetter: () => serverRef, turnManagerGetter: () => serverTurns, …)`, the `pushBackFeedbackDelivery` closure, and the alert-router channel-lookup all capture these `late` refs by reference. — Must handle by: storing the late refs on `_WiringContext` with setter methods (`ctx.bindServer(server)`, `ctx.bindTurns(turns)`) and exposing them via getters; the closures keep capturing `ctx.serverRefGetter`/`ctx.turnManagerGetter` so binding order is preserved.
- **Critical**: `CliWorkflowWiring`'s public `late final` instance fields (`pool`, `taskService`, `workflowService`, `workflowCliRunner`, `behavior`, `projectService`, `remotePushService`, `taskExecutor`, `taskCancellationSubscriber`, `skillRegistry`, `registry`, `eventBus`, `kvService`, `sessionService`, `messageService`, `searchDb`, `taskDb`, `worktreeManager`) are read by `dispose()` and likely by external callers. — Must handle by: leaving the field declarations alone; only refactor the `wire()` body. The `_CliWorkflowWiringContext` carries internal-to-`wire()` cross-cutting deps, not the exported handles.
- **Avoid**: Reordering statements that interact with `EventBus.subscribe` order, `ConfigNotifier.register` order, signal/IO setup, or `bootstrapAndthenSkills` invocation. — Instead: preserve the original 0..8 numbered ordering inside the new dispatcher; if a `_wireXxx` would re-order vs the original, leave it inline in `wire()` and split a different boundary.
- **Avoid**: Capturing `this` deep inside extracted lambdas in a way that defeats AOT tree-shaking. — Instead: prefer plain function arguments over instance-method tear-offs in performance-sensitive paths (existing pattern).
- **Constraint**: Workspace-wide strict-casts + strict-raw-types stay on. — Workaround: any new record/struct fields must have explicit types; any new private records must avoid `dynamic` / `Object` un-typed payloads.
- **Gotcha**: `service_wiring.dart` already imports `wiring/*.dart` files. Do NOT create a new `wiring/wiring_context.dart` file — keep `_WiringContext` private inside `service_wiring.dart` to satisfy "≤800 LOC total" and avoid file-count creep. Same for `_CliWorkflowWiringContext` — keep inside `cli_workflow_wiring.dart`.
- **Gotcha**: `DartclawServerBuilder` uses field-cascade assignment (`builder ..a = … ..b = …`). Splitting the pre-server cascade across `_wireXxx` methods is fine, but each method must take the same `builder` instance and return it (or operate via `ctx.builder`). Prefer adding `late DartclawServerBuilder builder` to the context struct rather than threading the builder as a method param everywhere.
- **Gotcha**: The two `_workflowGit(...)` calls (around lines 540 and 593) are file-private helpers used inside the `WorkflowTurnAdapter` closures. When extracting `_buildWorkflowTurnAdapter`, keep the helper top-level-private in `service_wiring.dart` — do NOT move into the context struct.

## Implementation Plan

> **Vertical slice ordering**: Land the context struct first, then split methods one section at a time (highest-LOC sections first), validating after each. A single big-bang split risks behaviour drift that's hard to bisect.

### Implementation Tasks

- [ ] **TI01** `_WiringContext` value type defined in `apps/dartclaw_cli/lib/src/commands/service_wiring.dart` carrying `eventBus`, `configNotifier`, `dataDir`, `port`, `assetResolver`, `resolvedAssets`, `builtInSkillsSourceDir`, `skillRegistry`, `messageRedactor`, plus `late` slots / setters for `builder` (`DartclawServerBuilder`), `serverRef`, `serverTurns`. Constructed at the top of `wire()`; existing late-getter call sites updated to call through the context.
  - Pattern: see `apps/dartclaw_cli/lib/src/commands/wiring/security_wiring.dart` for "named final fields + ctor" shape.
  - **Verify**: `dart analyze apps/dartclaw_cli/lib/src/commands/service_wiring.dart` passes with the context defined and used in place of standalone locals; existing `dart test apps/dartclaw_cli/test/commands/serve_command_test.dart` passes; `wire()` LOC reduced from baseline by at least the count of fields hoisted onto the context.

- [ ] **TI02** Extract `_wireRestartSentinel(_WiringContext ctx)` (the `restart.pending` sniff at lines ~327-339) and `_wireProviderStatusAndCanvas(_WiringContext ctx, HarnessWiring harness, …)` (`ProviderStatusService` + `CanvasService` construction) as standalone private methods. These are cohesive low-risk slices that prove the pattern.
  - Constraint: stderr message text `Restarted after config change (pending: $fields)` and `Restarted after config change` must remain byte-identical (S-NoBehaviourChange-Restart).
  - **Verify**: `dart test apps/dartclaw_cli/test/commands/serve_command_test.dart` (and any restart-pending test) passes; manual smoke `touch <dataDir>/restart.pending && dartclaw serve` prints the expected line; `wire()` LOC dropped further.

- [ ] **TI03** Extract `_wirePreServerBuilder(_WiringContext ctx, …)` covering the first cascade (`builder ..sessions = … ..workspaceDisplay = …` at lines ~354-399) and `_wirePostServerBuilder(_WiringContext ctx, …)` covering the second cascade (lines ~765-797). The first ends just before `serverTurns = builder.buildTurns()`; the second ends at `final server = serverFactory(builder); serverRef = server;`. After this task, `_assembleServer(_WiringContext ctx)` wraps `serverFactory(builder)` and binds `ctx.serverRef = server`.
  - Constraint: do NOT change the field-set of `DartclawServerBuilder`; do NOT reorder cascade entries (some are interdependent with `harness.wire`'s late binding).
  - **Verify**: `dart test apps/dartclaw_cli` passes; `dart test --run-skipped -t integration apps/dartclaw_cli/test/e2e/server_builder_integration_test.dart` passes (integration test asserts on `WiringResult.server` shape).

- [ ] **TI04** Extract the remaining `_wireXxx` methods covering the eight numbered sections (`_wireProjects`, `_wireAndthenSkillsBootstrap`, `_wireSkillRegistryDiscovery`, `_wireStorage`, `_wireSecurity`, `_wireHarness`, `_wirePreServerTasks`, `_wireChannels`, `_wirePostServerTasks`, `_wireWorkflowService` (which includes the `WorkflowTurnAdapter` literal — extract to `_buildWorkflowTurnAdapter` if needed), `_wireWorkflowRegistry`, `_wireThreadBindingLifecycle`, `_wireScheduling`, `_wireAlertRouter`, `_wireGroupSessionInit`, `_wireRestartService`, `_registerMcpTools`, `_wireSpaceEventsStart`, `_assembleWiringResult`). `wire()` becomes a sequential dispatcher.
  - Constraint: section ordering preserved; `late` binding sites move onto context setters; `wire()` reaches ≤100 LOC.
  - **Verify**: `wc -l < apps/dartclaw_cli/lib/src/commands/service_wiring.dart` ≤ 800; `awk '/Future<WiringResult> wire\(\) async \{/,/^  \}$/' apps/dartclaw_cli/lib/src/commands/service_wiring.dart | wc -l` ≤ 100; `dart test apps/dartclaw_cli` passes.

- [ ] **TI05** `_CliWorkflowWiringContext` value type defined in `apps/dartclaw_cli/lib/src/commands/workflow/cli_workflow_wiring.dart` carrying `eventBus`, `dataDir`, `runtimeCwd`, `environment`, `assetResolver`, `builtInSkillsSourceDir`, `credentialRegistry`, `harnessConfig`, `roleDefaults`, `skillRegistry`. Constructed at the top of `wire()`; replaces the in-method `final` locals it absorbs.
  - Pattern: same shape as `_WiringContext`.
  - **Verify**: `dart analyze apps/dartclaw_cli/lib/src/commands/workflow/cli_workflow_wiring.dart` passes; existing `apps/dartclaw_cli/test/commands/workflow/cli_workflow_wiring_test.dart` (or equivalent) passes.

- [ ] **TI06** Extract `_buildWorkflowTurnAdapter(_CliWorkflowWiringContext ctx, TurnManager turns, …)` containing the ~165-LOC `WorkflowTurnAdapter(...)` literal and its inline closures (`resolveStartContext`, `bootstrapWorkflowGit`, `promoteWorkflowBranch`, `publishWorkflowBranch`, `cleanupWorkflowGit`, `cleanupWorktreeForRetry`, `captureWorkflowBranchSha`, `captureAndCleanWorktreeForRetry`, `runResolverAttemptUnderLock`, `reserveTurn`, `reserveTurnWithWorkflowWorkspaceDir`, `executeTurn`, `waitForOutcome`, `availableRunnerCount`).
  - Constraint: closure bodies untouched — copy verbatim; only their lexical surroundings change.
  - **Verify**: `dart test apps/dartclaw_cli` passes; an existing standalone-workflow test (or a fresh one in `test/commands/workflow/` if missing for adapter creation) asserts `_buildWorkflowTurnAdapter` returns an adapter whose `publishWorkflowBranch` (no-PR-creator path) yields the same `WorkflowGitPublishResult` shape.

- [ ] **TI07** Extract the remaining `_wireXxx` methods on `CliWorkflowWiring` (`_wireSkillRegistry`, `_wireStorage`, `_wireTaskLayer`, `_wireProjectAndWorktree`, `_wireHarness`, `_wireBehaviour`, `_wireRunnerPool`, `_wireArtifactCollector`, `_wireWorkflowService` (calls `_buildWorkflowTurnAdapter`), `_wireWorkflowRegistry`, `_wireTaskExecutor`). `wire()` becomes a ≤100-LOC dispatcher.
  - Constraint: public `late final` instance-field set unchanged; `dispose()` body unchanged.
  - **Verify**: `awk '/Future<void> wire\(\) async \{/,/^  \}$/' apps/dartclaw_cli/lib/src/commands/workflow/cli_workflow_wiring.dart | wc -l` ≤ 100; `dart test apps/dartclaw_cli` passes.

- [ ] **TI08** File-LOC trim — comment policy pass on both files: delete numbered-section narration comments that are now redundant with method names; keep rationale-only comments (e.g. "lazy because closures capture `serverRef`"); delete any `// REMOVED` / `// was:` markers. Verify nothing dead remains.
  - **Verify**: `wc -l < apps/dartclaw_cli/lib/src/commands/service_wiring.dart` ≤ 800; `wc -l < apps/dartclaw_cli/lib/src/commands/workflow/cli_workflow_wiring.dart` ≤ 600; `rg "// REMOVED|// was:|// TODO" apps/dartclaw_cli/lib/src/commands/service_wiring.dart apps/dartclaw_cli/lib/src/commands/workflow/cli_workflow_wiring.dart` empty (or only TODOs with owner+issue link, none expected from this refactor).

- [ ] **TI09** Workspace-wide validation: `dart format --set-exit-if-changed apps/dartclaw_cli/lib/src/commands/service_wiring.dart apps/dartclaw_cli/lib/src/commands/workflow/cli_workflow_wiring.dart` clean; `dart analyze --fatal-warnings --fatal-infos` workspace-wide clean; `dart test apps/dartclaw_cli` (default tags) green; `apps/dartclaw_cli/pubspec.yaml` diff is empty.
  - **Verify**: all four commands exit 0; `git diff -- apps/dartclaw_cli/pubspec.yaml` is empty.

- [ ] **TI10** Manual smoke proof of behavioural identity:
  1. Capture pre-refactor baseline at `git stash` (or against `HEAD~1`): `dart run dartclaw_cli:dartclaw serve --port 3333 --config <dev.yaml>` startup banner + `curl http://localhost:3333/health` JSON + the registered MCP tool list (e.g. via `curl http://localhost:3333/mcp/...` or via SSE `connected` envelope) saved to `dev/.agent_temp/s17-baseline-serve.txt`.
  2. Apply the refactor and re-run; save to `dev/.agent_temp/s17-refactored-serve.txt`.
  3. `diff` the two — expect empty (or whitespace-only).
  4. Repeat for `dartclaw workflow run code-review --standalone --project <fixture>` against a fixture project; compare task-event sequences and exit codes.
  - **Verify**: both diffs are empty (or whitespace-only); both commands exit 0.

- [ ] **TI11** Integration test: `dart test --run-skipped -t integration apps/dartclaw_cli/test/e2e/server_builder_integration_test.dart` passes; the test's import `package:dartclaw_cli/src/commands/service_wiring.dart` and constructor call site needed no edits.
  - **Verify**: integration test green; `git diff -- apps/dartclaw_cli/test/e2e/server_builder_integration_test.dart` is empty.

- [ ] **TI12** Public-surface diff sanity: `git diff -- apps/dartclaw_cli/lib/src/commands/service_wiring.dart apps/dartclaw_cli/lib/src/commands/workflow/cli_workflow_wiring.dart | rg '^[-+]\s*(class|abstract|final class|sealed class|extension|typedef)\s|\bWiringResult\b|\b(ServiceWiring|CliWorkflowWiring)\(' --color never` shows no deletions of public-surface lines (additions of `_WiringContext`, `_CliWorkflowWiringContext`, and `_wireXxx`/`_buildXxx` helpers are expected; no removals of `class WiringResult`, `class ServiceWiring`, `class CliWorkflowWiring`, ctor named-param set, or `wire()` signatures).
  - **Verify**: the rg command output shows zero `^-` lines that match public-surface patterns; `WiringResult` field set is unchanged in the diff.

### Testing Strategy

- [TI01,TI05] Compilation + unit pass — proves context structs introduced without breaking call sites.
- [TI02] Scenario S-NoBehaviourChange-Restart → existing serve_command_test (or a new tiny test under `test/commands/wiring/restart_sentinel_test.dart`) writes a `restart.pending`, runs wire-equivalent path, asserts the stderr line and the file deletion.
- [TI03,TI04] Scenario S-Happy-Serve → `server_builder_integration_test.dart` exercises the post-refactor `ServiceWiring.wire()` end-to-end and asserts `WiringResult` shape; existing serve_command tests cover MCP-tool-registration ordering.
- [TI04,TI06,TI07] Scenario S-Happy-Workflow-Run → `dart test apps/dartclaw_cli/test/commands/workflow/` (existing standalone-mode tests) covers `CliWorkflowWiring.wire()` post-refactor.
- [TI04,TI07] Scenario S-NewSubsystemPattern → no test required; assert via Code Review that the per-section pattern is consistent (FIS Final Validation step).
- [TI04,TI07] Scenario S-Skip-AndthenBootstrap → existing `service_wiring_andthen_skills_test.dart` (apps/dartclaw_cli/test/commands/) and equivalent for `cli_workflow_wiring` already gate `runAndthenSkillsBootstrap = false`; both pass post-refactor.
- [TI04,TI07] Scenario S-NoBehaviourChange-EmergencyPaths → existing tests under `apps/dartclaw_cli/test/commands/` for budget warning + loop detection notifications pass without changes.
- [TI11] Integration coverage — `server_builder_integration_test.dart` is the highest-fidelity public-surface guard; must pass with zero edits.

### Validation

- Visual validation N/A (no UI changes).
- Behavioural-identity manual smoke (TI10) is required given the refactor's risk surface — diff-against-baseline is the cheapest reliable proof of "zero behaviour change."

### Execution Contract
- Implement tasks in listed order. Each **Verify** line must pass before proceeding to the next task. TI01 and TI02 land context + low-risk sentinel split first; TI03 and TI04 land the bulk of `service_wiring.dart`; TI05–TI07 land `cli_workflow_wiring.dart`; TI08–TI12 are validation.
- Prescriptive details (LOC ceilings, struct names per Decision #26, file paths) are exact — implement them verbatim.
- Sub-agents: spawn `andthen:documentation-lookup` only if a Dart language question arises (e.g. records vs `final class` for the context); none expected.
- After all tasks: run `dart format --set-exit-if-changed`, `dart analyze --fatal-warnings --fatal-infos`, `dart test apps/dartclaw_cli`, and the integration smoke from TI10–TI11. Keep `rg "TODO|FIXME|placeholder|not.implemented" apps/dartclaw_cli/lib/src/commands/service_wiring.dart apps/dartclaw_cli/lib/src/commands/workflow/cli_workflow_wiring.dart` empty.
- Mark task checkboxes immediately upon completion — do not batch.

## Final Validation Checklist

- [ ] All Success Criteria met (LOC ceilings, context structs in place, public surface unchanged, dart test green, manual smoke matches baseline, integration test green).
- [ ] All tasks fully completed, verified, and checkboxes checked.
- [ ] No regressions or breaking changes introduced (Constraint #1, #71).
- [ ] Server-side `packages/dartclaw_server/lib/src/service_wiring.dart` untouched.
- [ ] No new dependencies added to `apps/dartclaw_cli/pubspec.yaml` (Constraint #2).
- [ ] `dart analyze --fatal-warnings --fatal-infos` workspace-wide clean; strict-casts/raw-types unchanged.

## Implementation Observations

> _Managed by exec-spec post-implementation — append-only._

_No observations recorded yet._
