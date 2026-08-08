# Agent Persona and Model Application on the Delegation Dispatch Path

**Plan**: docs/specs/0.24/plan.json
**Story-ID**: S02

> Standalone FIS. Origin: adjacent defect recorded in `s01-agent-tool-policy-enforcement-on-the-live-tool-call-path.md` (this directory), runtime-confirmed 2026-08-05 via a FakeAgentHarness probe against a real `TurnRunner` and the verbatim `harness_wiring` dispatch closure – a `sessions_send('search', ...)` turn reached `AgentHarness.turn` with `model: null`, `effort: null`, and the MAIN behavior prompt (SOUL.md composition); `AgentDefinition.prompt` was entirely absent. Target: **0.24**. Execution repo: `dartclaw-public` – all paths relative to its root; anchors pinned at commit `584db0c1`.

## Feature Overview and Goal

**Intent**: The per-agent `prompt` and `model` config keys that `docs/guide/agents.md` advertises (plus the parsed-but-undocumented `effort`) are provider-side fiction on the DartClaw-dispatched delegation path – a delegated sub-agent turn today runs as the main persona on the default model; applying the definition at dispatch makes the configured sub-agent identity real and the config surface honest.

**Expected Outcomes**:

- [OC01] A `sessions_send` delegated turn runs under the agent definition's persona prompt on every harness, and under its configured `model`/`effort` on Claude and Codex – observable at the harness boundary and in the provider spawn/turn parameters. ACP receives the persona per-turn as a message-level prepend (the transport ACP offers); `AcpHarness` accepts and ignores `model`/`effort` today, and applying them there is out of scope.
- [OC02] Delegation is reachable while the caller's turn is active: the delegated turn executes on an idle task-pool worker (never the caller's busy harness), and when no worker is available the main agent receives a clear inline error instead of a wedged or hijacked turn.
- [OC03] Main-agent and task turns outside active onboarding are unchanged: no persona or model leaks into subsequent turns on the same runner, and ordinary turns trigger no additional harness restarts.
- [OC04] Delegated turns retain diagnosable session history without appearing in normal interactive-session surfaces or becoming permanently protected from retention cleanup.
- [OC05] A fresh `ONBOARDING.md` reaches every human-facing conversational channel – web chat, configured messaging channels, and the future REPL seam – on every harness, while automated and delegated turns remain onboarding-free.

## Required Context

### From `s01-agent-tool-policy-enforcement-on-the-live-tool-call-path.md` – "Adjacent defects surfaced" (sibling FIS, this directory)
<!-- source: docs/specs/0.24/s01-agent-tool-policy-enforcement-on-the-live-tool-call-path.md#adjacent-defects-surfaced-out-of-scope-do-not-fix-here -->
<!-- extracted: 2026-08-05 -->
> `AgentDefinition.prompt`/`model` appear unapplied on the `sessions_send` dispatch path: the delegated turn runs with the default behavior prompt and default model (`TurnRunner._buildSystemPrompt` reads behavior only; dispatch passes no `model`/`behaviorOverride`); the definition's prompt/model reach only the Claude-native `agents` handshake. Needs its own verification + spec.

Verification is complete (probe, 2026-08-05); this FIS is that spec.

### From `s01-agent-tool-policy-enforcement-on-the-live-tool-call-path.md` – "Testing Strategy" (reachability handoff)
<!-- source: docs/specs/0.24/s01-agent-tool-policy-enforcement-on-the-live-tool-call-path.md#testing-strategy -->
<!-- extracted: 2026-08-05 -->
> Delegated-dispatch reachability: verify end-to-end that a `sessions_send` delegated turn reaches a harness while the caller's turn is active (primary busy; `TurnManager` runner routing) before treating S01's live path as proven – the harness-level unit tests alone do not prove dispatch.

Code-level analysis for this FIS concludes reachability is broken today on the default path: the delegated session is created without `provider` (`SessionService.getOrCreateByKey`), `TurnManager._reserveRunnerForSession` therefore returns the primary runner, and `ClaudeCodeHarness.turn` throws `Harness is not idle` while the caller's turn holds it busy. The fix lands here (TI05), honoring the sibling FIS's non-goal ("Not changing … `SessionDelegate` dispatch flow").

### From `docs/guide/agents.md` – "Subagent Configuration Reference" (the promise being made real)
<!-- source: docs/guide/agents.md#subagent-configuration-reference -->
<!-- extracted: 584db0c1 -->
> | `prompt` | *(search prompt)* | System prompt for the subagent |
> | `model` | *(global agent.model)* | Model override for this subagent |
>
> The only pre-built subagent is `search` — a web search agent with `WebSearch` and `WebFetch` tools only. It defaults to the `haiku` model for cost efficiency.

The fixed `haiku` statement is superseded by the preflight decision: an omitted search model resolves to `sonnet` on Claude and `gpt-5.6-luna` on Codex; explicit configuration still wins.

## Deeper Context

