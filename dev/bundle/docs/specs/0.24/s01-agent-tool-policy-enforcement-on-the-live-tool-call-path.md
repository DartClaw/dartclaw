# Agent Tool Policy Enforcement on the Live Tool-Call Path

**Plan**: dev/bundle/docs/specs/0.24/plan.json
**Story-ID**: S01

> Standalone FIS. Origin: security wiring gap verified 2026-08-05 – the per-agent tool whitelist (`AgentDefinition.allowedTools`) is never enforced on any live tool-call path; restriction is prompt-level only while three docs describe an active 3-layer cascade. Target: **0.24** (owner decision 2026-08-05). Execution repo: `dartclaw-public` – all paths below relative to its root; anchors pinned at commit `584db0c1`. Pin exceptions (dated 2026-08-05, postdate the pin): the cited `dev/state/DECISIONS.md` entries and the TaskToolFilterGuard layered-chain fix – confirm they remain present before exec.

## Feature Overview and Goal

**Intent**: A delegated sub-agent turn (e.g. the built-in `search` agent) can today call `Bash`, `Read`, `Edit`, or any other tool because no production `beforeToolCall` GuardContext ever carries an `agentId` – `ToolPolicyGuard` passes unconditionally and the documented sandbox is fiction; threading the calling agent's identity into guard evaluation makes the configured tool sandbox a real security boundary instead of a prompt-level suggestion.

**Expected Outcomes**:

- [OC01] A delegated sub-agent turn calling a tool outside its configured allowlist is blocked at the guard layer wherever the tool-call guard path is active – unconditionally on Claude (`PreToolUse` hooks); on Codex when approval routing delivers tool calls to the host; on ACP the narrower fs/permission seams are a documented boundary, not an enforcement claim (see Constraints) – while allowlisted tools and main-agent turns behave as before, with one deliberate exception: own-MCP web fetches become domain-gated by `NetworkGuard` on every guard-evaluated turn (restored coverage – S09).
- [OC02] Per-agent network domain grants (`guards.network.agent_overrides`) are honored by `NetworkGuard` for the requesting agent – the config that is parsed and rendered in the guard summary UI actually affects verdicts. Grants apply on the host-enforced tier only (DartClaw-dispatched delegated turns); Claude-native subagent traffic evaluates with the global allowlist.
- [OC03] The config surface is honest: per-agent spawn fields that nothing enforces (`max_spawn_depth`, `max_children_per_agent`) are retired with a loud startup warning instead of being silently accepted, and user docs + architecture docs describe the enforcement that actually exists.

## Required Context

### From `dev/architecture/security-architecture.md` – "ToolPolicyGuard"
<!-- source: dev/architecture/security-architecture.md#toolpolicyguard -->
<!-- extracted: 584db0c1 -->
> 3-layer policy cascade wrapping `ToolPolicyCascade` for integration with the guard chain. Only evaluates when a sub-agent context is present (`context.agentId != null`). Main agent calls pass through.
>
> **Evaluation order** (most restrictive wins):
>
> 1. Global deny — always blocked regardless of agent
> 2. Agent deny — blocked for this specific agent
> 3. Sandbox allow — only explicitly listed tools are permitted (closed set)
>
> A tool passes only if it is NOT in global deny, NOT in agent deny, AND IS in the agent's allow set (if an allow set is defined).

This is the *intended* semantics this FIS makes real. The doc's follow-on claim ("all other tools … are denied at the OS level and policy level, providing defense-in-depth") currently overstates reality and is corrected by TI10.

### From `dev/architecture/security-architecture.md` – "NetworkGuard"
<!-- source: dev/architecture/security-architecture.md#networkguard -->
<!-- extracted: 584db0c1 -->
> **Per-agent overrides**: The `agent_overrides` config section allows granting additional domains to specific sub-agents (e.g. search agent may need broader web access).

Documented and parsed (`NetworkGuardConfig.fromYaml` builds `agentOverrides`) but never read in `NetworkGuard.evaluate`/`_checkUrl`. Once sandbox-allow enforcement is live, the search agent's `WebFetch` calls (and, after TI12, its own-MCP `web_fetch` calls, which canonicalize to `web_fetch`) are constrained by the dev-centric default domain allowlist, so this seam gains a concrete consumer – wire it (decision below). TI12's remap also restores `NetworkGuard` domain coverage for *all* turns' own-MCP fetches – today the MCP path bypasses the domain allowlist entirely (the MCP tool itself performs SSRF checks only); the main-agent consequence is deliberate (S09, DECISION NOTE: null-agent-networkguard-gating).

## Deeper Context

- `dev/state/DECISIONS.md` (Still Current, 2026-08-05: "Built-in `search` agent keeps its name") – rename to `web_search` was evaluated and declined; do not touch agent naming while fixing enforcement.
- `dev/state/DECISIONS.md` (Still Current, 2026-08-05: "Delegation enforcement boundary") – host-enforced delegated turns vs provider-enforced Claude-native subagents; the boundary TI10 documents.
- `dev/adrs/016-multi-provider-harness-architecture.md` Part 1 – the canonical taxonomy this FIS extends with `web_search` and `memory_save` (TI12; inline amendment note, precedent: the ADR-037 note in the same file).
- `dev/architecture/control-protocol.md#41-initialize-handshake` – the Claude initialize handshake and its `agents` request field (the doc example shows `description`/`prompt`; the authoritative per-agent shape is `AgentDefinition.toInitializePayload`); TI09/TI10 add `tools` here.
- `docs/guide/agents.md#subagent-configuration-reference` – the per-agent config key table (source of the keys retired/kept by TI08 and rewritten by TI10).
- `docs/guide/agents.md#subagent-limits` – documents `SubagentLimits` derivation (`maxSpawnDepth` hardcoded 1, `maxChildrenPerAgent` = summed `max_concurrent`); confirms the per-agent spawn fields were never the enforcement source.
- `dev/architecture/security-architecture.md#guard-pipeline` – hook points and chain composition, for placing the changed guards.

## Acceptance Scenarios

- [x] **S01 [OC01] [TI01,TI02,TI03,TI04] Search-agent harness turn cannot use the shell**
  - **Given** the default agent config (built-in `search` agent, `allowedTools: {web_search, web_fetch}` – canonical spellings) and a Claude harness turn invoked with DartClaw `sessionId: s-123` and `agentId: search`
  - **When** the Claude binary emits a `PreToolUse` hook callback for tool `Bash` during that turn
  - **Then** the guard chain returns a block verdict with message `Tool "Bash" not allowed for agent "search"`, the harness answers the hook with `allow: false`, and the evaluated `GuardContext` carries `agentId: search` and the DartClaw session id that was passed to `turn()` (not the provider-side session UUID)

