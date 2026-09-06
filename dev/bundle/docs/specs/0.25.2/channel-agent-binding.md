# Channel Agent Binding (`agent:` on an allowlist row)

## Feature Overview and Goal

**Intent**: Every channel peer reaches the one primary lane today, so an owner who wants a narrower persona on a shared group — or a second identity for a family member's DM — has to run a second deployment; binding a row to a named logical agent gives that conversation its own tools, model and voice while it still reads and writes the owner's one workspace.

**Expected Outcomes**:

- [OC01] A peer or group whose allowlist row carries `agent: <name>` talks to that persona: its messages open and continue that agent's own session, and a peer with no `agent` on its row keeps the session it has today.
- [OC02] The bound conversation reads as the persona and not as the owner: the agent's `prompt` stands in for `SOUL.md` over the task composition (TOOLS, AGENTS, channel origin, memory-retrieval hint); the owner's USER.md and memory projection are absent, and the persona's turns never feed the owner's daily log or journal. Tool-mediated memory access is bounded by the agent's `tools`.
- [OC03] The bound conversation executes as the agent: its tools, model, effort, provider and execution profile, on worker capacity that queues rather than refusing, with the row's own `model`/`effort` still winning.
- [OC04] A binding never degrades silently: an unknown agent name refuses the load rather than routing the peer to the primary lane, and no allowlist write drops a row's binding.

## Required Context

- `dev/adrs/054-model-first-delegation-and-one-authority-per-concern.md#rule-2--one-authority-per-concern` – why the row lookup, the execution-policy resolution and the prompt composition each get exactly one owner here rather than a channel-side copy; the binding is deterministic routing, so it also sits inside the carve-out and never reaches a model turn.
- `packages/dartclaw_runtime/AGENTS.md#runtime-composition-libsrcruntime` – the composition-root rules this FIS threads through: a wiring module owns construction and hands collaborators to the surfaces that need them; `HarnessWiring` owns the one `ExecutionPolicyResolver`.
- `packages/dartclaw_core/AGENTS.md#boundaries` – `dartclaw_core` may not import `dartclaw_runtime`, which is why the bound agent's *identity* is resolved in core (the session key) while its *execution policy* is resolved in runtime.
- `packages/dartclaw_kernel/AGENTS.md#configuration` – `ConfigMeta.fields` is the only registry for operator-facing fields; the three `dm_allowlist` and three `group_allowlist` descriptions are the surface `agent` must appear on.
- `dev/architecture/session-state-architecture.md` – the `agent:<agentId>:<scope>:<identifiers>` key table (line 118 onward) is the contract the binding rides: the agent id is already a key component, so no session column and no migration are involved.
- `docs/guide/agents.md#logical-agent-configuration-reference` – the `agent.agents.<name>` shape a binding names, and the capacity boundary the bound lane now shares.
- `dev/state/PRODUCT.md` § *Single-owner, multi-client* – `main` is the admin conversation; channel-bound agents get workspaces of their own in the milestone after 0.26. Until then a bound persona has no vault, which is why this FIS composes the task scope and keeps the daily log to `main`.
- `dev/guidelines/KEY_DEVELOPMENT_COMMANDS.md#generated-artifacts` – the two regeneration commands for `schemas/dartclaw.schema.json` and the generated region of `docs/guide/configuration.md`, both of which any `ConfigMeta` description change drifts.
- `dev/adrs/033-architectural-governance-via-fitness-functions.md` – a package LOC ceiling raise is a recorded maintainer decision, not a silent edit; `dartclaw_runtime` currently measures 65 676 against a 65 700 ceiling, so this story needs one.

## Deeper Context