- `docs/specs/0.24/s01-agent-tool-policy-enforcement-on-the-live-tool-call-path.md#implementation-plan` – sibling FIS that **must land first**; its TI03 adds `agentId` to `AgentHarness.turn` and sweeps ~23 implementer/fake files. This FIS touches the same interface and the same dispatch closure – see Execution Contract.
- `dev/architecture/control-protocol.md#41-initialize-handshake` – the `agents` initialize payload feeds only the claude binary's own native subagent spawns; there is no per-turn "run as agent X" addressing in the turn request (`ClaudeProtocolAdapter.buildTurnRequest`: message/system_prompt/resume only).
- `dev/state/DECISIONS.md` (Still Current, 2026-08-05: "Built-in `search` agent keeps its name") – do not touch agent naming.
- `docs/guide/agents.md#how-delegation-works` + `#content-guard-boundary` – delegation flow and result-scanning boundary; both unchanged by this FIS.

## Acceptance Scenarios

- [ ] **S01 [OC01] [TI01,TI02,TI03,TI04] Delegated search turn uses the Claude search default**
  - **Given** the default agent config (built-in `search` agent: web-search persona, no explicit model) and an idle Claude pool worker
  - **When** `SessionDelegate.handleSessionsSend` dispatches a delegated turn for agent `search`
  - **Then** `AgentHarness.turn` receives `systemPrompt` equal to `AgentDefinition.prompt` verbatim (no SOUL/USER/TOOLS/MEMORY composition), `model: 'sonnet'`, and the Claude worker process is (re)started with `--append-system-prompt <persona>` and `--model sonnet` in a single restart

- [ ] **S02 [OC01] [TI01,TI02,TI03] Custom agent config keys are honored on the dispatch path**
  - **Given** a custom agent parsed from YAML: `summarizer` with an explicit `prompt` and `model: sonnet`
  - **When** a delegated turn for `summarizer` is dispatched
  - **Then** the harness receives the summarizer's prompt verbatim and `model: 'sonnet'`; for a non-search agent whose YAML sets no `model`, the harness receives `model: null` and remains on the configured provider default; a configured `search` entry with no model receives the same provider-aware default as the built-in definition

- [ ] **S03 [OC02] [TI05] Delegation reaches a pool worker while the caller's turn is active**
  - **Given** the primary harness is mid-turn (the caller) and task-pool capacity for the default provider is available (an idle worker, or a spawnable slot on a fresh pool)
  - **When** the caller's turn invokes `sessions_send('search', ...)`
  - **Then** the delegated turn executes on the pool worker (never the busy primary), completes, and its result returns inline to the caller's turn

- [ ] **S04 [OC02] [TI05] No idle worker yields a clear inline error, not a wedge**
  - **Given** the primary is busy and no task-pool worker exists or can be spawned for the default provider (e.g. `tasks.max_concurrent: 0`)
  - **When** `sessions_send('search', ...)` is invoked
  - **Then** the main agent receives an `isError` result whose text names the unavailable provider pool (actionable toward `tasks.max_concurrent`/`providers.<id>.pool_size`), the caller's turn continues, and the primary harness is never restarted or contended

- [ ] **S05 [OC03] [TI02,TI04] No persona/model residue on the next turn of the same worker**
  - **Given** a pool worker that just completed a delegated Claude `search` turn (persona append prompt, sonnet)
  - **When** the next ordinary task turn runs on that worker with empty `systemPrompt` and no model override
  - **Then** the worker is restored to the configured static append prompt and configured model (restart-if-differs fires exactly once for the restore), and the task turn's observable behavior matches today's

- [ ] **S06 [OC03] [TI02,TI04] Ordinary interactive turns are byte-identical and restart-free**
  - **Given** the primary harness running main-session turns with no fresh onboarding sentinel (append strategy, empty per-turn `systemPrompt`)
  - **When** consecutive main turns execute
  - **Then** `_buildSystemPrompt` composes exactly as today (behavior files, memory, compact instructions), no `_restartForExecution` is triggered by prompt comparison, and existing `turn_runner_test.dart` assertions pass unchanged

- [ ] **S07 [OC01] [TI06] Codex and ACP delegated turns carry the persona and model**
  - **Given** a `search` definition with no explicit model dispatched to a Codex pool worker, and separately a delegated turn dispatched to an ACP worker
  - **When** the harness executes the turn
  - **Then** Codex: the fresh delegated `thread/start` carries `developerInstructions: <persona>` and `turn/start` carries `model: gpt-5.6-luna` plus any configured effort, with no App Server restart or `config.toml` rewrite; ACP: the per-turn `systemPrompt` equals the persona (existing pass-through – delivered as a message-level prepend via `_promptText`, weaker isolation than a true system prompt, accepted for ACP; `model`/`effort` are not applied on ACP)