- [x] **S02 [OC01] [TI02,TI04,TI12] Allowlisted tools still work for the delegated agent**
  - **Given** the same `search`-agent harness turn, with no search provider configured (native `WebSearch` is not suppressed at spawn)
  - **When** `PreToolUse` fires for `WebSearch`
  - **Then** `ToolPolicyGuard` passes (raw `WebSearch` maps to canonical `web_search`, which is in the allow set) and the hook is answered `allow: true` (subject only to the other guards in the chain)

- [x] **S03 [OC01] [TI02] Canonical tool names in an allowlist are provider-portable**
  - **Given** a custom agent configured with `tools: [web_fetch]` (canonical name, not the Claude-native `WebFetch`)
  - **When** the cascade evaluates a Claude call with raw name `WebFetch` (canonical `web_fetch`)
  - **Then** the call is allowed – the cascade matches if *either* the raw provider name or the canonical stable name is listed; a raw name absent from both (e.g. `Bash`/`shell`) is still blocked

- [x] **S04 [OC01] [TI02,TI04] Closed set blocks MCP tools – delegated agents cannot re-delegate**
  - **Given** the `search`-agent harness turn (allow set `{web_search, web_fetch}`)
  - **When** `PreToolUse` fires for the MCP tool `mcp__dartclaw__sessions_send` (canonical `mcp_call`)
  - **Then** the call is blocked – neither the raw name nor `mcp_call` is in the allow set, so a sandboxed agent cannot spawn further delegations or reach memory/task MCP tools

- [x] **S05 [OC01] [TI02,TI03] Main-agent turns are untouched**
  - **Given** an ordinary interactive turn (`agentName: 'main'`) on the same guard chain
  - **When** `PreToolUse` fires for `Bash`
  - **Then** the chain verdict and side effects are identical to today's – no `ToolPolicyGuard` block verdict is recorded (observable via the chain's `onVerdict`), `GuardContext.agentId` is null for main turns, and the outcome is decided solely by the other guards

- [x] **S06 [OC02] [TI07] Per-agent network domain grant applies only to that agent**
  - **Given** `guards.network.agent_overrides.search.extra_domains: [example.com]` and `example.com` absent from the global allowlist
  - **When** a `web_fetch` of `https://example.com/page` is evaluated with `agentId: search`, and the same fetch is evaluated with `agentId` null
  - **Then** the search-agent call passes `NetworkGuard` while the main-agent call is blocked with `Network blocked: domain not in allowlist (example.com)`

- [x] **S07 [OC03] [TI08] Retired spawn fields warn loudly and never leak to the provider**
  - **Given** a config with `agent.agents.search.max_spawn_depth: 2` and `max_children_per_agent: 5`
  - **When** the config is parsed at startup
  - **Then** a warning names each retired key as ignored/unenforced, `AgentDefinition` no longer carries the fields, and neither key appears in `extra` (and therefore never reaches the Claude initialize handshake)

- [x] **S08 [OC01] [TI04,TI12] MCP-backed search tools work for the delegated agent**
  - **Given** a `search`-agent harness turn in a serve deployment with MCP enabled and a search provider configured (native `WebFetch`/`WebSearch` suppressed at spawn via `mcpDisallowedTools`)
  - **When** `PreToolUse` fires for `mcp__dartclaw__brave_search` and then for `mcp__dartclaw__web_fetch`
  - **Then** both calls are allowed – the wiring-injected semantic mapping canonicalizes them to `web_search` / `web_fetch`, which are in the allow set – while `mcp__dartclaw__sessions_send` still canonicalizes to `mcp_call` and stays blocked (S04)

- [x] **S09 [OC01] [TI12] Own-MCP fetches are domain-gated on guard-evaluated turns (restored coverage)**
  - **Given** a guards-enabled serve deployment with MCP on, the Claude harness, `example.com` absent from `guards.network.allowed_domains`, and no `agent_overrides` entry for the main agent
  - **When** a main-agent turn (`agentId` null) calls `mcp__dartclaw__web_fetch` for `https://example.com/page`, and again for an allowlisted domain
  - **Then** the non-allowlisted fetch is blocked by `NetworkGuard` (`Network blocked: domain not in allowlist (example.com)`) and the allowlisted fetch passes – the remapped call evaluates as canonical `web_fetch`, closing today's MCP-path bypass of the domain allowlist (the MCP tool itself performs SSRF checks only)