- `dev/state/SPEC-LIFECYCLE.md` – governs this file's own lifetime under `dev/bundle/`; it is a transient working copy, removed before the squash-merge.
- `dev/state/LEARNINGS.md` § *Config / YAML* – "A new `ConfigMeta` field drifts a third artifact": beside schema and reference, `packages/dartclaw/test/config_advisory_baseline_test.dart` regenerates with `DARTCLAW_UPDATE_CONFIG_ADVISORY_GOLDEN=1`.
- `docs/guide/security.md#hardening-the-primary-agent-for-untrusted-channels` – the existing posture for a lower-trust channel peer (deny tools on the primary). A binding is the finer-grained alternative and the guides should not contradict it.
- Upstream sources, both in the sibling **private** repo (`dartclaw-private/`) and not required to execute this FIS, which carries every decision they settle: `docs/specs/0.25.2/prd.md` § *Feature requests joining the patch* (items 1a/1b of the SecondBrain deployment feedback) and decisions **D13** (prompt composition, `prompt` stands in for SOUL.md), **D14** (the binding lives on the allowlist row only; precedence row → primary), **D15** (worker capacity with `wait` admission; the row's `model`/`effort` win), **D16** (no per-agent workspace).

## Acceptance Scenarios

- **S01 [OC01] [TI01,TI03,TI04,TI06] A DM row carrying `agent` opens that agent's session; a row without one is unchanged**
  - **Given** `channels.signal.dm_allowlist` holding the map row `{id: +46700000001, agent: ana}` and the plain string `+46700000002`, with `agent.agents.ana` declared
  - **When** each peer sends a direct message under each `dm_scope` value (`shared`, `per_contact`, `per_channel_contact`)
  - **Then** the first peer's derived key carries `ana` as its agent component and the second peer's key is byte-identical to the key the same config produced before this change (`main`), with the scope rule itself untouched in both cases

- **S02 [OC01] [TI01,TI03,TI04,TI14] A group row carrying `agent` binds the group, and a slash command in that space resolves the same session**
  - **Given** `channels.google_chat.group_allowlist` holding `{id: spaces/AAA, agent: ana}`
  - **When** a group message arrives, and separately a `/status` slash command is handled for the same space
  - **Then** both resolve through the one derivation and yield the same `ana`-scoped group key, so the command reports the bound session rather than the primary one

- **S03 [OC02] [TI06,TI07] A bound turn composes the persona over the task scope, without the owner's USER.md or memory**
  - **Given** a bound peer, `agent.agents.ana.prompt` non-empty, and a workspace holding `SOUL.md`, `USER.md`, `TOOLS.md`, `AGENTS.md` and a memory index
  - **When** that peer sends a message
  - **Then** the composed system prompt is the `PromptScope.task` composition — TOOLS, AGENTS and the memory-retrieval hint, plus the channel-origin section the primary lane gets — with `ana`'s `prompt` standing where `SOUL.md`'s body stands for the owner; USER.md, recent errors and the memory projection are absent; no `systemPromptOverride` is in play; and an agent whose `prompt` is empty inherits the workspace `SOUL.md`

- **S04 [OC02] [TI06,TI07] A bound agent resolving to the `restricted` container profile gets no identity**
  - **Given** a bound peer whose agent resolves to container profile `restricted`
  - **When** that peer sends a message
  - **Then** the turn composes `PromptScope.restricted` (tools only, no SOUL, no USER, no memory) exactly as a restricted task turn does, and the agent's `prompt` reaches nothing

- **S05 [OC03] [TI06,TI09] A bound turn runs with the agent's execution identity, and the row's own overrides still win**
  - **Given** a bound peer whose agent declares `provider`, `execution`, `security_profile`, `model` and `effort`, `agent.agents.ana.denied_tools` naming one tool, and the row itself declaring a different `model`
  - **When** that peer sends a message
  - **Then** the session is created pinned to the agent's provider, container profile and execution mode; the turn carries `ana` as its agent name, so the cascade applies `ana`'s policy whole — the named tool is denied, and a declared `allowed_tools` closes the set for this conversation exactly as it does for `ana` as a logical agent; the effective model is the row's and the effective effort is the agent's

- **S06 [OC03] [TI08] Bound conversations queue on worker capacity rather than failing fast, and a container-executed persona keeps its own worker**
  - **Given** `providers.<id>.pool_size: 2`, one worker already serving a bound peer's turn
  - **When** a second message arrives for that same bound peer while the first turn runs, and separately a message arrives for a peer bound to a different agent
  - **Then** neither is refused with the logical-agents' fail-fast capacity error — each waits for admission — and each request carries its own agent as the worker-reuse key, so under a container policy the second persona is never handed the first persona's cached worker. On a host policy the coordinator's existing provider-and-policy fallback still applies and the two may share a process, as every host lane does today (see *What We're NOT Doing*)

- **S07 [OC04] [TI05] An `agent` naming no declared agent refuses the load**
  - **Given** a config whose `channels.whatsapp.dm_allowlist` row carries `agent: nope` with no `agent.agents.nope`
  - **When** the config is loaded through the one production load path
  - **Then** the load fails with a message naming the channel, the row id and the unknown agent, and nothing starts serving — the peer is never silently routed to the primary lane

- **S08 [OC04] [TI10] An allowlist write keeps every structured row intact**
  - **Given** `dm_allowlist` holding one map row with `agent:` and one plain string
  - **When** a peer is added through `POST /api/config/channels/<type>/dm-allowlist`, then removed again, and separately a pending DM pairing is confirmed
  - **Then** the map row survives every write with its `agent` intact, the added entry is present exactly once, removing an id that belongs to a map row removes that row rather than leaving it behind, and every allowlist read still answers a list of ids — so the bound peer stays listed on the settings channel page instead of disappearing from it

- **S09 [OC01] [TI04] A scheduled `announce` reaches the bound peer's conversation**
  - **Given** a bound DM peer with an existing bound channel session, and a `delivery: announce` job that has produced a result
  - **When** the announce is delivered
  - **Then** the peer receives the message once and the announce is recorded in the bound session's transcript with that session's continuity reset — the delivery path resolves its targets from stored channel sessions and never rebuilds a key with a default agent id

- **S10 [OC02] [TI15] A persona's turns never reach the owner's daily log**
  - **Given** a bound DM peer whose turn used tools, and an unbound peer whose turn used tools
  - **When** both turns complete
  - **Then** the daily activity log gains one entry, for the unbound (`main`) turn, and the bound turn appends nothing — so the nightly journal never folds a persona's conversation into the owner's memory

## Structural Criteria