- [ ] **S08 [OC04] [TI05] Delegated session history is hidden but retained and prunable**
  - **Given** a completed delegated turn whose session is `SessionType.delegated`
  - **When** normal session/sidebar listing runs, an explicit delegated-type query runs, and maintenance evaluates the session after its retention cutoff
  - **Then** the normal listing omits it, the explicit query returns it for diagnostics, and maintenance archives it using the existing configured retention path; the type is not in `SessionService.protectedTypes`

- [ ] **S09 [OC05] [TI02,TI04,TI06,TI07] Onboarding follows the human conversation, not the transport**
  - **Given** a fresh `ONBOARDING.md` and turns arriving through web chat, each configured messaging-channel dispatcher, an automated schedule, and a delegated agent
  - **When** those turns reach Claude, Codex, or ACP
  - **Then** each human-facing turn receives the full conversational prompt including `ONBOARDING.md`; automated and delegated turns do not; completing or expiring onboarding restores the configured default prompt on the next turn without leaking onboarding across sessions or channels

## Structural Criteria

- [ ] `AgentHarness.turn`'s `systemPrompt` contract is explicit in its dartdoc: non-empty = the authoritative scoped system prompt for this turn on every prompt strategy; empty = the harness's configured default. No implementer silently drops a non-empty persona or onboarding prompt.
- [ ] The Claude restart comparison treats empty per-turn `systemPrompt` as "configured default" – `rg`-provable absence of restarts in the existing interactive-turn test suites (no test needs a new restart expectation).
- [ ] `SessionDelegate` public API (`handleSessionsSend` params/result shape) and the content-guard boundary are unchanged.
- [ ] Signature coordination: this FIS's `AgentHarness.turn` edits build on the sibling FIS's landed `agentId` parameter (or, if executed first, leave a rebase note); the implementer sweep uses the sibling's `rg -n "implements AgentHarness|extends AgentHarness"` inventory.
- [ ] `docs/guide/agents.md`, `docs/guide/search.md`, and `dev/architecture/control-protocol.md` describe the shipped mechanism (persona replaces behavior composition for delegated turns; pool-worker routing; per-provider prompt mechanisms); no doc claims the definition prompt/model apply where they don't.
- [ ] `SessionType.delegated` is hidden by default but explicitly queryable, and maintenance opts into listing it; no session-key prefix parsing determines lifecycle. (Proved by TI05 Verify.)
- [ ] Search model defaults are resolved once from the effective provider family and reused by both Claude's native agents payload and DartClaw delegation; no duplicated provider checks or new YAML model-map shape. (Proved by TI03 Verify.)
- [ ] Workspace-wide `dart analyze` + `dart test` pass (package-scoped analyze hides cross-package breaks from the interface change).

## Scope & Boundaries

### Work Areas

- `apps/dartclaw_cli` – `harness_wiring.dart` dispatch closure: resolve the `AgentDefinition`, pass `model`/`effort`/persona into `startTurn`, create the delegated session with a `provider` so pool routing engages. **This file is being edited by the sibling FIS right now – rebase, don't anchor to 584db0c1 line numbers.**
- `apps/dartclaw_cli` + `dartclaw_config` – web and channel dispatch mark human conversations with one transport-neutral prompt scope; a future REPL reuses that scope. Scheduled/automated dispatch keeps its non-onboarding scope.
- `dartclaw_server` – `TurnRunner`/`TurnManager`: per-turn persona override on `TurnContext` threaded through `reserveTurn`/`startTurn`; `_buildSystemPrompt` returns it verbatim (bypassing behavior composition and the append-strategy short-circuit). The `reserveTurn`/`startTurn` signatures live on the `dartclaw_core` `TurnManager` interface (`packages/dartclaw_core/lib/src/turn/turn_manager.dart`) – the new parameter lands there first, then in the server implementations, `dartclaw_testing`'s `FakeTurnManager`, and the server test-support fakes.
- `dartclaw_core` – harness contract + implementations: `AgentHarness.turn` dartdoc contract; `ClaudeCodeHarness` restart-if-differs extended to the append prompt; `CodexHarness`/`CodexProtocolAdapter` persona seam; ACP verified pass-through.
- `dartclaw_models` + `dartclaw_core` – `SessionType.delegated`; `SessionService.listSessions` default-hidden/explicit-query behavior and deletion protection.
- `dartclaw_models` + `dartclaw_config` – provider-neutral search definition default plus recognition of the documented Codex default model ID.
- `dartclaw_server` – session maintenance explicitly includes delegated sessions; sidebar/API defaults remain free of them.
- `dartclaw_testing` + package-local fakes – `FakeAgentHarness` and the sibling FIS's fake inventory updated for any contract/signature change.
- Docs – `docs/guide/agents.md`, `docs/guide/search.md`, `dev/architecture/control-protocol.md`, touched package `AGENTS.md` files.
- Onboarding docs – `docs/guide/workspace.md`, `docs/guide/getting-started.md`, and prompt-scope architecture describe channel-neutral conversational onboarding.

### What We're NOT Doing