- [x] **S10 [OC01] [TI02,TI04,TI12] Doc-copied raw allowlists keep working under MCP (entry canonicalization)**
  - **Given** a search agent explicitly configured `tools: [WebSearch, WebFetch]` (the raw spelling today's guides instruct) in an MCP + search-provider deployment, running a delegated turn (`agentId: search`) on the Claude harness
  - **When** `PreToolUse` fires for `mcp__dartclaw__brave_search` (canonical `web_search`)
  - **Then** the call is allowed – allow/deny entries are normalized through the static known-name table at cascade build (`WebSearch` → `web_search`, `WebFetch` → `web_fetch`), so matching succeeds in canonical space; an entry matching no known name stays literal

- [x] **S11 [OC01] [TI12] Exact own-MCP semantics are consistent across Claude and Codex**
  - **Given** the shared own-MCP inventory contains `memory_save` → canonical `memory_save`
  - **When** Claude reports `mcp__dartclaw__memory_save` and Codex reports an `mcp_tool_call` item with `server: dartclaw`, `tool: memory_save`
  - **Then** both adapters emit canonical `memory_save`; an unknown DartClaw tool and a third-party server tool remain generic `mcp_call`

## Structural Criteria

- [x] `GuardChain.evaluateBeforeToolCall` gains only an optional named `agentId` parameter; all existing call sites compile unchanged (`service_wiring_mcp_tools.dart#_kgGuardEvaluator`, `guard_editor_service.dart#_evaluateTestChain`, `harness_wiring.dart#_acpPermissionDecision`).
- [x] On the Claude harness, `GuardContext.sessionId` for `beforeToolCall` equals the DartClaw session id passed to `turn()`; the provider-side session UUID (from `SystemInit`) remains available for logging but is no longer used as the guard/audit session identity.
- [x] On the Codex and ACP harnesses, `beforeToolCall` guard evaluations during an active/bound turn carry that turn's `agentId` alongside the existing DartClaw session id; idle/unbound behavior unchanged.
- [x] `AgentDefinition.toInitializePayload` emits `'tools': [...]` exactly when `allowedTools` is non-empty and continues to omit it when empty; `disallowedTools` and `extra` behavior unchanged.
- [x] `max_spawn_depth` and `max_children_per_agent` remain in `AgentDefinition._extractExtra`'s reserved set (parse-and-ignore with warning), so existing configs neither break nor leak the keys.
- [x] No doc in `docs/guide/` or `dev/architecture/` still claims that per-agent `max_spawn_depth`/`max_children_per_agent` are enforced, that per-agent `max_concurrent` is individually enforced, or that sandbox enforcement is "OS level".
- [x] Package `AGENTS.md` files for `dartclaw_security`, `dartclaw_core`, and `dartclaw_models` carry no stale mention of the retired spawn fields or pre-enforcement guard behavior.
- [x] The semantic own-MCP inventory is constructed once before harness startup and supplies both harness mapping and later MCP registration; provider adapters do not maintain separate tool lists. (Proved by TI12 Verify.)
- [x] All existing tests pass workspace-wide (`dart analyze` + `dart test`); barrel export tests updated only where the public API legitimately changed.

## Scope & Boundaries

### Work Areas

- `dartclaw_security` – `GuardChain`/`GuardContext` agent-identity plumbing (`guard.dart`), `NetworkGuard` per-agent overrides (`network_guard.dart`).
- `dartclaw_core` – `ToolPolicyCascade`/`ToolPolicyGuard` dual-name matching (`agents/tool_policy_cascade.dart`), `AgentHarness.turn` contract (`harness/agent_harness.dart`), Claude/Codex/ACP harness guard-context construction (`harness/claude_code_harness.dart`, `harness/codex_harness.dart`, `harness/acp_harness.dart` + `harness/acp_reverse_call_handlers.dart`), canonical taxonomy + adapter mapping (`harness/canonical_tool.dart`, `harness/claude_protocol_adapter.dart`, `harness/codex_protocol_adapter.dart`).
- `dartclaw_models` – `AgentDefinition` spawn-field retirement, `tools` in the initialize payload, and the canonical default allowlist for `searchAgent`/`fromYaml` search fallback (`agent_definition.dart`).
- `dartclaw_server` – `TurnRunner` passes the active turn's agent into `_worker.turn(...)` (`turn_runner.dart`); `guard_editor_service.dart` passthrough; canonical-consumer sweep in `task/claude_cli_provider.dart` (web translation split) and `templates/task_form.dart` (gains `web_search`) (TI12).
- `dartclaw_cli` – wiring cleanup where the retired fields were referenced (`commands/wiring/harness_wiring.dart` `SubagentLimits` construction – already derives from `maxConcurrent` only); agents-payload canonical→native translation and the own-MCP semantic map (same file, TI09/TI12); serve-startup enforcement warnings (TI08); the semantic inventory's registration seam `commands/service_wiring_mcp_tools.dart#_registerMcpTools` (TI12).
- `dartclaw_testing` + package-local test supports – `FakeAgentHarness`, `MinimalHarness`, `FakeTaskWorker` signature updates.
- Docs – `docs/guide/search.md`, `docs/guide/agents.md`, `docs/guide/configuration.md`, `dev/architecture/security-architecture.md`, `dev/architecture/control-protocol.md` (initialize-handshake `agents` payload docs), `dev/adrs/016-multi-provider-harness-architecture.md` (Part 1 taxonomy amendment note), package `AGENTS.md` files touched.

### What We're NOT Doing

- **No second enforcement layer via `TaskToolFilterGuard`** (i.e. not passing `allowedTools` through `SessionDelegate`'s `startTurn`) – it would duplicate the same policy in a second name domain (that guard matches canonical `context.toolName` only). One correct enforcement point (`ToolPolicyGuard`) beats two half-consistent ones. *(Update 2026-08-05: the filter now IS in the primary chain – see adjacent-defect note below – but the name-domain argument stands; still no `allowedTools` pass-through.)*
- **Not fixing the primary-runner `TaskToolFilterGuard` absence** – **FIXED separately on `feat/0.23` (2026-08-05)**: `harness_wiring.dart` now composes a `GuardChain.layered` per-runner chain (base security chain + per-runner filter) for the primary harness and task runners alike; base `replaceGuards` hot-reload propagates live, the filter survives rebuilds. Regression tests in `apps/dartclaw_cli/test/commands/wiring/harness_wiring_test.dart` + `packages/dartclaw_security/test/guard_chain_test.dart`.
- **Not enforcing per-agent `max_concurrent` individually** – `SubagentLimits` tracks spawns under parent `'main'` only; the global summed cap is what exists. TI10 corrects the docs claim; per-agent enforcement is deferred until someone needs it.
- **Not renaming the `search` agent** – declined in `dev/state/DECISIONS.md` (2026-08-05). Its default capabilities stay web search + web fetch; the allowlist *spelling* moves to canonical `{web_search, web_fetch}` (DECISION NOTE: search-agent-mcp-allow-set), which is not a capability change.
- **Not changing the `ContentGuard` return-path boundary or `SessionDelegate` dispatch flow** – the return-path boundary works; S02 owns delegated-dispatch reachability while the primary harness is busy. This FIS only adds identity to the tool-call path.

### Adjacent defects surfaced (out of scope, do not fix here)

- ~~Primary guard chain lacks `TaskToolFilterGuard`~~ – fixed on `feat/0.23` (2026-08-05, see What We're NOT Doing above). Note for TI04: session-keyed `TaskToolFilterGuard` policies now become newly effective on Claude for the **primary** runner too, not just task runners (third bullet below) – e.g. the knowledge-inbox no-tools turn.
- `AgentDefinition.prompt`/`model` appear unapplied on the `sessions_send` dispatch path: the delegated turn runs with the default behavior prompt and default model (`TurnRunner._buildSystemPrompt` reads behavior only; dispatch passes no `model`/`behaviorOverride`); the definition's prompt/model reach only the Claude-native `agents` handshake. Needs its own verification + spec.
- Session-keyed `TaskToolFilterGuard` policies on task-runner chains become *newly effective on Claude* once TI04 fixes the guard-context session id (they previously keyed on the provider UUID and never matched). Exec must run the workflow/task suites to confirm no latent policy suddenly blocks legitimate task-runner traffic.

## Architecture Decision

**Approach**: Thread agent identity as explicit active-turn state – `TurnRunner` passes the turn's agent into `AgentHarness.turn(...)`, each harness records it (mirroring Codex's existing `_activeSessionId` pattern) and supplies `agentId` + the DartClaw session id to `GuardChain.evaluateBeforeToolCall`; enforcement reuses the already-built-and-wired `ToolPolicyGuard`/`ToolPolicyCascade` as the single host-side gate, with `tools` forwarded in the Claude initialize handshake as provider-side defense-in-depth.
**Why this over alternatives**: an explicit parameter beats parsing agent ids out of session keys (the harness receives storage session ids, not the `agent:<id>:delegated:<uuid>` key) and beats a mutable sessionId→agent registry on the guard (which would silently not match on Claude, whose guard contexts carry the provider UUID today – the very bug class being fixed).

## Technical Overview

Identity flow after this change: `SessionDelegate.handleSessionsSend` → `TurnManager.startTurn(..., agentName: agentId)` → `TurnContext.agentName` → `TurnRunner._runTurnInner` passes `agentId` (null when `agentName == 'main'`) into `_worker.turn(...)` → harness stores `{sessionId, agentId}` for the active turn → every `beforeToolCall` guard evaluation (Claude `PreToolUse` hook, Codex approval request, ACP reverse call) carries both → `ToolPolicyGuard` consults `ToolPolicyCascade` with the raw provider name *and* the canonical stable name → block verdicts deny the provider-side hook/approval. Turns for agent names without a cascade entry (`advisor`, `cron:<job-id>` scheduled-job turns, provider-delegation ids, custom unnamed agents) get identity but no allow set, so they pass unchanged – only agents with configured `tools` are sandboxed, and `agent.disallowed_tools` (global deny) plus `denied_tools` (agent deny) apply to any identified agent. DartClaw's exact own-MCP tools canonicalize semantically through one wiring-built inventory: Claude keys by raw `mcp__<server>__<tool>` name, while Codex keys by the `server`/`tool` fields already present in each `mcp_tool_call` item. Search/fetch map to `web_search`/`web_fetch`, journal writes map to `memory_save`, and unrelated tools remain `mcp_call`; deny entries naming `mcp_call` still cover every semantically remapped own tool, and raw-spelled deny entries (e.g. `WebFetch`) reach the own-MCP equivalents via entry canonicalization – newly-identified turns (`cron:<id>`, delegated agents) feel both changes at once. The fetch remap restores `NetworkGuard` domain coverage (S09), and the cross-harness map removes the former Codex+MCP semantic-identity limitation without changing Codex's approval-routed host-guard boundary. Claude-native `agents` subagents run inside the main turn and remain provider-enforced via the forwarded `tools` key – the host-enforced boundary covers DartClaw-dispatched delegated turns only (`dev/state/DECISIONS.md` Still Current, 2026-08-05); Codex has no provider-native subagent path, so all Codex delegation is host-enforced when approval routing is active.

## Code Patterns & External References

```
# type | path#anchor or url                                                          | why needed (intent)
file   | packages/dartclaw_core/lib/src/harness/codex_harness.dart#_activeSessionId  | Active-turn state pattern to replicate for agentId (and in Claude harness for both ids)
file   | packages/dartclaw_core/lib/src/agents/tool_policy_cascade.dart#ToolPolicyCascade.isAllowed | The 3-layer evaluation to extend with dual-name matching
file   | packages/dartclaw_core/lib/src/harness/claude_code_harness.dart#_handlePreToolUseCallback  | Claude guard-evaluation site: raw name, canonical mapping, hook deny response
file   | packages/dartclaw_core/lib/src/harness/acp_reverse_call_handlers.dart#bindTurn | ACP per-turn binding (_AcpTurnBinding) to extend with agentId
file   | packages/dartclaw_server/lib/src/turn_runner.dart#_runTurnInner              | Where TurnContext.agentName is available around the _worker.turn call
file   | packages/dartclaw_server/lib/src/security/guard_builder.dart#buildGuardsFromConfig | Chain composition – ToolPolicyGuard already appended; no wiring change needed
file   | apps/dartclaw_cli/lib/src/commands/wiring/security_wiring.dart#_wireGuardChain | Where agentAllow/agentDeny maps are built from AgentDefinition (policy data already exists)
file   | packages/dartclaw_core/lib/src/harness/canonical_tool.dart#CanonicalTool     | The canonical stable-name set – TI12 extends it with web_search and memory_save
file   | apps/dartclaw_cli/lib/src/commands/wiring/harness_wiring.dart#agentsPayload  | Agents-payload assembly – canonical→native translation and the own-MCP semantic map are built here (TI09/TI12)
url    | https://code.claude.com/docs/en/headless                                     | Claude initialize `agents` payload – confirm the per-agent `tools` key shape for TI09
```

## Constraints & Gotchas

- **Two tool-name domains coexist**: config/docs use Claude-native names (`WebSearch`, `Bash`, `Read`); guards evaluate canonical names with the raw provider name preserved. The cascade must match **raw OR canonical** for both allow and deny sets (deny blocks if either matches; allow passes if either matches) so existing documented configs keep working and canonical names become the portable option for canonically-mapped tools. Unmapped provider tools have no canonical spelling and evaluate under a `claude:<raw>`/`codex:<raw>` fallback name (e.g. Claude `Glob`). DartClaw's exact own-MCP tools are the exception to generic `mcp_call`: Claude maps the exact raw name and Codex maps the existing `server`/`tool` payload pair through the same wiring-provided semantic inventory; third-party and unknown tools stay `mcp_call`. Do not regress the `dartclaw_security` convention that *other* guards route policy by canonical only.
- **The guard chain is shared** across the primary harness, task runners (base of `_buildTaskGuardChain`), the KG evaluator, and the guard-editor tester. Every behavior change must be null-agentId-neutral: with `agentId` null the new code paths must be observably equivalent to today – identical verdicts and side effects (S05) – with the single ratified exception of the TI12 own-MCP fetch remap, which domain-gates own-MCP `web_fetch` calls on every guard-evaluated turn including null-agent ones (S09, DECISION NOTE: null-agent-networkguard-gating).
- **`AgentHarness.turn` is an interface**: adding a named parameter breaks every implementer. Production set: `ClaudeCodeHarness`/`CodexHarness` (via `BaseHarness`) and `AcpHarness`; shared fakes: `dartclaw_testing/fake_agent_harness.dart`, `dartclaw_server/test/turn_runner_test_support.dart#MinimalHarness`, `dartclaw_server/test/task/task_executor_test_support.dart#FakeTaskWorker`, `dartclaw_workflow/test/workflow/scenario_test_support.dart#ScriptedAgentWorker`; plus ~18 inline test fakes across `dartclaw_server` tests (the sweep hits ~23 files; `packages/dartclaw/example/example.dart` only *calls* a harness – unaffected by an optional named parameter). Sweep with `rg -n "implements AgentHarness|extends AgentHarness"` before declaring done.
- **Claude session identity**: `_sessionId` is the *provider's* UUID from `SystemInit`; the DartClaw session id arrives as the `turn()` parameter and must be captured as active-turn state. Keep the provider UUID for the existing init log line; switch guard/audit context to the DartClaw id (Structural Criterion 2). Clear active-turn state in the same `finally` that clears `_turnCompleter`.
- **Fail-open semantics of unknown agents are deliberate**: no allow set → allow all (minus denies). Do not "harden" this – custom-named turns (`advisor`, delegation runners) rely on it.
- **`NetworkGuard._checkUrl` is also reached from Bash URL extraction** – per-agent extra domains must apply to both `shell` and `web_fetch` evaluation paths (pass the effective allowlist, don't special-case one caller).
- **Codex/ACP host guard evaluation rides the approval channel**: the only Codex `beforeToolCall` site is `_handleApprovalRequest`, and the recommended deadlock workaround (`control-protocol.md`, `approval: never` + full sandbox) means **no** Codex tool call reaches the host guards in that posture – host tool-policy enforcement on Codex requires `approval: on-request`/`granular`. OC01's guard-layer block is unconditional only on Claude. Cross-harness semantic mapping makes Codex own-MCP identity accurate when a tool event reaches the adapter, but does not manufacture a guard event under `approval: never`. On ACP the host-guard surface is narrower still: fs reverse calls evaluate canonically (`file_read`/`file_write`), but the permission seam passes the *agent-supplied* operation string as the guard tool name (no ACP raw→canonical mapping exists), and calls that request no permission never reach the host – so ACP gets identity plumbing (TI06) and this documented boundary, not an OC01 enforcement claim (owner decision 2026-08-07, same honesty posture as Codex). TI08 adds a startup warning for the sandboxed-agents + Codex + `approval: never` combination and a variant for sandboxed agents on an ACP harness; TI10 corrects `control-protocol.md`'s "guard chain remains active" claim.

## Implementation Plan

### Implementation Tasks

- [x] **TI01** `GuardChain.evaluateBeforeToolCall` accepts and propagates agent identity
  - Optional named `String? agentId` → `GuardContext.agentId`; `guard_editor_service.dart#_evaluateTestChain` forwards `context.agentId` for the tester path
  - **Verify**: `dartclaw_security` `guard_chain_test.dart` – a chain evaluation with `agentId: 'search'` yields a `GuardContext` whose `agentId` is `'search'`; omitting the parameter yields null (existing tests untouched)

- [x] **TI02** `ToolPolicyCascade` matches raw and canonical names; main-agent passthrough preserved
  - `isAllowed` (or a successor taking both names) blocks when raw *or* canonical hits global/agent deny, and passes the allow layer when the set is absent or contains raw *or* canonical; `ToolPolicyGuard` supplies `context.rawProviderToolName` and `context.toolName`, still passing immediately when `context.agentId` is null; block messages render the raw provider name when present (canonical fallback). Allow/deny *entries* are normalized at cascade build through a static known-name table of exact raw↔canonical pairs (`WebSearch`/`web_search`, `WebFetch`/`web_fetch`, `Bash`/`shell`, `Read`/`file_read`, `Write`/`file_write`, `Edit`/`file_edit`, Codex `command_execution`/`shell`; **no prefix rules and no kind-dependent entries** – an `mcp__…` entry matches no table row and stays literal, never widening to `mcp_call`) so raw-spelled configs match in canonical space too (S10); on the deny layers, semantically-remapped own-MCP calls additionally match entries naming `mcp_call` (deny-side category union – deny errs broad; the allow side stays semantic-only, so allowing `mcp_call` does not grant own fetch/search/memory tools)
  - **Verify**: `tool_policy_cascade_test.dart` – allow `{web_search, web_fetch}` (the search default): raw `Bash`/canonical `shell` blocked with message `Tool "Bash" not allowed for agent "search"`, raw `WebSearch` (canonical `web_search`) allowed; allow `{WebSearch}` (raw user-config entry): raw `WebSearch` allowed via raw match, and raw `mcp__dartclaw__brave_search` (canonical `web_search`) allowed via entry canonicalization [S10]; deny `{shell}`: raw `Bash` blocked; deny `{WebFetch}` (raw entry, normalized `web_fetch`): own-MCP `mcp__dartclaw__web_fetch` blocked (raw-spelled denies gain the own-MCP equivalents); deny `{mcp_call}`: own-MCP `mcp__dartclaw__web_fetch` (semantic canonical `web_fetch`) still blocked via category union, while allow `{mcp_call}` alone does not admit it; allow `{mcp__dartclaw__web_fetch}` (exact MCP raw entry): admits exactly that raw name and no other MCP tool (stays literal, no `mcp_call` widening); `agentId` null → pass for every tool; `agentId: 'cron:x'` with no cascade entry → pass for any tool not in global deny, and a global-deny entry still blocks it (identified-but-unsandboxed passthrough)

- [x] **TI03** `AgentHarness.turn` carries the calling agent; `TurnRunner` supplies it
  - Add `String? agentId` to the interface and all implementers (sweep per Constraints); `TurnRunner._runTurnInner` and the context-flush turn pass `agentName == 'main' ? null : agentName` from the active `TurnContext`
  - **Verify**: `turn_runner` test – `startTurn(..., agentName: 'search')` reaches the fake harness with `agentId: 'search'`; default `agentName` reaches it as null

- [x] **TI04** Claude harness evaluates guards with active-turn identity
  - Capture `{sessionId, agentId}` at `turn()` entry (cleared in the existing `finally`); `_handlePreToolUseCallback` passes both to `evaluateBeforeToolCall` – the DartClaw session id replaces `_sessionId` in the guard context
  - **Verify**: `claude_code_harness` test with a recording guard (`test/harness/harness_test_support.dart#RecordingGuard`) – during `turn(sessionId: 's-123', agentId: 'search')`, a `PreToolUse` for `Bash` produces a context with `sessionId: 's-123'`, `agentId: 'search'`, `rawProviderToolName: 'Bash'`, and a blocking chain answers the hook `allow: false` [S01]

- [x] **TI05** Codex harness threads `agentId` alongside `_activeSessionId`
  - Same active-turn capture; `_handleApprovalRequest` passes `agentId` into `evaluateBeforeToolCall`
  - **Verify**: codex harness approval test – recorded `GuardContext` carries `agentId` from the active turn and the existing DartClaw `sessionId`

- [x] **TI06** ACP turn binding carries `agentId`; reverse calls and permission decisions see it
  - `_AcpTurnBinding` + `bindTurn(...)` gain `agentId`; `_evaluateGuard` (acp_reverse_call_handlers.dart) passes it; the `AcpPermissionRequest` → `_acpPermissionDecision` seam forwards `sessionId` + `agentId` so the wiring-side evaluation stops calling `evaluateBeforeToolCall` identity-blind
  - **Verify**: `acp_reverse_call_handler_test.dart` – a reverse call during a bound turn evaluates with the bound `agentId`; unbound behavior unchanged

- [x] **TI07** `NetworkGuard` honors `agent_overrides` for the requesting agent
  - Effective allowlist = `allowedDomains` ∪ `agentOverrides[context.agentId]` for both the `shell` URL-extraction path and `web_fetch`; no change when `agentId` is null or has no override entry
  - **Verify**: `network_guard_test.dart` – with `agent_overrides: {search: {extra_domains: [example.com]}}`, `web_fetch` of `https://example.com` passes at `agentId: 'search'` and blocks at `agentId: null`; a `curl https://example.com` shell command follows the same split [S06]

- [x] **TI08** `AgentDefinition` retires the unenforced spawn fields
  - Remove `maxSpawnDepth`/`maxChildrenPerAgent` fields and the `searchAgent` factory args; `fromYaml` warns `agents.<id>.max_spawn_depth is not enforced — ignored` (same for `max_children_per_agent`) when present; keys stay in `_extractExtra`'s reserved set; `harness_wiring.dart` `SubagentLimits` construction (hardcoded depth 1, summed `maxConcurrent`) is confirmed field-independent; the existing empty-`tools` startup warning for non-search agents is corrected to match fail-open enforcement (empty allowlist = no sandbox, all tools available minus denies – not "will not be able to use any tools"); serve startup additionally warns when any agent defines `tools` while a Codex harness runs `approval: never` (host tool-policy enforcement is inactive on that harness – see Constraints), and likewise for sandboxed agents on an ACP harness (partial guard surface – see Constraints)
  - **Verify**: `dartclaw_models` test – `fromYaml` with `max_spawn_depth: 2` emits the warning, the resulting `toInitializePayload()` and `extra` contain neither key; `rg -n "maxSpawnDepth|maxChildrenPerAgent" packages/dartclaw_models` returns no hits; wiring test – warning emitted for the sandboxed-agents + Codex + `approval: never` combination and for the ACP variant

- [x] **TI09** Claude initialize handshake carries the per-agent allowlist in provider-native spelling
  - `toInitializePayload` emits `'tools': allowedTools.toList()` when non-empty (confirm key shape against the headless docs reference); empty allowlist keeps the key absent. `harness_wiring.dart` translates **every** canonical entry to its Claude-native spelling when assembling the `agents` payload (`shell` → `Bash`, `file_read` → `Read`, `file_write` → `Write`, `file_edit` → `Edit`, `web_fetch` → `WebFetch`, `web_search` → `WebSearch`; `mcp_call` has no native spelling – omitted with a debug log; prior art: `claude_cli_provider.dart`'s canonical→native pattern translation) and appends the concrete own-MCP raw names scoped by grant – the fetch tool name iff the allow set grants `web_fetch`, the search tool names iff it grants `web_search`, never unconditionally (appending to unrelated agents would widen the provider-side gate) – so the gate matches the tools the native subagent actually has; both the translation and the grant-scope check operate on entries normalized through the TI02 static table first, so raw-spelled configs (`tools: [WebSearch, WebFetch]`) translate and receive the own-MCP names exactly like canonical ones; entries the table does not know pass through untranslated
  - **Verify**: payload/wiring test – under an MCP-enabled config the search agent's `tools` contains `WebSearch`, `WebFetch`, and the own-MCP raw names; a raw-spelled agent `tools: [WebSearch, WebFetch]` under MCP gets the same own-MCP raw names appended (normalized grant check); a custom agent `tools: [shell, file_read]` forwards `['Bash', 'Read']`; a custom agent `tools: [Read]` gains no MCP names; an agent with empty `allowedTools` has no `tools` key; a raw user-configured entry (e.g. `Grep`) passes through unchanged

- [x] **TI10** User and architecture docs match the shipped enforcement
  - `docs/guide/search.md` + `docs/guide/agents.md`: cascade described as guard-layer enforcement on delegated turns; the search agent's canonical default allowlist (`{web_search, web_fetch}`) and the cross-harness own-MCP semantic mapping documented; tool-name domains explained (provider-native + canonical; canonical names are portable only for canonically-mapped tools – unmapped tools such as Claude `Glob` keep provider-native names, evaluating under `claude:<raw>`/`codex:<raw>` guard fallbacks); spawn-field rows removed/marked retired; the "Tools default behavior" paragraph corrected (empty/absent `tools` = no sandbox – all tools allowed minus denies, not "no tools are permitted"); the per-agent `max_concurrent` "finer-grained control" claim corrected to global-sum enforcement; guide examples move to canonical spellings with a migration note (raw spellings keep working via entry canonicalization; raw-spelled denies now also cover the own-MCP equivalents; task/step policies naming `web_fetch` no longer imply `WebSearch` – add `web_search`). `docs/guide/configuration.md`: `max_spawn_depth` removed from the example; a note that own-MCP `web_fetch` is now domain-gated by `guards.network.allowed_domains` on guard-evaluated turns (upgrade impact for guards-on MCP deployments – maintain `allowed_domains`/`extra_allowed_domains`). `dev/architecture/security-architecture.md`: ToolPolicyGuard section states identity threading and the delegation enforcement boundary, fixes the "OS level" claim, adds `web_search`/`memory_save` taxonomy rows, and documents exact own-MCP mapping on Claude raw names and Codex `server`/`tool` payloads; NetworkGuard notes `agent_overrides` is enforced. `dev/architecture/control-protocol.md#41-initialize-handshake`: the `agents` example and request-field table document per-agent `tools`, while its deadlock-workaround section states that no `beforeToolCall` guard runs under Codex `approval: never`. `docs/guide/workflows-reference.md`: the `mcp_call` entry notes that DartClaw's own fetch/search/memory tools now evaluate under their exact canonicals, so step allowlists naming `mcp_call` no longer admit them – list `web_fetch`/`web_search`/`memory_save` instead (the deny-side `mcp_call` union lives in the agent cascade, not in step allowlists – `TaskToolFilterGuard` has no deny layer; the union is documented in the agents guide/security-architecture).
  - **Verify**: `rg -n "max_spawn_depth" docs/ dev/architecture/` reports only retired-key mentions (if any); `rg -n "OS level" dev/architecture/security-architecture.md` returns nothing; `rg -n "web_search" dev/architecture/security-architecture.md` shows the corrected taxonomy row; the agents-guide cascade section names `ToolPolicyGuard` as the live enforcement point

- [x] **TI11** Package `AGENTS.md` files stay current
  - `dartclaw_security` (ToolPolicyGuard is the one guard matching raw+canonical; `evaluateBeforeToolCall` identity params), `dartclaw_core` (harness active-turn identity; Claude guard-context session id is the DartClaw id), `dartclaw_models` (spawn fields retired, `tools` forwarded) – update the affected Role/Gotcha lines in the same change
  - **Verify**: each edited package's `AGENTS.md` diff shows the corresponding fact updated and no stale mention of the retired spawn fields or pre-enforcement guard behavior remains (diff inspection – the field names appear in no package `AGENTS.md` today, so absence alone proves nothing)

- [x] **TI12** Canonical `web_search`/`memory_save` + cross-harness semantic mapping for DartClaw's own MCP tools
  - `CanonicalTool` gains `webSearch('web_search')` and `memorySave('memory_save')`; `dev/adrs/016-multi-provider-harness-architecture.md` Part 1's taxonomy table receives one inline amendment note. Claude maps `WebSearch` and exact own-MCP raw names; Codex corrects native `web_search` and maps MCP items using their existing `server`/`tool` payload fields before generic `mcp_call`. Immediately after security wiring and before harness wiring, the composition root constructs one immutable semantic inventory of the actual enabled own-MCP tool instances needed at startup (`web_fetch` → `web_fetch`, enabled Brave/Tavily search → `web_search`, `memory_save` → `memory_save`), passes it to `HarnessWiring` for provider map construction, and later registers those same instances in `_registerMcpTools`; outbound/third-party tools stay generic and are excluded. The shared MCP server key replaces the duplicated `'dartclaw'` literal. `AgentDefinition.searchAgent` and the `fromYaml` search fallback default to `{web_search, web_fetch}`; remaining canonical-name consumers and task-form options are swept.
  - **Verify**: adapter tests prove Claude raw and Codex `server`/`tool` forms produce the same canonical for search/fetch/memory-save, while unknown own tools and third-party tools stay `mcp_call` (S11); wiring tests prove the semantic map and live MCP registration derive from the same prebuilt instances with no duplicated enabled-provider predicate; `searchAgent` defaults to `{web_search, web_fetch}`; own-MCP `web_fetch` reaches `NetworkGuard` with the URL visible (S09); deny `mcp_call` still blocks all remapped own tools, while allow `mcp_call` alone grants none of them.

### Testing Strategy

- Scenario tests live at the layer that owns the behavior: cascade matrix in `dartclaw_core` (TI02), per-harness context assertions in the harness suites (TI04–TI06), network overrides in `dartclaw_security` (TI07). One harness-boundary assertion (S01) belongs in the Claude harness test since that is where hook-deny is observable; no new integration profile needed.
- After TI04, run the `dartclaw_server` task/workflow suites to catch session-keyed `TaskToolFilterGuard` policies newly matching on Claude (see Adjacent defects, third bullet).
- S09's composed assertion (semantic inventory → adapter canonical → `NetworkGuard` domain verdict) lives as one chain-level test in `dartclaw_security` `network_guard_test.dart` evaluating a `beforeToolCall` context shaped like the inventory's output – named here so the three-package composition is proven once, not assumed from the per-layer unit tests.
- S01 completion is harness-boundary-provable: TI03 proves `TurnRunner` supplies the agent identity and TI04–TI06 prove each active host guard path receives it. Production `sessions_send` reachability depends on S02's pool-routing fix and is owned solely by S02's S03/live-smoke gate; it does not block S01 completion.

### Validation

### Execution Contract

- TI01 → TI02 → TI03 before any harness task; TI12 after TI02 (S02, S08–S11 need TI12 – S02/S08 also TI04; TI09's payload translation needs TI12's canonical defaults); TI04–TI07 are independent of each other after TI03; TI08 independent; TI10/TI11 last.

## Final Validation Checklist

- [x] Workspace-wide gate per `dev/guidelines/KEY_DEVELOPMENT_COMMANDS.md` (format, analyze, tests) – package-scoped analyze hides cross-package breaks from the `AgentHarness.turn` signature change.

## Implementation Observations

#### DECISION NOTE: search-agent-mcp-allow-set
Decision-Key: search-agent-mcp-allow-set
Altitude: project-decision
Affected surface: CanonicalTool + Claude/Codex protocol adapters, shared own-MCP semantic inventory, AgentDefinition.searchAgent defaults + fromYaml fallback, harness_wiring agents payload, scenarios S02/S04/S08/S11, tasks TI02/TI09/TI12
Decision: Semantic canonical mapping is cross-harness. One prebuilt own-MCP inventory maps exact tools to canonicals; Claude uses the raw MCP name and Codex uses the existing server/tool payload fields. Search/fetch map to web_search/web_fetch and memory_save maps exactly to memory_save. Third-party, unknown, sessions, task, and delegation tools remain mcp_call. The search agent keeps {web_search, web_fetch}; generic mcp_call never widens a semantic allow set.
Rationale: Reuses one mapping and the identity already supplied by each protocol, removes the Codex inconsistency, restores NetworkGuard visibility for own web_fetch, and supports the journal's exact memory_save boundary without another guard or provider special case.
Evidence: Owner interview 2026-08-05 (andthen:preflight); Codex mcp_tool_call items already carry server/tool fields in codex_protocol_utils.dart; startup exploration found that a prebuilt tool inventory can supply both harness mapping and live registration.

#### DECISION NOTE: canonical-web-search
Decision-Key: canonical-web-search
Altitude: fis-local
Affected surface: packages/dartclaw_core/lib/src/harness/canonical_tool.dart (CanonicalTool enum), claude_protocol_adapter.dart / codex_protocol_adapter.dart mapToolName, dev/adrs/016-multi-provider-harness-architecture.md Part 1 taxonomy table, task TI12
Decision: Add canonical web_search as the seventh CanonicalTool value. Claude WebSearch → web_search; Codex raw web_search remapped from web_fetch → web_search. ADR-016 Part 1 taxonomy table updated with an inline amendment note (repo precedent: the ADR-037 amendment note in the same file). NetworkGuard untouched – search calls carry a query, not a URL, so no URL-inspection surface changes.
Rationale: ADR-016 explicitly labels the six-value set an 'Initial taxonomy' with extension anticipated; without a search canonical, Claude WebSearch is unmappable (claude:WebSearch fallback) and the Codex web_search → web_fetch mapping is semantically wrong. Load-bearing for the search-agent-mcp-allow-set decision (semantic MCP mapping needs a search canonical to map to).
Evidence: Owner interview 2026-08-05 (andthen:preflight); doc-review finding R8 (HIGH, 2026-08-05); ADR-016 Part 1 ('Initial taxonomy').

#### DECISION NOTE: null-agent-networkguard-gating
Decision-Key: null-agent-networkguard-gating
Altitude: fis-local
Affected surface: OC01 exception clause, Required Context NetworkGuard commentary, scenario S09, NetworkGuard evaluation of remapped own-MCP web_fetch calls (all turns incl. main agent), TI10 operator docs, TI12
Decision: Accept the tightening. The TI12 remap deliberately makes NetworkGuard's domain allowlist apply to own-MCP web_fetch calls for every turn, including main-agent (agentId null) turns – no null-agent exemption or special case. OC01 and the null-agent-neutrality constraint carry an explicit carve-out; S09 pins the behavior; TI10 documents the operator impact (guards-on MCP deployments must maintain guards.network.allowed_domains).
Rationale: The current MCP path bypasses the domain allowlist entirely (the MCP web_fetch tool performs SSRF checks only, no domain gating) – the bypass is the bug, and restoring documented NetworkGuard coverage uniformly is the cleanest, most correct, least special-cased resolution. An agentId-null exemption would keep the guard hole open and add a permanent special case.
Evidence: Owner interview 2026-08-05 (andthen:preflight round 2, doc-review pass 2 finding N1, filter-verified conf 100: WebFetchTool has no internal domain allowlist); owner criteria: cleanest/most correct/least over-engineered.

#### DECISION NOTE: allowlist-entry-canonicalization
Decision-Key: allowlist-entry-canonicalization
Altitude: fis-local
Affected surface: ToolPolicyCascade build path (allow/deny entry normalization), scenario S10, TI02, TI10 guide migration note
Decision: Canonicalize entries. At cascade build, every allow/deny entry is normalized through a static known-name table (union of provider mappings: WebSearch→web_search, WebFetch→web_fetch, Bash→shell, Read→file_read, …), so matching succeeds in canonical space as well as raw-literal space; entries matching no known name stay literal. Guide examples move to canonical spellings (TI10) with a migration note.
Rationale: Doc-copied configs (tools: [WebSearch, WebFetch] – the exact spelling today's search.md/agents.md instruct) would otherwise brick the search agent under MCP + provider, since explicit lists bypass the fromYaml canonical default and literal entries match neither the MCP raw names nor their canonicals. Entry normalization is one deterministic table, keeps every existing config working with zero user action, and beats a warn-and-hope migration.
Evidence: Owner interview 2026-08-05 (andthen:preflight round 2, doc-review pass 2 finding N4, conf 75; filter-verified: guides instruct the raw spelling verbatim and agent_definition.dart:102 bypasses the default for explicit lists).

#### DECISION NOTE: deny-mcp-category-union
Decision-Key: deny-mcp-category-union
Altitude: fis-local
Affected surface: ToolPolicyCascade deny-layer matching for semantically-remapped own-MCP calls, TI02 (rule + Verify), TI10 workflows-reference note
Decision: Deny-side category union. On global and agent deny layers, every semantically remapped own-MCP call – including web_fetch, search providers, and memory_save – also matches mcp_call. The allow side stays semantic-only: listing mcp_call does not grant any exact remapped own tool.
Rationale: denied_tools: [mcp_call] means no MCP tools and must not narrow when exact semantics are added. Deny erring broad preserves current security configuration meaning; semantic-only allows keep journal/search policies closed.
Evidence: Owner interviews 2026-08-05 (andthen:preflight); cross-harness own-MCP mapping decision; prior filtered finding N8.

#### DECISION NOTE: acp-enforcement-scope
Decision-Key: acp-enforcement-scope
Altitude: fis-local
Affected surface: OC01 wording, Constraints Codex/ACP bullet, TI06 scope, TI08 warning variant, TI10 docs
Decision: Scope and document, like Codex. ACP is dropped from OC01's enforcement claim: its host-guard surface (fs reverse calls evaluate canonically; the permission seam passes the agent-supplied operation string as the guard tool name with no ACP raw→canonical mapping; calls requesting no permission never reach the host) is stated as a documented boundary in Constraints and TI10, TI06 remains identity plumbing only, and TI08's startup warning gains an ACP variant for sandboxed agents. No ACP name-domain machinery is specced.
Rationale: Same honesty posture ratified twice for Codex – document the real boundary instead of building speculative naming machinery on agent-controlled strings for the least-mature harness path; the non-permission-call bypass would persist regardless of any mapping.
Evidence: Owner interview 2026-08-07 (andthen:preflight round 3, doc-review pass 3 finding M7, filter-validated conf 75: harness_wiring.dart _acpPermissionDecision passes request.operation as toolName; no acp:<raw> fallback exists).
