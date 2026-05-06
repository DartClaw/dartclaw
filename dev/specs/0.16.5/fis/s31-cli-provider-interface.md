# Feature Implementation Specification — S31: CliProvider Interface for WorkflowCliRunner

**Plan**: ../plan.md
**Story-ID**: S31

## Feature Overview and Goal

Encapsulate `WorkflowCliRunner.executeTurn`'s already-branching per-provider dispatch behind a `CliProvider` abstract interface with `ClaudeCliProvider` and `CodexCliProvider` concrete implementations. Each provider owns its `_buildXxxCommand` logic, parsing helpers, and temp-file lifecycle; `executeTurn` collapses to a ≤60-LOC dispatcher over `Map<String, CliProvider>`. Adding a future provider becomes "add one new `CliProvider` class"; the runner stops growing per-provider switch arms. Zero behaviour change at the dispatcher level — stdout/stderr text, `WorkflowCliTurnResult` shape, telemetry events all byte-identical.

> **Technical Research**: [.technical-research.md](../.technical-research.md) — Story-Scoped File Map § "S31 — CliProvider Interface for WorkflowCliRunner" and Shared Decision #25.


## Required Context

### From `dev/specs/0.16.5/plan.md` — "S31: CliProvider Interface for WorkflowCliRunner"
<!-- source: dev/specs/0.16.5/plan.md#p-s31-cliprovider-interface-for-workflowclirunner -->
<!-- extracted: e670c47 -->
> **Scope**: `packages/dartclaw_server/lib/src/task/workflow_cli_runner.dart` grew from 515 → 635 LOC during 0.16.4 as Codex support matured; `executeTurn` now has 11 optional parameters and a per-provider switch that mixes process lifecycle, provider-specific command construction, and temp-file management. Introduce `abstract class CliProvider { Future<WorkflowCliTurnResult> run(CliTurnRequest request); }` plus `ClaudeCliProvider` and `CodexCliProvider` implementations. Each implementation owns its `_buildXxxCommand` logic (working-dir translation, container mount wiring, provider-specific stdin/stdout parsing) and temp-file cleanup. `WorkflowCliRunner.executeTurn` becomes a dispatcher on `Map<String, CliProvider>`. Keep `_WorkflowCliCommand` private helper type if still needed, or promote it to a `CliTurnRequest` value object. As part of TD-070, record the ownership decision explicitly: `WorkflowCliRunner` remains in `dartclaw_server` for now as the concrete one-shot process adapter, while portable request/value types and reusable parsing/settings helpers move to `dartclaw_core`; a full harness-dispatched rewrite remains out of scope.
>
> **Acceptance Criteria**:
> - `CliProvider` interface exists with `ClaudeCliProvider`/`CodexCliProvider` implementations (must-be-TRUE)
> - `WorkflowCliRunner.executeTurn` ≤60 LOC and contains no provider-specific branching (must-be-TRUE)
> - Ownership decision documented as a dated addendum section appended to `docs/adrs/023-workflow-task-boundary.md` (private repo; the canonical ADR-023 location): runner remains server-owned concrete adapter; core owns portable request/value/helper types; addendum is cross-referenced from public-repo `docs/architecture/workflow-architecture.md` so public readers can find it (must-be-TRUE)
> - `workflow_cli_runner.dart` total LOC reduced from ~635 toward ~350 (must-be-TRUE)
> - `dart test packages/dartclaw_server/test/task/workflow_cli_runner_test.dart` passes; add a per-provider test where the existing test is implementation-agnostic
> - Adding a future provider (e.g. Ollama) requires adding only a new `CliProvider` class — no edits to `WorkflowCliRunner` itself

### From `dev/specs/0.16.5/prd.md` — "Constraints"
<!-- source: dev/specs/0.16.5/prd.md#constraints -->
<!-- extracted: e670c47 -->
> - **No new user-facing features.** Any feature-shaped work defers to 0.16.6+.
> - **No breaking protocol changes.** JSONL control protocol, REST payloads, SSE envelope format all stable.
> - **No new dependencies** in any package.
> - **Workspace-wide strict-casts + strict-raw-types** must remain on throughout.

### From `dev/state/TECH-DEBT-BACKLOG.md` — "TD-070 — Workflow architecture and fitness carry-overs"
<!-- source: dev/state/TECH-DEBT-BACKLOG.md#td-070 -->
<!-- extracted: e670c47 -->
> **Context**: The 0.16.4 workflow requirements baseline intentionally carries three advisory architecture/fitness items into 0.16.5+: `workflow_executor.dart` remains above the 800-line fitness target, `WorkflowCliRunner` still lives in `dartclaw_server` despite acting as workflow/task boundary infrastructure, and several inter-package workflow task-config keys remain stringly typed.
>
> **Current state**: Non-gating for 0.16.4. Fitness tests keep the current file-size baseline visible, and ADR-023 documents the workflow/task boundary direction. The 0.16.5 PRD/plan now fold the carry-overs into existing stabilisation stories: S15 handles the executor extraction, **S31 records the `WorkflowCliRunner` ownership/seam decision**, and S34 centralises workflow task-config keys.


## Deeper Context

- `dev/specs/0.16.5/.technical-research.md#s31--cliprovider-interface-for-workflowclirunner` — Story-scoped file map: target paths for the new `CliProvider` interface, `ClaudeCliProvider`/`CodexCliProvider` implementations, and ADR-023 addendum.
- `dev/specs/0.16.5/.technical-research.md#shared-architectural-decisions` — Shared Decision #25 (`CliProvider` interface shape and ownership rule).
- `packages/dartclaw_server/CLAUDE.md` — package-scoped conventions: workflow-task glue (`workflow_one_shot_runner.dart`, `workflow_cli_runner.dart`) lives under `lib/src/task/`; container orchestration stays in this package and **must not move down** to core.
- `packages/dartclaw_server/lib/src/task/workflow_cli_runner.dart` — current 806-LOC implementation (research recorded 635 LOC; the file has grown further, which strengthens the case for this story).