- **No tool-allowlist enforcement** – owned by the in-flight sibling FIS (`s01-agent-tool-policy-enforcement-on-the-live-tool-call-path.md`); this FIS only makes persona/model real.
- **No per-agent `provider` field** – delegated sessions use the global default provider's pool; a per-agent provider is speculative (YAGNI) and adds a routing matrix nobody asked for.
- **No one-shot CLI execution for delegation** – delegated turns stay on the long-lived streaming harnesses per `dev/architecture/control-protocol.md#workflow-one-shot-exception` ("Interactive chat, channels, cron, and ordinary task turns remain on the long-lived streaming harnesses"); revisiting that boundary is an ADR-sized decision, not a defect fix.
- **No claude-native `agents`-payload turn addressing** – the protocol has no per-turn agent selector; the initialize payload stays as provider-side defense-in-depth for native Task spawns.
- **No ACP `model`/`effort` application** – `AcpHarness.turn` accepts and ignores both today; wiring them is new ACP work outside this defect fix (OC01 scopes model/effort to Claude and Codex).
- **No immediate deletion of delegated sessions** – they retain diagnostics and use existing configured maintenance; no bespoke cleanup timer or session-key heuristic.
- **No REPL implementation** – this FIS provides a transport-neutral conversational scope that a future REPL can select; it does not build the REPL.
- **Not changing the default-prompt oddity** – `AgentDefinition.fromYaml` falls back to the *search* persona for any agent without a `prompt` (documented in the config table as "*(search prompt)*"). This FIS makes that documented default live for the first time; changing the fallback is a separate product decision. TI07 makes the doc wording unmissable.

## Architecture Decision

**Approach**: Thread the definition through the existing turn seams – the dispatch closure resolves the `AgentDefinition` and passes model/effort plus a new `TurnContext` persona override into `startTurn`; `_buildSystemPrompt` returns the persona verbatim for delegated turns; `AgentHarness.turn` gains an explicit contract that a non-empty `systemPrompt` is authoritative on every strategy. Preserve the same seam for fresh onboarding, replacing the web-specific scope with one human-conversational scope selected by web, configured messaging channels, and a future REPL. One composition-root helper resolves an omitted search model from the effective provider family (`sonnet` for Claude, `gpt-5.6-luna` for Codex) and feeds both the native agents payload and DartClaw dispatch. Create the provider-pinned session as `SessionType.delegated` so pool routing, hidden diagnostics, and ordinary retention are explicit domain behavior.
**Why this over alternatives**: every leg reuses a proven seam (per-task model restarts, provider-pinned session routing, replace-strategy prompt pass-through) – the alternatives (message-level persona injection, a dedicated subagent harness, one-shot CLI spawns) either weaken the persona to a prompt suggestion or add new infrastructure for a defect fix.

## Technical Overview

Flow after this change: `SessionDelegate.handleSessionsSend` → dispatch resolves `AgentDefinition` and effective provider family → explicit model or search default (`sonnet`/`gpt-5.6-luna`) → `getOrCreateByKey(sessionId, type: delegated, provider: <default provider>)` → `TurnManager.startTurn(..., agentName, model: resolvedModel, effort: def.effort, systemPromptOverride: def.prompt)` → pool acquisition → `_worker.turn(systemPrompt: persona, model, effort)` → Claude: one restart applying persona + `sonnet`; Codex: `thread/start.developerInstructions` + `turn/start.model: gpt-5.6-luna`; ACP: per-turn prepend and unchanged model behavior. The next non-delegated turn restores configured defaults. The delegated session remains explicitly queryable and later follows normal maintenance retention.

## Code Patterns & External References

```
# type | path#anchor or url                                                              | why needed (intent)
file   | apps/dartclaw_cli/lib/src/commands/wiring/harness_wiring.dart#SessionDelegate   | The dispatch closure to extend (session create + startTurn call) – under concurrent edit, rebase first
file   | apps/dartclaw_cli/lib/src/commands/wiring/channel_wiring.dart#_dispatchChannelTurn | Messaging-channel entry point that selects the conversational onboarding scope
file   | packages/dartclaw_config/lib/src/prompt_scope.dart#PromptScope                  | Rename the web-only onboarding scope to the transport-neutral conversational scope
file   | packages/dartclaw_server/lib/src/turn_runner.dart#_buildSystemPrompt            | Prompt composition to short-circuit with the persona override
file   | packages/dartclaw_server/lib/src/turn_runner.dart#reserveTurn                   | TurnContext population – where the override field lands
file   | packages/dartclaw_server/lib/src/turn_manager.dart#_reserveRunnerForSession     | Provider-pinned pool routing seam (session.provider → tryAcquireForProvider)
file   | packages/dartclaw_core/lib/src/harness/claude_code_harness.dart#turn            | restart-if-differs comparison (model/effort/directory) to extend with the append prompt
file   | packages/dartclaw_core/lib/src/harness/codex_harness.dart#_startThread           | Thread-scoped `developerInstructions` persona seam; turn/start model/effort remain dynamic
file   | packages/dartclaw_core/lib/src/storage/session_service.dart#getOrCreateByKey    | provider param already exists – dispatch just passes it
file   | packages/dartclaw_models/lib/src/models.dart#SessionType                        | Explicit delegated lifecycle classification
file   | packages/dartclaw_config/lib/src/provider_identity.dart#ProviderIdentity        | Existing effective provider-family resolution for search defaults
file   | packages/dartclaw_server/lib/src/maintenance/session_maintenance_service.dart   | Retention must include default-hidden delegated sessions
file   | packages/dartclaw_testing/lib/src/fake_agent_harness.dart#FakeAgentHarness      | Records lastSystemPrompt/lastModel/lastEffort – the probe/assert surface
url    | https://developers.openai.com/codex/cli                                         | Codex app-server: confirm the per-turn vs config.toml `developer_instructions` shape for TI06
url    | https://agentclientprotocol.com/protocol/v1/schema                              | Stable ACP request fields – no system/developer/persona channel
url    | https://agentclientprotocol.com/protocol/v1/session-config-options              | ACP config/mode selectors are agent-advertised options, not arbitrary instructions
```