- **SC01** A row without `agent` changes nothing downstream: the plain id list every consumer of the parsed DM list takes — the three `DmAccessController` constructions in `channel_wiring.dart`, Signal's E.164/UUID advisory, `config_serializer.dart` — is the same list it is today, and no channel package gains a dependency on agent definitions or execution policy. (`inbound_gate.dart` never sees the DM list; it takes a `DmAccessController?` and the group id list.)
- **SC02** One row-resolution authority: a `(channel, scope, id)` allowlist-row lookup happens in exactly one type, which both the session-key derivation and the model/effort precedence chain consume; `runtime/model_resolver.dart` derives no group id from a session key; and every production builder of a channel session key — the derivation and `session/group_session_initializer.dart` — carries the row's `agent`, so a bound group has no unbound twin.
- **SC03** No storage change: the bound agent id lives only in the session key string — no session column, no migration, no schema edit, and `SessionKey`'s factories keep their `'main'` defaults.
- **SC04** The bound dispatch reuses the logical-agent recipe rather than copying it: `ExecutionPolicyResolver.resolveForAgent` stays the one policy authority and the channel path constructs no second resolver, and the identity arrives as composed behaviour files, never `systemPromptOverride`.
- **SC05** `agent` is registered exactly once per field in `ConfigMeta.fields`, and the two generated artifacts derived from it — `schemas/dartclaw.schema.json` and the generated region of `docs/guide/configuration.md` — carry it with no drift.
- **SC06** No shipped document still describes an allowlist row as an id or a group-only map: the three channel guides, the agents guide and `CHANGELOG.md` all state `agent` on both lists, and the agents guide states the worker-slot cost.
- **SC07** The workspace package-LOC gate passes with the `dartclaw_runtime` ceiling re-cut and its necessity recorded in `dev/tools/arch_check.dart` in the form the 2026-09-06 entry uses.

## Scope & Boundaries

### Work Areas

- `packages/dartclaw_core/lib/src/scoping/`: `group_entry.dart` (the `agent` key, field-labelled warnings), `common_channel_fields.dart` (`dm_allowlist` parsed as rows), `group_config_resolver.dart` (DM rows and the DM lookup).
- `packages/dartclaw_core/lib/src/channel/channel_manager.dart`: the one row lookup and the bound agent id on every `SessionKey` dm/group factory call; `packages/dartclaw_runtime/lib/src/session/group_session_initializer.dart`: the same agent id on the group sessions it pre-creates.
- `packages/dartclaw_signal`, `packages/dartclaw_whatsapp`, `packages/dartclaw_google_chat`: each config's `dmAllowlist` becomes a row list with a `dmIds` getter, mirroring the group side; consumers switch to `dmIds`.
- `packages/dartclaw_runtime/lib/src/runtime/{channel_wiring,model_resolver}.dart` and `lib/src/config/config_load.dart`: the resolver built once before the channel manager, the bound dispatch, the precedence chain, and the load-time refusal of an unknown agent name.
- `packages/dartclaw_runtime/lib/src/turn_manager.dart` and `lib/src/behavior/behavior_file_service.dart`: the SOUL stand-in and the per-persona worker lease. No `TurnManager` signature changes, so `dartclaw_core`'s interface and `dartclaw_testing`'s fake are untouched.
- `packages/dartclaw_runtime/lib/src/api/channel_access_service.dart` and `packages/dartclaw_kernel/lib/src/config_writer.dart`: allowlist reads and writes that preserve a structured row.
- `packages/dartclaw_kernel/lib/src/config_meta/channel_fields.dart` plus the regenerated schema, config reference and advisory golden; `docs/guide/{whatsapp,signal,google-chat,agents}.md`, `CHANGELOG.md`, `dev/architecture/{channel-messaging,session-state}-architecture.md`, `dev/tools/arch_check.dart`.

### What We're NOT Doing

- **Per-agent `workspace`** -- deferred to the agent-workspace milestone sequenced straight after 0.26 (private D16): a persona's own identity files, memory corpus, daily log and journal, container mount and skills, keyed by the `user_id` tenancy dimension 0.26 FR3 puts into `FullTextIndex`, with wiki and knowledge graph staying the owner's behind the context engine. This FIS is that milestone's routing prerequisite and deliberately leaves a bound persona without a vault rather than lending it the owner's.
- **A channel-level default agent or a `bindings:` table** -- both create a second answer to "who handles this peer" beside the row (private D14). The row is twenty lines; a whole-channel case has not appeared.
- **Web-session binding** -- the web UI is the owner's own console and has no peer identity to bind. Web sessions stay on the primary agent.
- **Renaming `GroupEntry` / `GroupConfigResolver` now that both cover DM rows** -- the coherent rename spans two core types, three channel packages, their tests and two architecture docs, is entirely mechanical, and none of it is required for the binding. Their dartdoc states the widened scope instead. Owner-pinned scope call, not a claim the names are right.
- **Session titles and sidebar naming for a bound conversation** -- the key carries the agent id and the existing title logic is untouched; how a persona is named in the session list belongs to the Chat & Sessions milestone.
- **Per-persona worker-process isolation on the host lane** — settled as the status quo, no code change. `ExecutionCoordinator._takeCached` compares `logicalAgentId` only under a container policy; its non-container fallback matches on provider and execution policy alone, and host-lane cached-worker reuse stays keyed that way, exactly as it is today for every named agent on the logical-agent lane. A reused worker serves DartClaw sessions serially, each resuming its own provider session, with the system prompt composed per turn and the tool cascade evaluated per turn by agent id, so the binding introduces no sharing the logical-agent lane does not already have; widening `_takeCached` would change cached-worker reuse for every lane to serve a case with no evidence. **Revisit on**: evidence of state crossing sessions through a reused host worker — and then widen for all lanes, not for the binding alone.
- **Showing a row's binding on the settings channel page or the allowlist API** -- both project an allowlist to a list of ids, and TI10 keeps a bound peer listed by that id, so nothing disappears; rendering `agent` beside it is a UI change with its own fragment and design-system work, and no scenario here needs it.