## Success Criteria (Must Be TRUE)

> Each criterion has a proof path: a Scenario (behavioral) or task Verify line (structural).

- [ ] **`CliProvider` abstract interface exists** at `packages/dartclaw_server/lib/src/task/cli_provider.dart` with the contract `Future<WorkflowCliTurnResult> run(CliTurnRequest request)` (proof: TI01 Verify)
- [ ] **`ClaudeCliProvider` and `CodexCliProvider` concrete implementations exist** in the same package, each owning its `_buildXxxCommand`, provider-specific parsing, and temp-file cleanup (proof: TI02, TI03 Verify lines)
- [ ] **`WorkflowCliRunner.executeTurn` ≤60 LOC** (counted as the method body inclusive of signature line through closing brace) with **no `switch (provider)` arm referencing provider names** — dispatch is `providers[provider]?.run(request)` over a `Map<String, CliProvider>` (proof: TI04 Verify; Scenario "Adding a third provider requires no `WorkflowCliRunner` edit")
- [ ] **`workflow_cli_runner.dart` total LOC reduced from current 806 toward ~350** (target ≤400 LOC for the runner file; per-provider extraction targets ~200-250 LOC per provider file) (proof: TI08 Verify)
- [ ] **ADR-023 dated addendum exists in private repo** at `docs/adrs/023-workflow-task-boundary.md` recording the ownership decision: `WorkflowCliRunner` stays server-owned concrete adapter; core owns portable request/value/helper types; full harness-dispatched rewrite explicitly out of 0.16.5 (proof: TI07 Verify)
- [ ] **Public-repo cross-reference exists** so public readers can discover the addendum: a one-line pointer in `packages/dartclaw_server/CLAUDE.md` (or `docs/guide/architecture.md` if a workflow section is the better fit) noting that the ownership/seam decision is recorded in private-repo ADR-023's 2026-05 addendum (proof: TI07 Verify)
- [ ] **`dart test packages/dartclaw_server/test/task/workflow_cli_runner_test.dart` passes** with zero edits to existing assertions — existing tests remain implementation-agnostic against `WorkflowCliRunner.executeTurn`'s public contract (proof: Scenario "Existing workflow_cli_runner_test suite passes byte-identically"; TI09 Verify)
- [ ] **Adding a future provider (e.g. `OllamaCliProvider`) requires only a new `CliProvider` class** — no edits to `WorkflowCliRunner` itself (proof: Scenario "Adding a third provider requires no `WorkflowCliRunner` edit"; TI06 Verify via doc-comment + grep that `executeTurn` body contains no provider-name string literals)

### Health Metrics (Must NOT Regress)