## Constraints & Gotchas

- **One restart, not two**: persona and model changes on Claude must land in a single `_restartForExecution` call – compare all desired values (append prompt, model, effort, directory, maxTurns) before restarting. A persona-then-model double restart doubles delegation latency and churns the provider process.
- **Append ≠ replace on Claude**: `--append-system-prompt` appends the persona to the claude binary's own base system prompt – identical posture to the main behavior prompt today. Docs must not claim full prompt replacement on Claude.
- **Empty means default everywhere**: `''`/absent per-turn `systemPrompt` must map to "configured default" in every harness comparison – otherwise every ordinary turn restarts the worker (S06 guards this). The same rule binds the dispatch: pass the persona override only when `def.prompt.trim().isNotEmpty` (a YAML `prompt: ""` or whitespace-only prompt is *unset* – override `null`); "override is set" in TI02 means non-null and non-empty after trim, and harness comparisons use the trimmed value.
- **Onboarding is conversational, not globally interactive**: do not make `PromptScope.interactive` onboarding-eligible because it also serves cron today. Rename `webInteractive` to a transport-neutral conversational scope and select it explicitly from web and messaging-channel entry points; future REPL wiring selects the same value.
- **Sibling FIS ordering**: `s01-agent-tool-policy-enforcement-on-the-live-tool-call-path.md` edits `harness_wiring.dart`, `guard.dart`, and the `AgentHarness.turn` signature (its TI03 adds `agentId`; its sweep covers ~23 implementer/fake files). Execute this FIS only after that work lands; re-resolve every anchor against the then-current tree before starting.
- **Pool-required posture** (ratified 2026-08-06): delegation requires task-pool capacity for the default provider and never uses the caller's primary harness. TI05 extends the existing `TaskRunnerPoolCoordinator` with one awaitable provider provision-then-acquire path: no idle match + spawnable capacity triggers a serialized spawn, including when existing workers are busy; concurrent callers await the same in-flight provision rather than racing duplicate spawns. `tasks.max_concurrent: 0`, exhausted capacity, or failed provisioning yields S04's inline error.
- **Persona turns skip memory/behavior composition deliberately** – do not "helpfully" append MEMORY.md or TOOLS.md to sub-agent personas; isolation is the point and the content-guard boundary assumes it.
- **Nested delegation goes live – for fail-open agents only**: a delegated turn can call `sessions_send` again, but only when the delegated agent has no tool allowlist (fail-open) or an allowlist including the MCP surface – sandboxed agents (configured `tools`, e.g. the default `search`) are blocked from `sessions_send` by the sibling FIS's closed-set enforcement (its S04). Where it applies, recursion is bounded by the `'main'`-keyed `SubagentLimits` children cap (summed `max_concurrent`) and pool capacity, never by the per-agent depth fields (`SessionDelegate` hardcodes `parentAgentId: 'main', currentDepth: 0`; the sibling FIS retires those fields as unenforced). No enforcement change here – recorded so the bound is a known quantity.
- **Cancellation does not propagate**: cancelling the caller's turn does not cancel an in-flight delegated turn (separate session, separate runner – it completes and the result is discarded); a stalled delegated turn holds its pool worker and blocks the caller's `sessions_send` call until the pool harness's `turnTimeout` backstop fires. Accepted for this defect fix – no new propagation machinery.
- **Provider-aware search default**: `AgentDefinition` remains provider-neutral. At wiring, resolve the actual provider family through the existing `ProviderIdentity` seam; an omitted `search.model` becomes `sonnet` for Claude or `gpt-5.6-luna` for Codex. Explicit model wins, non-search omission remains null, and unknown/ACP-only families retain existing provider behavior. Use the same helper for native payload and dispatch so the two delegation mechanisms cannot drift.
- **ACP prompt authority is weaker** (ratified 2026-08-06): ACP v1 and draft v2 have no interoperable system/developer/persona field. Preserve the existing persona/onboarding-before-user-text prepend, document it as message-level guidance, and do not invent `_meta` semantics or map arbitrary personas onto agent-advertised modes.