## Architecture Decision

**Approach**: `agent: <name>` on an allowlist row selects the `agentId` component the session key already has, and everything downstream follows from the key: the session is created pinned with `resolveForAgent` exactly as a logical-agent session is, the turn carries the agent's name so the existing tool cascade and worker-reuse keys apply, and the persona reaches the prompt as a `BehaviorFileService` whose SOUL is the agent's `prompt`.
**Why this over alternatives**: the key format, the pinning recipe, the tool cascade and the `behaviorOverride` seam all already exist and are already exercised by the logical-agent and task lanes — binding is a routing decision, so the only new thing is *which* agent id the derivation produces. A `bindings:` table or a `systemPromptOverride` persona would each add a second authority beside one that already works.

## Technical Overview

`SessionKey`'s dm/group factories already take an `agentId` that every channel caller leaves at `'main'`; `ChannelManager.deriveSessionKey` is the single place that choice is made for an inbound message, and it becomes the single place the bound row is looked up. It is not the only production builder of a channel key: `session/group_session_initializer.dart` pre-creates and titles one session per allowlisted group at startup and on every `group_allowlist` change, so it must pass the same row's `agent` or a bound group gets a titled `main` twin beside the session its messages actually land in. The lookup itself is the existing `GroupConfigResolver`, widened to hold DM rows beside group rows, and `CommonChannelFields` now parses `dm_allowlist` through `GroupEntry.parseList` so both lists carry the same row form — the channel packages keep consuming a plain id list through a `dmIds` getter, so no access check, no Signal UUID advisory and no settings surface changes shape. Because the row is now resolved from the message rather than re-derived from the key, `resolveChannelTurnOverrides` takes the resolved row in place of its resolver argument and retires its group-id-from-key decoding — it keeps the session key, which still selects the per-channel scope override and gates the crowd-coding fallback. In `ChannelWiring`, the resolver is built from the three resolved channel configs before the channel manager is constructed, and both dispatch sites resolve one row for both purposes. A bound dispatch then mirrors `harness_wiring.dart`'s logical-agent dispatch: `resolveForAgent(definition, providerId:)` → `getOrCreateByKey(key, type: SessionType.channel, provider:, securityProfile:, executionMode:)` → `reserveTurn(..., agentName: <bound>, behaviorOverride: <behaviour with the agent's prompt as SOUL>)` → `executeTurn` → `waitForOutcome` — the `task_executor.dart` / `service_wiring_workflow.dart` shape, which is where `behaviorOverride` lives. It lives there and nowhere else because it takes a `dartclaw_runtime` type, so the bound branch narrows `dispatchChannelTurn`'s `turnManagerGetter` to the runtime manager rather than widening `dartclaw_core`'s interface; the unbound branch keeps today's `startTurn` call unchanged. Nothing else is needed at turn level: the pinned session already resolves its own policy through `_sessionExecutionPolicy`, so this path passes no `workerPolicy` even though the logical-agent dispatch does; the harness already receives a non-`main` agent name, and `ToolPolicyCascade.isAllowed` already scopes by it. Unknown agent names are refused where both halves of the config are visible for the first and only time — `loadDartclawConfig`, the one production load path, which already resolves every channel section.

## Code Patterns & External References

```
# type | path#anchor                                                              | why needed (intent)
file   | packages/dartclaw_core/lib/src/scoping/group_entry.dart#GroupEntry       | the row type and its parseList: known-key set, duplicate rule, warning shape
file   | packages/dartclaw_core/lib/src/scoping/group_config_resolver.dart#GroupConfigResolver | the lookup being widened; note fromChannelEntries drops all-null rows, which `agent` must now count against
file   | packages/dartclaw_core/lib/src/channel/channel_manager.dart#deriveSessionKey | the one derivation, and the scope switches the agent id rides through
file   | packages/dartclaw_runtime/lib/src/session/group_session_initializer.dart#_ensureGroupSessions | the second key builder: already iterates GroupEntry rows, so entry.agent is in hand
file   | packages/dartclaw_runtime/lib/src/runtime/harness_wiring.dart#_logicalAgentSessions | the recipe to mirror, in the closure wired there (the class itself lives in dartclaw_core): resolveForAgent, pinned getOrCreateByKey, agent-named reserveTurn + executeTurn
file   | packages/dartclaw_runtime/lib/src/task/task_executor.dart#promptScope     | the precedent for restricted-profile scope selection (containerProfile == 'restricted')
file   | packages/dartclaw_runtime/lib/src/runtime/service_wiring_workflow.dart    | the precedent for handing a turn its own BehaviorFileService as behaviorOverride
file   | packages/dartclaw_runtime/lib/src/behavior/behavior_file_service.dart#composeSystemPrompt | _addGlobalSoul is the one SOUL hook; composeStaticPrompt is the append-strategy twin that must match
file   | packages/dartclaw_runtime/lib/src/turn_manager.dart#TurnManager           | _reserveExecutionForSession: where admission and logicalAgentId are chosen
file   | packages/dartclaw_runtime/lib/src/config/config_load.dart#loadDartclawConfig | the one production load path, already resolving every channel section
file   | packages/dartclaw_kernel/lib/src/agent_definition.dart#parseExecutionMode | the load-time refusal idiom: FormatException naming the yaml path and the accepted values
file   | packages/dartclaw_runtime/lib/src/api/channel_access_service.dart         | the allowlist mutation that currently round-trips through a string list
```

## Constraints & Gotchas

- **Critical**: `ConfigWriter.readChannelAllowlist` returns `value.whereType<String>()`, and `ChannelAccessService._mutateAllowlist` writes that list back whole — so any allowlist write today silently deletes every structured row, and `confirmPairing` writes from the controller's id set, which never held one. -- Must handle by: reading rows without narrowing, sourcing the current list from that read for DM lists too (`_mutateAllowlist` takes it from the `DmAccessController`'s id set whenever one exists, so un-narrowing the read alone leaves every DM binding flattened), matching and removing by id, and writing the preserved rows back. Without this the first pairing confirmation erases every binding the operator just configured. The same fix closes the pre-existing group-row case; that is the minimum, not an invitation to redesign the endpoint.
- **Critical**: `GroupConfigResolver.fromChannelEntries` stores only rows carrying at least one non-null optional field. -- Must handle by: counting `agent` in that test, or a row whose only content is its binding is dropped and the peer silently falls back to the primary lane — the exact failure the load-time refusal exists to prevent.
- **Critical**: `behaviorOverride` takes a `BehaviorFileService`, a `dartclaw_runtime` type, so it exists only on the runtime `TurnManager.reserveTurn` — not on `dartclaw_core`'s `TurnManager` interface, which `dartclaw_testing`'s fake (kernel + core only) also implements. Putting it there would make core import runtime and fail the tier gate. -- Must handle by: leaving the core interface and every `startTurn` implementation alone and narrowing the bound branch to the runtime manager's `reserveTurn` + `executeTurn`, the only shape the two existing `behaviorOverride` callers use. Resist adding a `workerPolicy` beside it — the pinned session already supplies its own execution policy on this path.
- **Constraint**: the agent name is one identity, not a menu — carrying `ana` into a channel turn applies every surface already keyed by an agent id, not just `denied_tools`: a declared `allowed_tools` becomes a closed set for that conversation, and under a container policy the bridged MCP grant and the gateway principal are the ones `ana` already gets as a logical agent. -- Workaround: none is wanted. This is what "the bound conversation gets that agent's tools" means, and a bound peer that must keep a wider grant is an agent-definition change, not a binding one.
- **Avoid**: giving a bound turn a `systemPromptOverride`. -- Instead: compose behaviour files with the agent's `prompt` in the SOUL position. `systemPromptOverride` replaces the whole prompt, which would drop TOOLS, AGENTS and the channel origin — the opposite of what a bound conversation is for (private D13).
- **Avoid**: special-casing `DmScope.shared` for a bound peer. -- Instead: let the agent id ride the existing scope rule unchanged, so `shared` means one session per agent lane — bound peers of one persona share a session, unbound peers keep the primary shared session. A per-peer exception here would be a second scope rule nothing asked for.
- **Constraint**: `packages/dartclaw_core` cannot import `dartclaw_runtime`, so the row-to-agent-id decision (core) and the agent-id-to-execution-policy decision (runtime) are deliberately split across the two packages. -- Workaround: core resolves identity only; `ChannelWiring` receives the one `ExecutionPolicyResolver` and the agent definitions from `HarnessWiring`, which `_wireChannels` already has in hand.
- **Critical**: a bound persona has no vault of its own yet and must not borrow the owner's. -- Must handle by: composing `PromptScope.task` (no USER.md, no memory projection), keeping the daily log to `main` turns (TI15), and keeping every workspace-rooted service shared and unparameterised; partitioning memory, wiki or inbox per persona is the agent-workspace milestone's work, not this feature's.

## Implementation Plan

### Implementation Tasks

- **TI01** Both allowlists carry the same row form, and `agent` is one of its keys
  - `GroupEntry` gains an `agent` field in its known-key set, `==`, `hashCode` and `toString`; `parseList` takes the config path it is parsing and uses it in place of the literal `GroupEntry` prefix its four warnings carry today — three as `GroupEntry: …`, the missing-id one as `GroupEntry map missing or invalid "id" field …` — so a DM row's advisory names `dm_allowlist`. `CommonChannelFields.dmAllowlist` becomes a `List<GroupEntry>` parsed by `parseList`, mirroring `groupAllowlist`.
  - **Verify**: `packages/dartclaw_core/test/scoping/group_entry_test.dart#agent binding` – a string row parses with a null `agent`, a map row parses its `agent`, an unknown key still warns naming the field's config path, and the duplicate and empty-id rules are unchanged
  - **SATISFIES**: S01, S02, SC01