- [ ] All existing `packages/dartclaw_server/test/task/workflow_cli_runner_test.dart` tests pass with zero diff to existing assertions (only added per-provider tests are new code)
- [ ] `dart analyze --fatal-warnings --fatal-infos packages/dartclaw_server` clean
- [ ] `dart format --set-exit-if-changed packages/dartclaw_server` clean
- [ ] `WorkflowCliTurnResult` shape unchanged (no field added/removed/renamed); `WorkflowCliProviderConfig` shape unchanged
- [ ] `WorkflowCliTurnProgressEvent` emission semantics unchanged — Codex streaming progress events fire on the same lines, with the same payload, as before the refactor
- [ ] No new package dependencies anywhere in the workspace (binding constraint #2)


## Scenarios

### Workflow one-shot invokes Claude — output byte-identical (happy path)

- **Given** `WorkflowCliRunner` is constructed with `providers: {'claude': WorkflowCliProviderConfig(executable: 'claude', ...)}` and a recorded `WorkflowCliProcessStarter` fake that returns a process emitting the canonical Claude stream-json events from the existing test fixture
- **When** the orchestrator calls `executeTurn(provider: 'claude', prompt: 'hello', workingDirectory: ..., profileId: ..., providerSessionId: 'sess-7', model: 'claude-sonnet-4-5', ...)`
- **Then** the resulting `WorkflowCliTurnResult` has the same `providerSessionId`, `responseText`, `structuredOutput`, token counts, `totalCostUsd`, and `duration > Duration.zero` as the pre-refactor baseline captured by `workflow_cli_runner_test.dart`; the recorded process invocation receives the same executable + arguments + working directory + environment

### Workflow one-shot invokes Codex — output byte-identical (happy path / streaming)

- **Given** `WorkflowCliRunner` is constructed with `providers: {'codex': WorkflowCliProviderConfig(executable: 'codex', options: {'sandbox': 'workspace-write'})}`, a fake `EventBus`, and a recorded process starter returning a process emitting Codex JSON-RPC frames including `WorkflowCliTurnProgressEvent`-triggering events
- **When** the orchestrator calls `executeTurn(provider: 'codex', prompt: 'task', workingDirectory: ..., profileId: ..., taskId: 'task-1', sessionId: 'sess-9', sandboxOverride: 'read-only', ...)`
- **Then** stricter sandbox resolution still chooses `read-only` (preserving the existing `_CodexSandboxDecision` semantics), the recorded process invocation matches the pre-refactor command vector exactly, the `WorkflowCliTurnProgressEvent` events fired on the bus match the pre-refactor sequence, and the returned `WorkflowCliTurnResult` is byte-identical to the baseline

### Adding a third provider requires no `WorkflowCliRunner` edit

- **Given** an experimental `OllamaCliProvider implements CliProvider` is authored in a downstream branch
- **When** the developer registers it via `WorkflowCliRunner(providers: {..., 'ollama': WorkflowCliProviderConfig(executable: 'ollama')}, providerImpls: {..., 'ollama': OllamaCliProvider(...)})` (or whatever the chosen registration shape is — see Architecture Decision)
- **Then** `executeTurn` routes calls with `provider: 'ollama'` to the new provider via the same `Map<String, CliProvider>` dispatch — no edits to `WorkflowCliRunner.executeTurn` body, no new `case 'ollama':` arm anywhere in `workflow_cli_runner.dart`

### Per-provider command construction stays inside the provider (structural)

- **Given** any future change to Claude command flags (e.g. a new `--cache-control` option) or Codex sandbox handling
- **When** a contributor goes to add it
- **Then** the diff touches **only** `claude_cli_provider.dart` (or `codex_cli_provider.dart` / its sibling helpers) — `workflow_cli_runner.dart` remains unchanged

### Unknown provider error path (negative path)

- **Given** `WorkflowCliRunner` is constructed with `providers: {'claude': ...}` only
- **When** the orchestrator calls `executeTurn(provider: 'codex', ...)`
- **Then** `executeTurn` throws `StateError('No workflow CLI provider config for "codex"')` — same exception type and message as before the refactor, validated by the existing test at `workflow_cli_runner_test.dart`

### Existing workflow_cli_runner_test suite passes byte-identically (regression / no-change-to-tests)

- **Given** the existing 1164-LOC `packages/dartclaw_server/test/task/workflow_cli_runner_test.dart`
- **When** `dart test packages/dartclaw_server/test/task/workflow_cli_runner_test.dart` is run after the refactor
- **Then** every existing test passes with zero edits to the test file's existing assertions; only **additions** are allowed (per-provider unit tests for `ClaudeCliProvider` / `CodexCliProvider` directly, exercising builder shape — these are net-new and live in either the same file under a new `group(...)` or sibling files `claude_cli_provider_test.dart` / `codex_cli_provider_test.dart`)


## Scope & Boundaries

### In Scope

_Every scope item maps to at least one task with a Verify line._

- New file `packages/dartclaw_server/lib/src/task/cli_provider.dart` with `abstract class CliProvider`, the `CliTurnRequest` value type (private to this package unless promoted later), and any shared helper types lifted from `_WorkflowCliCommand` (TI01)
- New file `packages/dartclaw_server/lib/src/task/claude_cli_provider.dart` with `class ClaudeCliProvider implements CliProvider`, owning `_buildClaudeCommand`, Claude stream-json parsing (`_parseClaude`), and Claude-specific settings/permission helpers (TI02)
- New file `packages/dartclaw_server/lib/src/task/codex_cli_provider.dart` with `class CodexCliProvider implements CliProvider`, owning `_buildCodexCommand`, Codex stream parsing (`_parseCodex`, `_handleCodexLine`, `_CodexSandboxDecision`, `_CodexStreamState`), temp-schema-file cleanup, and Codex-specific event emission (TI03)
- Refactor `WorkflowCliRunner.executeTurn` to a ≤60-LOC dispatcher: validate provider config exists, look up `CliProvider` impl in `Map<String, CliProvider>`, build `CliTurnRequest`, delegate to `provider.run(request)`, return its result (TI04)
- Promote or retire `_WorkflowCliCommand` — promote to `CliTurnRequest` (or a sibling `CliCommandPlan`) only if needed across providers; if each provider's `_buildXxxCommand` returns its own private result, leave as provider-scoped private types (TI01 design call)
- Per-provider tests where existing test is implementation-agnostic — add direct unit tests for `ClaudeCliProvider`/`CodexCliProvider` exercising command-vector construction without spawning a process (TI05)
- Verify `executeTurn` body contains no provider-name string literals via grep (TI06)
- Add ADR-023 dated addendum in **private repo** at `docs/adrs/023-workflow-task-boundary.md` with `## Addendum — 2026-05 — `WorkflowCliRunner` Ownership` heading, three paragraphs (decision / rationale / out-of-scope) (TI07)
- Add public-repo cross-reference in `packages/dartclaw_server/CLAUDE.md` under the existing **Workflow glue** bullet (or in `docs/guide/architecture.md` if a workflow section exists) — single-line pointer to the private-repo addendum (TI07)
- LOC verification (TI08)
- Full validation (TI09)

### What We're NOT Doing

- **Not rewriting `WorkflowCliRunner` as a harness-dispatched runner** — full harness-dispatched rewrite is **explicitly out of 0.16.5** per the ADR-023 addendum recorded by this story; the runner stays as the concrete one-shot process adapter. Revisit in a future milestone after the workflow ↔ task boundary is fully consolidated.
- **Not moving `WorkflowCliRunner` into `dartclaw_core`** — server-owned per TD-070 ownership decision and `dartclaw_server/CLAUDE.md` boundary rules ("Container orchestration ... lives here, not in core ... Don't move it down"). Container/`ContainerExecutor` integration is the binding constraint that pins the runner to `dartclaw_server`.
- **Not changing `WorkflowCliTurnResult` / `WorkflowCliProviderConfig` / `executeTurn` public signature** — binding constraint #1 (REST/SSE wire format unchanged) doesn't apply directly here, but the same zero-behaviour-change discipline forbids it; any caller of `executeTurn` must compile and behave identically.
- **Not touching `workflow_one_shot_runner.dart` (the caller of `WorkflowCliRunner`)** — that's S29's blast radius for run-id command base; out of S31's scope.
- **Not refactoring `claude_code_harness.dart` parsing helpers** — S34 owns the `ClaudeSettingsBuilder` extraction and the cross-package `normalizeDynamicMap` consolidation; S31 stays inside `WorkflowCliRunner`'s blast radius.
- **Not promoting `CliTurnRequest` to `dartclaw_core` in this story** — the plan explicitly says "portable request/value types ... move to `dartclaw_core` as opportunity arises"; the opportunity is not S31. Keep types package-private now; promote later when a second consumer appears.

### Agent Decision Authority

- **Autonomous**: Whether `_WorkflowCliCommand` survives as a private helper or is promoted/renamed to `CliTurnRequest`/`CliCommandPlan`; whether per-provider impls live as separate top-level classes (`ClaudeCliProvider` / `CodexCliProvider`) or as a single file with sibling classes (preferred: separate files for grep-ability); whether `_handleCodexLine`, `_CodexSandboxDecision`, `_CodexStreamState`, `_mapValue`, `_intValue`, `_previewText` move into the Codex provider as `_`-prefixed private members or as siblings inside `codex_cli_provider.dart`; whether the public-repo cross-reference lives in `packages/dartclaw_server/CLAUDE.md` (concise) or `docs/guide/architecture.md` (more discoverable for end-readers) — pick whichever is most consistent with existing precedent and document the choice.
- **Escalate**: Any change that alters `executeTurn`'s public signature; any change to `WorkflowCliTurnResult` or `WorkflowCliProviderConfig`; any change that requires editing `workflow_one_shot_runner.dart` or other callers; any test edit beyond pure additions.


## Architecture Decision

**We will**: Introduce a `CliProvider` interface **owned by `dartclaw_server`** (not `dartclaw_core`) per TD-070's ownership decision. `WorkflowCliRunner` keeps its current public API, ownership of `providers: Map<String, WorkflowCliProviderConfig>`, ownership of `containerManagers`, and ownership of process spawning via the injected `WorkflowCliProcessStarter`. `executeTurn` delegates per-provider command construction, parsing, and temp-file cleanup to a `CliProvider` implementation looked up in a parallel `Map<String, CliProvider>`. Each impl receives a `CliTurnRequest` value object carrying everything `executeTurn` currently passes via the per-provider switch (prompt, container manager, options, sessionId/model/effort/etc.) plus collaborator hooks (process starter, event bus, uuid, log) so the impl can spawn its own process and emit events without owning runtime state.

The TD-070 ownership decision is recorded as a dated addendum to ADR-023 (private repo) — the canonical home for workflow ↔ task architectural decisions. The addendum names two facts: (1) `WorkflowCliRunner` stays in `dartclaw_server` because container orchestration (the `ContainerExecutor` collaborator) is server-owned and a downward move would invert the package dependency graph; (2) the full harness-dispatched rewrite (replacing `WorkflowCliRunner`'s one-shot process adapter pattern with reuse of `AgentHarness` interactive-mode infrastructure) is **explicitly out of 0.16.5** because it would widen blast radius beyond the milestone's stabilisation theme.

**Rationale**: Mechanical refactor that eliminates an already-branching dispatch with **zero behaviour change** at the public boundary. The existing 1164-LOC test suite is the proof-of-work — every existing test must pass byte-identically. Per-provider isolation makes future Ollama / generic-OpenAI-CLI providers a "new file, no runner edit" change. Recording the ownership decision in ADR-023 (rather than inline in code comments) means future readers find one canonical answer when asking "why is `WorkflowCliRunner` not in `dartclaw_core`?".

**Alternatives considered**:
1. **Promote `CliProvider` interface to `dartclaw_core` now** — rejected: violates `dartclaw_server/CLAUDE.md` boundary rule (container orchestration lives in server, not core); the `ContainerExecutor` collaborator that providers need is server-owned; promoting later (when a second consumer appears) is the cheaper sequencing.
2. **Keep `_buildClaudeCommand` / `_buildCodexCommand` as static methods on `WorkflowCliRunner` and only extract the dispatch** — rejected: doesn't reduce the 806-LOC file weight, doesn't enable "add new provider without editing runner", and leaves the per-provider `_handleCodexLine` / `_CodexStreamState` / `_CodexSandboxDecision` cluster mixed with Claude-specific helpers.
3. **Full harness-dispatched rewrite (use `AgentHarness` interactive-mode for one-shot turns)** — rejected: out of 0.16.5 scope per the recorded ADR-023 addendum; widens blast radius past the milestone's stabilisation theme.

See ADR: private repo `docs/adrs/023-workflow-task-boundary.md` (existing — "Accepted 2026-04-21") with the new dated **`## Addendum — 2026-05 — `WorkflowCliRunner` Ownership`** section authored by this story.


## Technical Overview

### Data Models (if applicable)

**`CliProvider` (abstract class)** — the protocol contract; one method `Future<WorkflowCliTurnResult> run(CliTurnRequest request)`. No state; implementations carry their own collaborators via constructor injection.

**`CliTurnRequest` (value object — package-private to `dartclaw_server` for now)** — bundles everything `executeTurn` currently passes per-provider:
- `prompt: String` (required)
- `workingDirectory: String` (required, host path)
- `profileId: String` (required)
- `taskId: String?`, `sessionId: String?`, `providerSessionId: String?`
- `model: String?`, `effort: String?`, `maxTurns: int?`
- `jsonSchema: Map<String, dynamic>?`
- `appendSystemPrompt: String?`, `sandboxOverride: String?`
- `extraEnvironment: Map<String, String>?`
- `providerConfig: WorkflowCliProviderConfig` (the per-provider YAML config)
- `containerManager: ContainerExecutor?` (resolved from `containerManagers[profileId]`)
- `processStarter: WorkflowCliProcessStarter` (so providers spawn through the runner-injected fake in tests)
- `eventBus: EventBus?`, `uuid: Uuid`, `log: Logger` (collaborators, hoisted up so impls don't reach for globals)

The provider implementations are responsible for: (a) translating `CliTurnRequest` → executable + args + env, (b) spawning the process via `processStarter`, (c) parsing stdout/stderr, (d) emitting any progress events, (e) cleaning up temp files in `finally`. The runner doesn't see any of that.

### Integration Points (if applicable)

- **`packages/dartclaw_server/lib/src/task/workflow_one_shot_runner.dart`** — sole production caller of `WorkflowCliRunner.executeTurn`; **untouched** because `executeTurn`'s public signature is preserved.
- **`packages/dartclaw_server/lib/src/server_builder.dart`** (or wherever `WorkflowCliRunner` is constructed) — needs to also construct the per-provider `CliProvider` map. Simplest: `WorkflowCliRunner` constructor accepts an optional `Map<String, CliProvider>? providerImpls` defaulting to a built-in factory registry that maps `'claude' → ClaudeCliProvider(...)` and `'codex' → CodexCliProvider(...)`. Default behaviour preserved; tests can inject a fake provider map.
- **`packages/dartclaw_server/test/task/workflow_cli_runner_test.dart`** — existing tests construct `WorkflowCliRunner` and exercise `executeTurn`. Default behaviour (built-in factory registry) means **no test edits** needed; tests continue to pass.


## Code Patterns & External References

```
# type | path/url                                                                                          | why needed
file   | packages/dartclaw_server/lib/src/task/workflow_cli_runner.dart:1-132                              | Source — typedefs, public types (WorkflowCliProviderConfig, WorkflowCliTurnResult), runner constructor; preserve unchanged
file   | packages/dartclaw_server/lib/src/task/workflow_cli_runner.dart:133-286                             | Source — current `executeTurn` body with per-provider switch and finally-block temp-file cleanup; collapse to ≤60-LOC dispatcher
file   | packages/dartclaw_server/lib/src/task/workflow_cli_runner.dart:288-432                             | Source — `_startProcess` + `_buildClaudeCommand` (Claude impl will own `_buildClaudeCommand` and its helpers; `_startProcess` stays available via a runner method or moves into `CliTurnRequest.processStarter`)
file   | packages/dartclaw_server/lib/src/task/workflow_cli_runner.dart:433-559                             | Source — `_handleCodexLine` + `_buildCodexCommand` + Codex stream parsing; lifts to `CodexCliProvider`
file   | packages/dartclaw_server/lib/src/task/workflow_cli_runner.dart:560-718                             | Source — small helpers (`_mapValue`, `_intValue`, `_previewText`, `_defaultProcessStarter`, `_claudePermissionMode`, `_claudeSettings`); split between providers (Claude helpers → ClaudeCliProvider; generic helpers stay on runner or move into `cli_provider.dart` shared helpers)
file   | packages/dartclaw_server/lib/src/task/workflow_cli_runner.dart:744-806                             | Source — `_WorkflowCliCommand`, `_CodexSandboxDecision`, `_CodexStreamState` private types; `_CodexSandboxDecision` + `_CodexStreamState` move with the Codex provider; `_WorkflowCliCommand` either becomes `CliTurnRequest`-side helper or stays Claude-private
file   | packages/dartclaw_server/test/task/workflow_cli_runner_test.dart:1-1164                            | Constraint — existing assertions must pass byte-identically; reference for per-provider test patterns to add (TI05)
file   | packages/dartclaw_server/CLAUDE.md                                                                 | Reference — package boundary rule: container orchestration stays in server; supports the "do not move to core" decision in the ADR-023 addendum
file   | dev/specs/0.16.5/.technical-research.md (Shared Decision #25)                                      | Reference — interface shape, ownership rule, scope of "out of 0.16.5"
file   | docs/adrs/023-workflow-task-boundary.md (in private repo)                                          | Target — append `## Addendum — 2026-05 — `WorkflowCliRunner` Ownership` section here (TI07)
```


## Constraints & Gotchas

- **Critical (binding constraint #2)**: No new package dependencies. `CliProvider` and impls use only `dart:async`, `dart:convert`, `dart:io`, `dart:math`, plus existing imports (`dartclaw_core`, `dartclaw_security`, `logging`, `meta`, `path`, `uuid`).
- **Critical (zero behaviour change)**: The existing 1164-LOC test suite is the proof-of-work. **Do not edit existing test assertions.** New tests are additions only. If any existing test fails after the refactor, the refactor is wrong — fix the implementation, not the test. The only exception: if an existing test reaches into a now-removed private member (e.g. `WorkflowCliRunner._buildClaudeCommand` via `@visibleForTesting`), provide a forwarding method or move the test to the new provider — but flag this in the implementation observations.
- **Constraint**: `@visibleForTesting (String, List<String>) buildCodexCommandForTesting(...)` at `workflow_cli_runner.dart:102-125` is consumed by tests. Either keep this method as a forwarder that delegates to the new `CodexCliProvider.buildCommandForTesting(...)`, or update its body to call the new impl. The public method signature must not change (existing tests depend on it).
- **Constraint**: `WorkflowCliTurnProgressEvent` is emitted from `_handleCodexLine` for Codex turns. The provider implementation owns this emission via the `eventBus` collaborator on `CliTurnRequest` — preserve the event payload shape and emission timing exactly.
- **Avoid**: Reaching back into `WorkflowCliRunner` from a provider impl. **Instead**: providers receive everything they need via `CliTurnRequest` (collaborators included). This keeps providers testable in isolation and prevents circular dependency between runner and impls.
- **Avoid**: Inventing a registration DSL or plugin discovery mechanism. **Instead**: the runner constructor accepts an optional `Map<String, CliProvider>? providerImpls` defaulting to `{'claude': ClaudeCliProvider(), 'codex': CodexCliProvider()}` (constructed inline). Future providers register by extending the default in the construction site (e.g. `server_builder.dart`).
- **Critical**: `WorkflowCliRunner` lives in `dartclaw_server`, not `dartclaw_core`. The `ContainerExecutor` collaborator (server-owned) is the binding constraint. Document this in the ADR-023 addendum (TI07) so this is the canonical answer for future readers asking "why isn't `CliProvider` in core?".
- **Constraint**: Codex temp-file cleanup currently lives in `executeTurn`'s `finally` block (lines 277-285). This responsibility moves with Codex command construction — `CodexCliProvider.run` owns the `try/finally` for its own `tempSchemaPath`. The runner must not retain any temp-file lifecycle code post-refactor.


## Implementation Plan

> **Vertical slice ordering**: TI01 establishes the interface and request type. TI02 + TI03 lift the two existing providers behind it. TI04 collapses the runner. TI05 + TI06 prove the seam (test additions + grep). TI07 records the ADR addendum and public cross-reference. TI08 + TI09 verify size + health.

### Implementation Tasks

- [ ] **TI01** New file `packages/dartclaw_server/lib/src/task/cli_provider.dart` exists with `abstract class CliProvider` declaring exactly one method `Future<WorkflowCliTurnResult> run(CliTurnRequest request)`, plus the `CliTurnRequest` value class carrying every field `executeTurn` currently passes per-provider (see Data Models section). `CliTurnRequest` is a package-private (`final class`, library-public for cross-file access within `lib/src/task/`) value object — fields all `final`, named-constructor initialiser, no methods beyond a possible `copyWith`. Imports limited to `package:dartclaw_core/dartclaw_core.dart` (for `ContainerExecutor`, `EventBus`, `WorkflowCliTurnProgressEvent`), `package:logging/logging.dart`, `package:uuid/uuid.dart`. Mirror the dartdoc style of existing public types in `workflow_cli_runner.dart` (one-line summary above each field).
  - **Verify**: `rg -n "^abstract class CliProvider" packages/dartclaw_server/lib/src/task/cli_provider.dart` returns 1; `rg -n "Future<WorkflowCliTurnResult> run\(CliTurnRequest" packages/dartclaw_server/lib/src/task/cli_provider.dart` returns 1; `dart analyze packages/dartclaw_server` clean.

- [ ] **TI02** New file `packages/dartclaw_server/lib/src/task/claude_cli_provider.dart` with `class ClaudeCliProvider implements CliProvider`. Owns: `_buildClaudeCommand(...)` (lifted verbatim from `workflow_cli_runner.dart:288-432` where Claude-specific), `_parseClaude(...)`, `_claudePermissionMode(Map<String, dynamic>)`, `_claudeSettings(...)`, plus the Claude branches of `_mapValue`/`_intValue`/`_previewText`/`_stringifyDynamicMap`/`_deepMergeInto` (or these stay on a shared helper if they're truly cross-provider; default: keep them on the provider that uses them, duplicate trivial helpers if needed — DRY can be retired in S34's cross-package consolidation pass). `run(CliTurnRequest req)` does the full Claude lifecycle: build command, spawn process via `req.processStarter`, drain stdout/stderr, parse, return `WorkflowCliTurnResult`. No event bus emission (Claude path doesn't emit progress events today).
  - Pattern reference: existing `_buildClaudeCommand` body and the Claude arm of `executeTurn` (`workflow_cli_runner.dart:158-285`).
  - **Verify**: `rg -n "^class ClaudeCliProvider implements CliProvider" packages/dartclaw_server/lib/src/task/claude_cli_provider.dart` returns 1; `dart analyze packages/dartclaw_server` clean; the Claude-specific arm of the existing test suite passes (`dart test packages/dartclaw_server/test/task/workflow_cli_runner_test.dart -n claude`).

- [ ] **TI03** New file `packages/dartclaw_server/lib/src/task/codex_cli_provider.dart` with `class CodexCliProvider implements CliProvider`. Owns: `_buildCodexCommand(...)`, `_parseCodex(...)`, `_handleCodexLine(...)`, `_CodexSandboxDecision`, `_CodexStreamState`, plus the temp-schema-file cleanup `try/finally` block (currently in `executeTurn` at lines 277-285). `run(CliTurnRequest req)` emits `WorkflowCliTurnProgressEvent` via `req.eventBus` exactly where `_handleCodexLine` does today. The `@visibleForTesting (String, List<String>) buildCodexCommandForTesting(...)` API on the runner becomes a forwarder: `WorkflowCliRunner.buildCodexCommandForTesting(...)` calls `(_providerImpls['codex'] as CodexCliProvider).buildCommandForTesting(...)`. Both signatures stay byte-identical so existing tests don't change.
  - Pattern reference: existing `_buildCodexCommand`, `_handleCodexLine`, `_CodexSandboxDecision`, `_CodexStreamState`, and the Codex arm of `executeTurn`. Note the temp-schema-file path: it's created inside `_buildCodexCommand` (returned via `_WorkflowCliCommand.tempSchemaPath`) and deleted in `executeTurn`'s `finally`. Both ends move into `CodexCliProvider.run`.
  - **Verify**: `rg -n "^class CodexCliProvider implements CliProvider" packages/dartclaw_server/lib/src/task/codex_cli_provider.dart` returns 1; `dart analyze packages/dartclaw_server` clean; the Codex arm of the existing test suite passes (`dart test packages/dartclaw_server/test/task/workflow_cli_runner_test.dart -n codex`).

- [ ] **TI04** `WorkflowCliRunner.executeTurn` collapses to a ≤60-LOC dispatcher. Body: validate `providers[provider]` (existing `StateError` preserved verbatim); resolve `containerManagers[profileId]`; construct `CliTurnRequest` from the method parameters + collaborators (`_processStarter`, `_eventBus`, `_uuid`, `_log`); look up `CliProvider impl = _providerImpls[provider]` (throw a same-shape `UnsupportedError('Workflow one-shot CLI is not implemented for provider "$provider"')` when missing — **same exception type and message as today**); return `await impl.run(req)`. The runner's `executeTurn` body must contain **zero** `'claude'` / `'codex'` string literals after this refactor — that's the structural proof of "no provider-specific branching". Constructor adds an optional `Map<String, CliProvider>? providerImpls` parameter; default factory: `_providerImpls = providerImpls ?? <String, CliProvider>{'claude': ClaudeCliProvider(), 'codex': CodexCliProvider()}`.
  - Pattern reference: keep `_startProcess` as either a runner-private method that providers reach via `req.processStarter`, or fold the helper into providers. Prefer the second (cleaner provider isolation), unless `_startProcess`'s container-manager hook is non-trivially shared — in which case keep it as a helper on the runner, hoisted into `CliTurnRequest` collaborators.
  - **Verify**: `awk '/^  Future<WorkflowCliTurnResult> executeTurn\(/,/^  \}/' packages/dartclaw_server/lib/src/task/workflow_cli_runner.dart | wc -l` ≤ 60; `rg -n "'claude'|'codex'" packages/dartclaw_server/lib/src/task/workflow_cli_runner.dart | grep -v "providerImpls\|throw" | rg -v "^[^:]*:[^:]*://" ` returns no matches inside `executeTurn` (a focused awk-extract of the method body and grep over it is acceptable).

- [ ] **TI05** Per-provider tests added where the existing test is implementation-agnostic. Concretely: where `workflow_cli_runner_test.dart` exercises a provider behaviour through `executeTurn` only, **leave it unchanged** (existing tests prove the integrated path). Add new direct-unit tests for `ClaudeCliProvider.run` and `CodexCliProvider.run` (or `buildCommand` if a smaller seam suffices) covering: (a) command vector for the basic happy path, (b) container-manager working-directory translation, (c) Codex sandbox-override resolution, (d) temp-schema-file lifecycle for Codex. Place the new tests in either the existing test file under a new `group('ClaudeCliProvider', () { ... })` / `group('CodexCliProvider', () { ... })` or sibling files `claude_cli_provider_test.dart` / `codex_cli_provider_test.dart` — pick whichever keeps the existing file's structure clean (sibling files preferred if the existing file is already over 1000 LOC).
  - **Verify**: `dart test packages/dartclaw_server/test/task/workflow_cli_runner_test.dart` passes (new tests included); `dart test packages/dartclaw_server/test/task/claude_cli_provider_test.dart` (or the new `group`) passes; same for codex.

- [ ] **TI06** "Adding a future provider requires no `WorkflowCliRunner` edit" is provable by grep. The `WorkflowCliRunner.executeTurn` body contains no provider-name string literals; the runner's class body contains no `case 'claude':` / `case 'codex':` switches; the only place provider names appear in `workflow_cli_runner.dart` is the default-factory line in the constructor (`{'claude': ClaudeCliProvider(), 'codex': CodexCliProvider()}`).
  - **Verify**: `rg -n "case '" packages/dartclaw_server/lib/src/task/workflow_cli_runner.dart` returns 0 matches; `rg -n "switch \(provider\)" packages/dartclaw_server/lib/src/task/workflow_cli_runner.dart` returns 0; `rg -c "'claude'|'codex'" packages/dartclaw_server/lib/src/task/workflow_cli_runner.dart` returns ≤ 2 (the two registry-default entries) plus possibly one allowlist comment.

- [ ] **TI07** Append a dated addendum section to **private repo** `docs/adrs/023-workflow-task-boundary.md` with heading `## Addendum — 2026-05 — \`WorkflowCliRunner\` Ownership` (note: append after the existing `## References` section, do **not** rewrite earlier sections). The addendum has three short paragraphs:
  1. **Decision**: `WorkflowCliRunner` remains in `dartclaw_server` as the concrete one-shot process adapter. Per-provider command construction, parsing, and temp-file lifecycle are isolated behind a `CliProvider` interface (also server-owned). Portable request/value types and reusable parsing/settings helpers move to `dartclaw_core` only when a second consumer appears.
  2. **Rationale**: The `ContainerExecutor` collaborator that providers depend on is server-owned (see `dartclaw_server/CLAUDE.md` boundary rule); a downward move would invert the package dependency graph. The `CliProvider` seam delivers the encapsulation goal (per-provider isolation, "new file, no runner edit" for future providers) without forcing a premature core promotion.
  3. **Out of scope for 0.16.5**: Full harness-dispatched rewrite (replacing `WorkflowCliRunner`'s one-shot process adapter with reuse of `AgentHarness` interactive-mode infrastructure). That rewrite remains a future option but is not part of 0.16.5's stabilisation theme.
  Add a public-repo cross-reference: a single line in `packages/dartclaw_server/CLAUDE.md` under the existing **Workflow glue** bullet of the **Boundaries** section, e.g. "Ownership decision recorded as a 2026-05 dated addendum to ADR-023 (private repo `docs/adrs/023-workflow-task-boundary.md`)." If `docs/guide/architecture.md` carries a workflow-runtime section, prefer that location; otherwise `CLAUDE.md` is the load-bearing canonical answer for contributors.
  - **Verify (private repo)**: `rg -n "^## Addendum — 2026-05 — \`WorkflowCliRunner\` Ownership" docs/adrs/023-workflow-task-boundary.md` returns 1 (in the private repo).
  - **Verify (public repo)**: `rg -n "ADR-023.*addendum|2026-05.*WorkflowCliRunner" packages/dartclaw_server/CLAUDE.md docs/guide/architecture.md 2>/dev/null` returns ≥1.

- [ ] **TI08** LOC verification: `wc -l packages/dartclaw_server/lib/src/task/workflow_cli_runner.dart` ≤ 400 (current 806; target ~350; ≤400 gives margin for the registry-default constructor). Per-provider files target ~200-250 LOC each. Record: `runner_before=806 runner_after=<N> claude_provider=<M> codex_provider=<P> cli_provider=<Q>` in the implementation observations or commit message.
  - **Verify**: `wc -l packages/dartclaw_server/lib/src/task/workflow_cli_runner.dart` returns ≤400; total LOC across the four files (`workflow_cli_runner.dart` + `cli_provider.dart` + `claude_cli_provider.dart` + `codex_cli_provider.dart`) may exceed 806 (acceptable — the goal is encapsulation, not raw LOC reduction).

- [ ] **TI09** Full validation: `dart format packages/dartclaw_server` produces no changes; `dart analyze --fatal-warnings --fatal-infos packages/dartclaw_server` clean; `dart test packages/dartclaw_server/test/task/workflow_cli_runner_test.dart` and any sibling provider test files all green; workspace-wide `dart analyze` clean (binding constraint — strict-casts/strict-raw-types maintained).
  - **Verify**: All four commands exit 0; PR diff shows zero edits to existing test assertions in `workflow_cli_runner_test.dart` (only additions, if any).

### Testing Strategy

- [TI02] Scenario "Workflow one-shot invokes Claude — output byte-identical" → existing Claude tests in `workflow_cli_runner_test.dart` (no new assertions; existing tests are the proof)
- [TI03] Scenario "Workflow one-shot invokes Codex — output byte-identical" → existing Codex tests in `workflow_cli_runner_test.dart` plus the existing sandbox-resolution tests
- [TI04,TI06] Scenario "Adding a third provider requires no `WorkflowCliRunner` edit" → grep-based structural proof (TI06 Verify line) + a new test (in TI05) that constructs `WorkflowCliRunner(providerImpls: {'fake': FakeCliProvider()})` and asserts `executeTurn(provider: 'fake', ...)` routes correctly without touching `workflow_cli_runner.dart`
- [TI04] Scenario "Per-provider command construction stays inside the provider" → covered by TI06 grep (`rg "'claude'|'codex'"` on the runner) plus by TI02/TI03's Claude/Codex provider tests demonstrating that command-vector assertions live in the provider tests, not the runner tests
- [TI04] Scenario "Unknown provider error path" → existing test in `workflow_cli_runner_test.dart` asserting `StateError('No workflow CLI provider config for "xyz"')` continues to pass byte-identically
- [TI09] Scenario "Existing workflow_cli_runner_test suite passes byte-identically" → `dart test` exit 0 with zero diff to existing assertions

### Validation

Standard validation (build/test, analyze, format, code review) is sufficient. No feature-specific validation needed — this is a mechanical refactor with the existing test suite as the proof-of-work.

### Execution Contract

- Implement tasks in listed order. Each **Verify** line must pass before proceeding to the next task.
- Prescriptive details (file paths, error messages, identifier names) are exact — implement them verbatim.
- Proactively use sub-agents for non-coding needs (none expected for this story; possibly a documentation-lookup sub-agent if any external API doc is needed for Codex stream-event semantics, but the existing implementation is the reference).
- After all tasks: `dart format packages/dartclaw_server`, `dart analyze --fatal-warnings --fatal-infos packages/dartclaw_server`, `dart test packages/dartclaw_server` all green; `rg "TODO|FIXME|placeholder|not.implemented" packages/dartclaw_server/lib/src/task/cli_provider.dart packages/dartclaw_server/lib/src/task/claude_cli_provider.dart packages/dartclaw_server/lib/src/task/codex_cli_provider.dart packages/dartclaw_server/lib/src/task/workflow_cli_runner.dart` empty.
- Mark task checkboxes immediately upon completion — do not batch.


## Final Validation Checklist

- [ ] **All success criteria** met (each one mapped to a Scenario or Verify line)
- [ ] **All tasks** TI01–TI09 fully completed, verified, and checkboxes checked
- [ ] **No regressions**: zero edits to existing test assertions in `workflow_cli_runner_test.dart`; only additions allowed
- [ ] **`workflow_cli_runner.dart` ≤400 LOC** (target ~350) with `executeTurn` body ≤60 LOC and zero provider-name string literals inside the method body
- [ ] **`CliProvider` interface + `ClaudeCliProvider` + `CodexCliProvider`** all present in `dartclaw_server`; future provider addition requires only a new file
- [ ] **ADR-023 dated addendum** exists in private repo; public-repo cross-reference exists in `packages/dartclaw_server/CLAUDE.md` (or `docs/guide/architecture.md`)
- [ ] **Workspace `dart analyze` + `dart format` + `dart test packages/dartclaw_server`** all green


## Implementation Observations

> _Managed by exec-spec post-implementation — append-only._

_No observations recorded yet._

---

## Plan-format migration addendum (2026-05-06)

> Migrated from the pre-template `plan.md` story body during the plan-template reformat. Verbatim copy of the plan's `**Acceptance Criteria**`, `**Key Scenarios**`, and any detailed `**Scope**` paragraphs not already represented above. Authoritative spec content lives in this FIS; the plan now carries only a 1-2 sentence Scope summary plus catalog metadata.

### From plan.md — Scope detail (migrated from old plan format)

**Scope**: `packages/dartclaw_server/lib/src/task/workflow_cli_runner.dart` grew from 515 → 635 LOC during 0.16.4 as Codex support matured; `executeTurn` now has 11 optional parameters and a per-provider switch that mixes process lifecycle, provider-specific command construction, and temp-file management. Introduce `abstract class CliProvider { Future<WorkflowCliTurnResult> run(CliTurnRequest request); }` plus `ClaudeCliProvider` and `CodexCliProvider` implementations. Each implementation owns its `_buildXxxCommand` logic (working-dir translation, container mount wiring, provider-specific stdin/stdout parsing) and temp-file cleanup. `WorkflowCliRunner.executeTurn` becomes a dispatcher on `Map<String, CliProvider>`. Keep `_WorkflowCliCommand` private helper type if still needed, or promote it to a `CliTurnRequest` value object. As part of TD-070, record the ownership decision explicitly: `WorkflowCliRunner` remains in `dartclaw_server` for now as the concrete one-shot process adapter, while portable request/value types and reusable parsing/settings helpers move to `dartclaw_core`; a full harness-dispatched rewrite remains out of scope.

### From plan.md — Acceptance Criteria addendum (migrated from old plan format)

**Acceptance Criteria**:
- [ ] `CliProvider` interface exists with `ClaudeCliProvider`/`CodexCliProvider` implementations (must-be-TRUE)
- [ ] `WorkflowCliRunner.executeTurn` ≤60 LOC and contains no provider-specific branching (must-be-TRUE)
- [ ] Ownership decision documented as a dated addendum section appended to `docs/adrs/023-workflow-task-boundary.md` (private repo; the canonical ADR-023 location): runner remains server-owned concrete adapter; core owns portable request/value/helper types; addendum is cross-referenced from public-repo `docs/architecture/workflow-architecture.md` so public readers can find it (must-be-TRUE)
- [ ] `workflow_cli_runner.dart` total LOC reduced from ~635 toward ~350 (must-be-TRUE)
- [ ] `dart test packages/dartclaw_server/test/task/workflow_cli_runner_test.dart` passes; add a per-provider test where the existing test is implementation-agnostic
- [ ] Adding a future provider (e.g. Ollama) requires adding only a new `CliProvider` class — no edits to `WorkflowCliRunner` itself