## Implementation Plan

### Implementation Tasks

- [ ] **TI01** `TurnContext` carries a per-turn persona override; `reserveTurn`/`startTurn` (TurnRunner and the TurnManager passthrough) expose it
  - Mirror the existing `model`/`effort` threading (`turn_runner.dart#reserveTurn`, `turn_manager.dart#startTurn`); name it for what it is (persona/system-prompt override), not `behaviorOverride` (that slot is the task-scoped `BehaviorFileService`); the parameter is added on the `dartclaw_core` `TurnManager` interface and every implementer/fake (`FakeTurnManager`, server test-support fakes) – "call sites compile unchanged" holds for callers, not implementers
  - **Verify**: `Test: startTurn(..., systemPromptOverride: 'P') reaches TurnContext; omitted → null; existing reserveTurn call sites compile unchanged`

- [ ] **TI02** `TurnRunner._buildSystemPrompt` returns the authoritative scoped prompt for every prompt strategy
  - A persona override returns verbatim and bypasses behavior composition; no memory/AGENTS content is attached to delegated personas. Without a persona, preserve the fresh-onboarding path but make its scope transport-neutral: web and configured messaging-channel entry points select the renamed conversational scope, which composes the normal interactive static prompt plus `ONBOARDING.md`; tasks, cron, workflows, evaluators, and delegated agents never select it. Append-strategy harnesses must receive this non-empty value instead of dropping it.
  - **Verify**: `Test: override 'P' reaches append- and replace-strategy fakes verbatim; fresh onboarding reaches web and channel conversational turns on both strategies; task/restricted/evaluator/delegated and scheduled interactive turns exclude it; no-sentinel turns retain existing prompt assertions [S06,S09]`

- [ ] **TI03** The delegation dispatch applies the resolved `AgentDefinition` (persona, model, effort)
  - `harness_wiring.dart` resolves the effective provider family once, then one helper returns `def.model` when explicit, `sonnet`/`gpt-5.6-luna` for an omitted search model on Claude/Codex, otherwise null. Use it both when constructing Claude's `agentsPayload` and in the dispatch closure; pass the resolved model, `def.effort`, and the nonblank persona into `startTurn`. Make `AgentDefinition.searchAgent()` provider-neutral rather than retaining a hidden `haiku` default, and recognize `gpt-5.6-luna` in config model advisories.
  - **Verify**: `Test: built-in and fromYaml search definitions with no model resolve to sonnet under Claude and gpt-5.6-luna under Codex in both agents payload and dispatch; explicit model wins; a non-search omission stays null; custom provider aliases resolve through ProviderIdentity; no haiku search default remains [S01,S02,S07].`

- [ ] **TI04** `ClaudeCodeHarness` honors a non-empty per-turn `systemPrompt` under the append strategy via restart-if-differs; empty restores the configured default
  - Extend the `turn()` desired-state comparison (`claude_code_harness.dart#turn`) with the effective append prompt (non-empty param, else `harnessConfig.appendSystemPrompt`); spawn args use the effective value; single restart covers prompt+model+effort together; the first-use adoption block stays model/effort-only and never suppresses a persona-driven restart (a persona restart carries all desired values in the same comparison); document the contract in `AgentHarness.turn` dartdoc
  - **Verify**: `Test: turn(systemPrompt: 'P', model: 'sonnet') on an idle harness restarts once with --append-system-prompt P and --model sonnet [S01]; a conversational onboarding prompt uses the same single-restart seam [S09]; the next empty/default turn restarts once back to configured prompt/model [S05,S09]; consecutive empty-prompt turns trigger zero restarts [S06]`

- [ ] **TI05** Delegated sessions route to an idle pool worker; unavailability surfaces as a clear inline delegation error
  - Dispatch passes `type: SessionType.delegated` and `provider: <default provider id>` to `getOrCreateByKey`. Extend `TaskRunnerPoolCoordinator` with a provider-generic awaitable provision-then-acquire method and use it from delegation/TurnManager rather than adding a second `_isSpawning` flag or raw callback race in `HarnessWiring`. It first acquires an idle matching runner; otherwise, if capacity remains, it coalesces callers onto one in-flight spawn, then retries acquisition. Busy matching runners plus spare capacity also trigger expansion. Only zero/exhausted capacity, spawn failure, or no acquired runner after provisioning returns S04; primary is never eligible. Existing task acquisition keeps its queue semantics through the same coordinator. Separately, `SessionService.listSessions` hides delegated sessions by default but returns them by explicit type/internal include; maintenance includes them and deletion protection does not.
  - **Verify**: `Test: busy primary + idle worker completes on worker [S03]; fresh pool + capacity spawns once then completes; two concurrent first delegations coalesce provisioning and do not exceed capacity; all matching workers busy + spare capacity spawns another; no capacity or failed spawn returns actionable error and never uses primary [S04]. Existing task coordinator tests remain green. Created session is delegated; default lists omit it, explicit query returns it, deletion protection excludes it, maintenance archives after cutoff [S08].`