- **TI02** Each channel config exposes DM rows and the id list its access checks consume
  - `SignalConfig`, `WhatsAppConfig` and `GoogleChatConfig` hold `dmAllowlist` as `List<GroupEntry>` with a `dmIds` getter beside the existing `groupIds`; the three `DmAccessController` constructions in `channel_wiring.dart`, Signal's E.164/UUID advisory loop and `config_serializer.dart` read `dmIds`, so their logic is untouched. `settings_page.dart` is not on this list — it renders `ChannelAccessService.readAllowlist` and `dmAccess.allowlist`, never the parsed config field.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_signal/test/signal_config_test.dart packages/dartclaw_google_chat/test/google_chat_config_test.dart packages/dartclaw_whatsapp/test/config_registration_test.dart packages/dartclaw_runtime/test/config/config_serializer_test.dart` – every suite passes, so the DM advisories, the serializer projection and the allowlist shapes are unchanged for plain-string rows
  - **SATISFIES**: SC01

- **TI03** One resolver answers which allowlist row owns a conversation, for both scopes
  - `GroupConfigResolver` takes DM rows per channel beside group rows and answers a DM lookup by peer id; a row is retained when it carries `agent` as well as when it carries `name`, `project`, `model` or `effort`. Its dartdoc states that it now covers both allowlists.
  - **Verify**: `packages/dartclaw_core/test/scoping/group_config_resolver_test.dart#dm rows` – a DM row carrying only `agent` resolves, a plain-string DM row resolves to null, a group id and a peer id with the same literal value do not collide, and the existing group cases pass unchanged
  - **SATISFIES**: S01, S02, SC02

- **TI04** `ChannelManager.deriveSessionKey` returns the bound agent's key
  - The manager takes the TI03 resolver, exposes the one row lookup for a `ChannelMessage` (group by `groupJid`, else DM by `senderJid`), and passes the row's `agent` — or `'main'` — as `agentId` to every dm/group `SessionKey` factory. The scope switches themselves are unchanged, so `DmScope.shared` yields one session per agent lane.
  - **Verify**: `packages/dartclaw_core/test/channel/channel_manager_test.dart#agent binding` – for each `dm_scope` and `group_scope` value a bound row yields the agent-prefixed key and an unbound sender yields the exact key the same config yields today; a manager wired without a resolver derives `main` throughout
  - **SATISFIES**: S01, S02, S09, SC03

- **TI05** An `agent` naming no declared agent refuses the load
  - `loadDartclawConfig` — the one production load path, which already resolves every channel section — checks every allowlist row's `agent` against `config.agent.agents` and throws a `FormatException` naming the channel, the list, the row id and the unknown name, in the `agent_definition.dart#parseExecutionMode` idiom. Fail-closed by choice: a warning would leave a narrower-trust peer silently on the primary lane.
  - **Verify**: `packages/dartclaw_runtime/test/config/channel_config_resolver_test.dart#unknown bound agent` – a config binding a row to an undeclared agent throws with the channel, row id and name in the message; the same config with the agent declared loads; a config whose DM rows are all plain strings loads with the same warning count as before (a malformed DM map, dropped silently by `_parseStringList` today, now warns — that is the row form, not a regression)
  - **SATISFIES**: S07

- **TI06** A bound conversation runs as its agent, with the persona in the prompt
  - `ChannelWiring` builds the TI03 resolver from the three resolved channel configs before constructing the channel manager, and receives `HarnessWiring`'s one `ExecutionPolicyResolver` and the agent definitions (`_wireChannels` already holds the `HarnessWiring`). The default provider id is today a local in `HarnessWiring.wire()`, so `HarnessWiring` exposes it as a getter rather than `ChannelWiring` normalising `config.agent.provider` a second time. Both dispatch sites resolve one row and, when it is bound, `dispatchChannelTurn` pins the session with `resolveForAgent` (`provider`, `securityProfile`, `executionMode`) and starts the turn with the agent's name plus a `behaviorOverride` carrying its `prompt` as SOUL — `PromptScope.task`, never `systemPromptOverride`. A resolved container profile of `restricted` selects `PromptScope.restricted` and no behaviour override, the `task_executor.dart` precedent. An unbound row takes today's call unchanged.
  - **Verify**: `packages/dartclaw_runtime/test/runtime/channel_wiring_test.dart#bound channel turn` – a bound peer's session is created with the agent's provider, profile and mode and its turn carries the agent name and the persona-composed behaviour under `PromptScope.task`; a `restricted` agent's turn carries `PromptScope.restricted` and no override; an unbound peer's session and turn arguments are identical to the pre-change call
  - **SATISFIES**: S01, S03, S04, S05, SC04

- **TI07** The agent's `prompt` stands in for `SOUL.md` over the task composition, with the channel origin
  - `BehaviorFileService` gains an optional SOUL stand-in used by `_addGlobalSoul`, so both `composeSystemPrompt` and `composeStaticPrompt` (the append-strategy twin) honour it, plus a copy method producing that variant while sharing workspace dir and every other collaborator. The channel-origin section moves out of the primary-only block so a task-scope turn that carries a `TurnOrigin` gets it too (task turns pass none today, so nothing else changes). An empty or whitespace-only agent `prompt` yields no variant, so the workspace `SOUL.md` is inherited. No `TurnManager` signature changes: the runtime manager's `reserveTurn` already carries `behaviorOverride` and `promptScope`, and TI06's bound branch passes the variant with `PromptScope.task` through a runtime-typed getter, so `dartclaw_core`'s interface, the runner, `dartclaw_testing`'s fake and the runtime test fixture all stay untouched.
  - **Verify**: `packages/dartclaw_runtime/test/behavior/behavior_file_service_test.dart#soul stand-in` – the variant's task composition carries the stand-in where the workspace SOUL body would be and the channel-origin section when an origin is given, contains no USER.md section and no memory projection, is otherwise section-for-section identical to the base service's task composition, the append-strategy composition matches, and a blank stand-in composes exactly as the base service
  - **SATISFIES**: S03, S04