- [ ] **TI06** Codex thread startup carries scoped instructions; Codex turn startup carries model/effort; ACP pass-through is pinned by test
  - Thread a non-empty persona or onboarding prompt into `CodexHarness._startThread` as stable App Server `thread/start.params.developerInstructions`. Track the effective instructions per session: when they change between onboarding and the configured default, replace that session's thread and reuse existing history replay rather than restarting the App Server or rewriting `config.toml`. Keep `turn/start.model` and add/verify `turn/start.effort`. ACP needs no mechanism change – retain `_promptText` message-level prepend and add persona/onboarding assertions. Update request-shape tests against the installed schema; if the deployed Codex binary lacks the stable thread field, fail clearly instead of silently dropping instructions.
  - **Verify**: `Test: delegated Codex thread/start contains persona byte-equal and turn/start contains model/effort [S07]; a conversational onboarding thread contains the full scoped prompt, then completion/expiry starts one replacement thread with configured defaults and replayed history [S09]; other sessions and automated turns never receive onboarding; no config write or App Server restart occurs; ACP receives both scoped prompt forms`

- [ ] **TI07** Docs describe the shipped mechanism
  - `docs/guide/agents.md`: config-reference rows for `prompt`/`model`/`effort`, provider-aware search defaults (`sonnet` Claude, `gpt-5.6-luna` Codex), pool-worker requirement/S04 error, delegated-session visibility/retention, and the missing-prompt fallback; remove every claim that search defaults to haiku or is necessarily "cheap". `docs/guide/search.md` and recipes/examples align; `docs/guide/workspace.md` and `docs/guide/getting-started.md` describe onboarding across human-facing channels rather than web-only; `dev/architecture/control-protocol.md` documents the turn prompt contract; session architecture documents delegated retention.
  - **Verify**: inspect every `rg -n "provider-side|not applied" docs/guide/agents.md` hit – each must be the sibling FIS's "provider-side defense-in-depth" wording; none may claim the per-agent config is unapplied (no exit-code expectation – the sibling's legitimate wording may match); the agents guide names the pool-worker requirement; control-protocol.md documents the non-empty-systemPrompt contract

- [ ] **TI08** Package `AGENTS.md` files and shared fakes stay current
  - `dartclaw_core` (harness turn contract + restart trigger set), `dartclaw_server` (TurnRunner persona override), `dartclaw_testing` (any `FakeAgentHarness`/`FakeTurnManager` contract change) updated in the same change per the currency rule
  - **Verify**: each edited package's `AGENTS.md` diff reflects the new contract; `dart analyze` clean workspace-wide

### Testing Strategy

- Harness-level restart/prompt assertions live in the `dartclaw_core` harness suites (TI04, TI06); dispatch/routing integration in `dartclaw_server` (`TurnManager` + `SessionDelegate` with `FakeAgentHarness`, which already records `lastSystemPrompt`/`lastModel`/`lastEffort`).
- S03 owns the production reachability proof after S01 lands: run one live smoke (`sessions_send` from an active chat turn on a default-config `dartclaw serve`) and record the provider, pool state, delegated agent, harness/runner evidence, and returned result in Implementation Observations here. S01 closes independently on its harness-boundary evidence.

### Validation

### Execution Contract

- Execute **after** `s01-agent-tool-policy-enforcement-on-the-live-tool-call-path.md` lands (same branch, same files, same `AgentHarness.turn` interface); re-resolve all anchors first. TI01 → TI02 → TI03 in order; TI04/TI05/TI06 independent after TI02; TI07/TI08 last.

## Final Validation Checklist

- [ ] Workspace-wide gate per `dev/guidelines/KEY_DEVELOPMENT_COMMANDS.md` (format, analyze, tests).
- [ ] Production `sessions_send` smoke from an active caller reaches a task-pool worker, returns inline, and records the provider/pool/runner/result evidence in Implementation Observations (S03).

## Implementation Observations

#### DECISION NOTE: delegated-session-lifecycle
Decision-Key: delegated-session-lifecycle
Altitude: requirements
Affected surface: SessionType, SessionService listing/deletion policy, SessionMaintenanceService, delegation dispatch, session architecture/docs, TI05
Decision: Add SessionType.delegated. Delegated sessions are hidden from normal session listings, remain addressable through explicit type/id queries for diagnostics, are not protected from deletion, and participate in normal configured maintenance pruning and storage limits.
Rationale: Preserves failure and audit history without polluting interactive session surfaces or accumulating forever. One domain enum value and existing listing/maintenance seams are simpler and more honest than key-pattern filtering or bespoke cleanup.
Evidence: Operator selected the recommended lifecycle on 2026-08-06. Current user sessions are visible and prunable; task sessions are hidden but protected indefinitely.