- **TI08** A bound turn waits for admission and carries its persona as the worker-reuse key
  - In `turn_manager.dart`'s execution reservation the worker-reuse key is the turn's agent name whenever it is not `main`, so `ExecutionCoordinator._takeCached`'s container-policy clause partitions cached workers per persona; fail-fast admission stays confined to `SessionType.logicalAgent`, so a bound channel session keeps waiting (private D15). The coordinator itself is not touched: its non-container fallback matches on provider and policy alone, which is why S06 claims host-lane process isolation for neither personas nor anything else.
  - **Verify**: `packages/dartclaw_runtime/test/turn_manager_execution_policy_test.dart#bound channel lease` – a channel-session turn named for an agent requests waiting admission carrying that agent as its worker-reuse key, a logical-agent turn still requests fail-fast, and a `main` channel turn requests exactly what it does today
  - **SATISFIES**: S06

- **TI09** The row's own model and effort still win over the agent's and the channel's
  - `resolveChannelTurnOverrides` takes the row resolved in TI04 in place of its `groupConfigResolver` argument, and only that argument: it still needs the session key for the two other links of the chain — `channelTypeFromSessionKey` selects the per-channel scope override, and the crowd-coding fallback is gated on `parsed?.scope == 'group'`. Retiring the key would silently delete both. What retires is `_groupIdFromSessionKey`, now that the row arrives resolved. The chain stays row → channel → scope → crowd, and a DM row's `model`/`effort` become effective for the first time, which is what S05 asks for. The agent's own `model`/`effort` are supplied by the TI06 dispatch and are therefore below the row.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/runtime/model_resolver_test.dart` – the whole suite passes: a row's model and effort win over channel, scope and crowd values; a null row falls through the same chain as today; DM rows and group rows resolve through the same argument
  - **SATISFIES**: S05, SC02

- **TI10** An allowlist write preserves every structured row
  - `ConfigWriter.readChannelAllowlist` returns the stored rows without narrowing to strings, and `ChannelAccessService`'s allowlist mutation sources its current list from that read for **both** lists: today `_mutateAllowlist` takes `controller?.allowlist.toList() ?? await writer.readChannelAllowlist(...)`, so for a DM list with a `DmAccessController` the current list is the controller's plain id set and never the stored rows — un-narrowing the read alone would still flatten every DM binding. The mutation and the pairing confirmation match, remove and write over the stored rows by id — a map row by its `id`, a plain string by its value — while the DM controller is still updated with the plain id. Every read the API and the settings page answer stays a list of ids — a preserved row projects to its `id`, so an operator sees the bound peer listed rather than vanished; rendering the binding beside it is out of scope. Depends on nothing else here; it also closes the same pre-existing loss for group rows.
  - **Verify**: `packages/dartclaw_runtime/test/api/config_api_allowlist_test.dart#structured rows survive` – adding, removing and confirming a pairing each leave an untouched map row byte-identical in the written YAML, removing a map row's id removes that row, adding an id a map row already holds is refused as a duplicate, and the read response lists a map row's id alongside the plain-string entries
  - **SATISFIES**: S08

- **TI11** The generated config artifacts and the advisory golden state the row form
  - The three `dm_allowlist` and three `group_allowlist` `FieldMeta` descriptions in `config_meta/channel_fields.dart` name `agent` and give DM rows the same "maps carrying an id plus optional …" sentence group rows already have. Both generated artifacts and the advisory golden are regenerated, never hand-edited (`dev/state/LEARNINGS.md` § Config / YAML).
  - **Verify**: `cmd: dart run packages/dartclaw_kernel/tool/generate_config_schema.dart --check && dart run dev/tools/render_config_reference.dart && rg -c 'agent' docs/guide/configuration.md > /dev/null && dart test --reporter=failures-only packages/dartclaw_kernel/test/config_meta_test.dart packages/dartclaw/test/config_advisory_baseline_test.dart` – the schema check reports no drift, the reference regenerates, and both the registry gate and the advisory golden pass
  - **SATISFIES**: SC05