#### DECISION NOTE: codex-persona-seam
Decision-Key: codex-persona-seam
Altitude: fis-local
Affected surface: CodexHarness thread startup/resume, turn/start model and effort fields, S07, TI06, control-protocol documentation
Decision: Apply each delegated persona through thread/start developerInstructions on its fresh delegated Codex thread; apply model and effort through turn/start. Do not regenerate config.toml or restart the App Server for persona changes.
Rationale: The stable thread-scoped field exactly matches the delegated-session lifetime and reuses the existing thread-start seam. Config regeneration is broader persistent state and would add avoidable restart/config lifecycle machinery.
Evidence: Current official OpenAI App Server schema and the locally generated schema expose developerInstructions on ThreadStartParams, not TurnStartParams; TurnStartParams exposes model and effort. No experimental gate is declared for the thread field.

#### DECISION NOTE: search-provider-default-model
Decision-Key: search-provider-default-model
Altitude: requirements
Affected surface: Search AgentDefinition resolution, delegation dispatch and Claude agents payload, config model recognition, S01/S02/S05, TI03/TI04/TI07
Decision: When the search agent omits model, resolve the default from the active provider family: sonnet for Claude and gpt-5.6-luna for Codex. Explicit per-agent models always win; other agents keep null/inherit behavior. Resolve through one wiring helper used by both native agents payload construction and DartClaw delegation dispatch; add no provider-model map to YAML.
Rationale: Preserves one honest documented default without binding a multi-harness agent definition to one provider's model namespace. The existing provider-family seam makes this a small composition-root rule rather than a new configuration abstraction.
Evidence: Operator selected provider-specific defaults on 2026-08-06. Official Claude Code CLI docs support the rolling sonnet alias; current official Codex model docs list gpt-5.6-luna and App Server model selection.

#### DECISION NOTE: delegated-pool-provisioning
Decision-Key: delegated-pool-provisioning
Altitude: fis-local
Affected surface: TaskRunnerPoolCoordinator, delegation dispatch, HarnessPool acquisition, S03/S04, TI05
Decision: Delegation is pool-only. Extend and reuse the existing coordinator with an awaitable provider provision-then-acquire path that coalesces concurrent spawn requests. Spawn when no matching runner is idle and capacity remains, including when existing workers are busy; never fall back to the caller's primary harness. Return the inline unavailable error only at real exhaustion or failed provisioning.
Rationale: Preserves deterministic isolation and uses available capacity without duplicating spawn serialization in HarnessWiring. A primary fallback is unavailable in the common active-caller path; immediate failure would waste configured capacity.
Evidence: Operator ratified the recommended behavior on 2026-08-06. Current TaskRunnerPoolCoordinator already serializes task-runner spawning and triggers expansion when matching workers are busy but spawnable capacity remains.

#### DECISION NOTE: onboarding-channel-scope
Decision-Key: onboarding-channel-scope
Altitude: requirements
Affected surface: PromptScope, TurnRunner prompt composition, web and channel dispatch, Claude/Codex prompt lifecycle, onboarding tests and user documentation
Decision: Treat a fresh ONBOARDING.md as bootstrap instructions for every human-facing conversational channel, including web chat, configured messaging channels, and a future REPL. Exclude automated task, cron, workflow, evaluator, and delegated-agent turns. Preserve and make the scoped prompt emission effective across providers instead of removing it.
Rationale: Onboarding belongs to the user conversation, not one transport. Restricting it to the Web UI makes bootstrap provider- and channel-dependent; injecting it into automated execution would leak setup behavior into unrelated work.
Evidence: Operator explicitly expanded onboarding from web-only to all human-facing channels on 2026-08-06 after confirming that ONBOARDING.md is the first-run conversational bootstrap.

#### DECISION NOTE: acp-persona-transport
Decision-Key: acp-persona-transport
Altitude: requirements
Affected surface: OC01, S07/S09, AcpHarness prompt construction, TI06, control-protocol and agent documentation
Decision: On ACP, deliver delegated personas and conversational onboarding as a message-level prepend before the user's prompt, document that this is weaker than a provider system/developer-instruction channel, and pin the exact ordering with tests. Do not introduce a private `_meta` convention or misuse agent-advertised modes as arbitrary instructions.
Rationale: ACP exposes no interoperable system/developer/persona field. The existing prepend provides useful behavior across ACP agents without inventing a bilateral extension that would fragment provider support.
Evidence: Operator conditionally approved the recommended behavior on 2026-08-06 after re-verification. Official ACP v1 and draft v2 schemas expose only user content on `session/prompt`; config options and modes select agent-advertised values, while `_meta` is extension data with no standard persona semantics.