- **TI12** Operator and contributor documents state the binding and its cost
  - `docs/guide/{whatsapp,signal,google-chat}.md` state `agent: <name>` on both allowlists beside the existing structured-entry paragraphs and point at the agents guide; `docs/guide/agents.md` gains the channel-binding section — what a bound conversation inherits, that its prompt is the persona over the task composition (the agent's `prompt` as SOUL, TOOLS, AGENTS, channel origin) without the owner's USER.md or memory, that its turns never feed the owner's daily log, that tool-mediated memory access is bounded by the agent's `tools`, that precedence is row → primary, and that each persona chatting concurrently consumes a `providers.<id>.pool_size` slot. `CHANGELOG.md` gains an entry under the existing `## [Unreleased]` heading; `dev/architecture/channel-messaging-architecture.md` and `dev/architecture/session-state-architecture.md` describe the binding in their derivation and key sections and bump their "Current through" markers.
  - **Verify**: `cmd: for f in docs/guide/whatsapp.md docs/guide/signal.md docs/guide/google-chat.md docs/guide/agents.md CHANGELOG.md dev/architecture/channel-messaging-architecture.md dev/architecture/session-state-architecture.md; do rg -q 'agent: ' "$f" || exit 1; done; rg -q 'pool_size' docs/guide/agents.md` – every hand-written document carries the row form, and the agents guide states the worker-slot cost
  - **SATISFIES**: SC06

- **TI14** The pre-created group sessions carry the same binding
  - `session/group_session_initializer.dart` already iterates `GroupEntry` rows, so `_ensureGroupSessions` passes `entry.agent` (else `'main'`) to `SessionKey.groupShared` on both its paths — the startup sweep and the `ConfigChangedEvent` handler. Without it a bound group is pre-created and titled under `main` while its messages open the `ana` key, leaving a titled twin in the session list and the real conversation untitled.
  - **Verify**: `packages/dartclaw_runtime/test/session/group_session_initializer_test.dart#bound group` – a bound group row pre-creates exactly one session and its key carries the agent component, an unbound row pre-creates the key it does today, and the existing title-resolution cases pass unchanged
  - **SATISFIES**: S02, SC02

- **TI15** A persona's turns skip the owner's daily log
  - `_appendDailyLog` in `turn_runner_memory.dart` already reads the active turn's `agentName` for memory attribution; it returns before writing whenever that name is not `main`, beside the existing session-type predicate. Host-enforced, no config.
  - **Verify**: `packages/dartclaw_runtime/test/turn_runner_daily_log_test.dart#bound persona turns` – a channel-session turn named for an agent appends nothing after a tool-using result, a `main` channel turn with the same result appends exactly what it does today, and the existing session-type cases pass unchanged
  - **SATISFIES**: S10

- **TI13** The workspace package-LOC gate passes with the runtime ceiling re-cut
  - `dartclaw_runtime/lib` measures 65 676 against a 65 700 ceiling before this story, so its net growth needs a raise recorded in `dev/tools/arch_check.dart` in the "Reviewed necessity" form the 2026-09-06 entry uses, naming what the story added and why nothing came out. Re-cut to `_maxCeilingFor(measured)` on the finished tree; the other packages have band headroom and must not be touched.
  - **Verify**: `cmd: dart run dev/tools/arch_check.dart` – all checks pass, including the twelve-package count and every untouched ceiling
  - **SATISFIES**: SC07

### Execution Contract

- TI03 depends on TI01's `agent` field; TI04 on TI03; TI14 on TI01's `agent` field; TI06 on TI03, TI04 and TI07's behaviour variant; TI09 on TI04's row lookup. TI02, TI05, TI10, TI11, TI12, TI14 and TI15 are independent of each other.
- TI13 measures the finished tree, so it runs last.
- `dart run dev/tools/embed_assets.dart` is required after a fresh clone or worktree before `dart analyze` or any runtime test; no template in this story changes.

## Implementation Observations

### Run: 2026-09-06 18:04 UTC – discovered-requirements

#### DISCOVERED REQUIREMENTS

- **DR01** A bound channel turn is reserved on the worker lane. `ExecutionCoordinator._laneFor` sends every `ExecutionSurface.channel` request to the primary lane and `_routeRequest` rewrites it to the primary's provider and policy, so a session pinned to the agent's provider and container profile would still execute as the primary – OC03 would degrade silently, and TI08's `_takeCached` persona clause applies to the logical-agent surface only. `_reserveExecutionForSession` therefore presents a channel-session turn named for an agent as `ExecutionSurface.logicalAgent` while admission stays `wait` (the session type is still `channel`), which is the lane and admission S06 describes.

### Run: 2026-09-06 18:13 UTC – observations

#### NOTICED BUT NOT TOUCHING

- The agent's own `model`/`effort` sit below the whole channel chain (row → channel scope → scope global → crowd → agent), because TI09 keeps `resolveChannelTurnOverrides` row-only and TI06 hands its result to the dispatch as `model ?? agent.model`; a `sessions.scope.model` therefore beats a bound agent's `model`. S05 holds either way. Placing the agent between row and channel would need the agent in the resolver's argument list, which TI09 rules out.
- `confirmPairing` and the allowlist mutation now write the stored rows plus the confirmed id; the previous code wrote the `DmAccessController`'s whole in-memory set, which also persisted Signal's sealed-sender self-healed entries as a side effect. Those entries stay in memory only now (the controller still answers for them on add/remove), as TI10 directs.
- `GroupSessionInitializer._onConfigChanged` parses the new list with `GroupEntry.parseList`, so a `name` on a row added at config-change time now titles the pre-created session; the retired hand-rolled extraction dropped every field but `id`. Causally required for `agent` and one parser authority.
- `dev/state/UBIQUITOUS_LANGUAGE.md` has no term for an allowlist row or a channel agent binding; `GroupEntry` / `GroupConfigResolver` keep their names per *What We're NOT Doing*.
- `docs/guide/security.md#hardening-the-primary-agent-for-untrusted-channels` does not mention the binding as the finer-grained alternative; it does not contradict it either, and the FIS names only the three channel guides and the agents guide.
