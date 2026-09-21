# Provider-reported model catalogue

**Plan**: dev/bundle/docs/specs/0.27-model-catalogue/plan.json
**Story-ID**: S01

## Feature Overview and Goal

**Intent**: The composer's model picker offers a hardcoded, already-stale list of raw aliases (Claude `sonnet, opus, haiku` without Fable or the 1M default; Codex no models and efforts missing `max`/`ultra`), and the pill names only the provider, so the owner cannot pick every model their account has or see which model a turn will run.

**Expected Outcomes**:

- [OC01] The model picker lists every model the provider offers the account, each by the provider's own human-readable name.
- [OC02] The effort picker offers exactly the efforts the selected model supports.
- [OC03] The composer pill and the topbar crumb name the model – including what Default resolves to – by that human-readable name, never by a raw alias the provider has named.
- [OC04] Discovery runs no model turn and never blocks or breaks the chat page: before or without a catalogue the pickers still offer Default and any staged value.


## Required Context

- `dev/architecture/control-protocol.md#41-initialize-handshake` – where the Claude `initialize` control response is received today; the catalogue's `models` rows arrive in that same response.
- `dev/architecture/control-protocol.md#codex-json-rpc-protocol` – the Codex `initialize`/`thread/start` exchange the Codex discovery extends with `model/list`.
- `dev/state/DECISIONS.md` § Still Current, bullet "Composer context is two popovers over one apply path, with adapter-declared catalogues" – the rule this story replaces: the adapter stays the only authority, but its catalogue now comes from the provider process instead of a constant.
- `docs/guide/web-ui-and-api.md#features` – the **Effective context** bullet describing the pickers' contents.

### Wire shapes observed 2026-09-21 (claude 2.1.278, codex-cli 0.155.1)

> Claude `initialize` control_response → `response.response.models[]`, one row per model (the `default` row is the account default):
> `{"value":"opus[1m]","resolvedModel":"claude-opus-5[1m]","displayName":"Opus (1M context)","description":"Opus 5 with 1M context · …","supportsEffort":true,"supportedEffortLevels":["low","medium","high","xhigh","max"]}`
> `{"value":"haiku","resolvedModel":"claude-haiku-4-5-20251001","displayName":"Haiku","description":"Haiku 4.5 · …"}` – no effort fields
> Rows seen: `default` "Default (recommended)", `opus[1m]` "Opus (1M context)", `claude-fable-5-1[1m]` "Fable", `sonnet` "Sonnet", `haiku` "Haiku". Optional row field `disabled` (visible, not selectable).
> Claude `get_settings` control request → `applied.model`: the id this process runs (`claude-opus-5[1m]` with `--model opus[1m]` or no flag; `claude-sonnet-5` with `--model sonnet`). Match it against rows' `resolvedModel`, skipping `default`.
> Codex `model/list` params `{cursor, limit, includeHidden}` → `{data: Model[], nextCursor}`; `Model` requires `id, model, displayName, description, hidden, isDefault, defaultReasoningEffort, supportedReasoningEfforts` where `supportedReasoningEfforts` is `[{"reasoningEffort":"low","description":"…"}, …]`. `isDefault` marks the catalogue default, not the configured model.
> Codex `thread/start` with `ephemeral: true` → result `{"model":"gpt-5.5","modelProvider":"openai","reasoningEffort":"medium",…}`: the resolved model, no turn started.


## Acceptance Scenarios

- **S01 [OC01] The Claude picker lists the provider's models by name**
  - **Given** Claude discovery returned the five rows above and `applied.model` `claude-opus-5[1m]`
  - **When** the Model popover renders for a `claude` conversation
  - **Then** the options read "Default · Opus (1M context)", "Opus (1M context)", "Fable", "Sonnet", "Haiku" with values `''`, `opus[1m]`, `claude-fable-5-1[1m]`, `sonnet`, `haiku`; the provider's own `default` row is not a separate option, and a `disabled` row is not offered

- **S02 [OC01] The Codex picker lists `model/list` entries by name**
  - **Given** Codex discovery returned two pages (`nextCursor` set on the first) including one `hidden: true` entry, and `thread/start` resolved `gpt-5.5`
  - **When** the Model popover renders for a `codex` conversation
  - **Then** every non-hidden entry from both pages is offered by its `displayName` with its `id` as value, and the first option reads "Default · " plus the `displayName` of `gpt-5.5`

- **S03 [OC02] Effort follows the selected model**
  - **Given** a `claude` conversation with effort `high` staged
  - **When** the user picks Haiku (no effort support), then Sonnet
  - **Then** with Haiku the Effort select offers only Default, is disabled and the applied effort is `null`; with Sonnet it offers Default plus `low, medium, high, xhigh, max`; a Codex model offers exactly its `supportedReasoningEfforts`, `max` and `ultra` included where listed

- **S04 [OC03] The pill and crumb name the model**
  - **Given** a `claude` conversation
  - **When** the next-turn model is Default, then Sonnet with effort `high`
  - **Then** the pill reads "claude · Opus (1M context)", then "claude · Sonnet · high"; the topbar crumb names the current context's model by the same label

- **S05 [OC03] A value outside the catalogue stays representable**
  - **Given** a staged model `claude-sonnet-4-5` that the catalogue does not list (set from YAML or the JSON API)
  - **When** the popover and pill render
  - **Then** the picker offers it as its own option labelled by its id, selected, and the pill shows that id

- **S06 [OC04] No catalogue yet, or discovery failed**
  - **Given** a provider whose discovery has not finished, or failed (process error, timeout, or a response missing a required field)
  - **When** the Model popover and pill render
  - **Then** the Model and Effort selects offer Default plus any staged value, the pill shows the provider plus any staged model id, each failure is logged with the provider id, and a render at least 5 minutes after the last failed attempt starts one background re-discovery (never two concurrent, never more often), whose success shows names on a later render; a successful catalogue is kept for the life of the process

- **S07 [OC04] Discovery runs no model turn, on the host with the worker's inputs**
  - **Given** server start with `claude` and `codex` executable
  - **When** discovery runs
  - **Then** each provider process is spawned on the host – never in a container – from the same executable, provider options (including the configured model), credential environment and subscription home its workers use; Claude receives only `initialize` and `get_settings`, Codex only `initialize`/`initialized`, `model/list` (every page) and one `thread/start` with `ephemeral: true`; no user turn is sent to either, and each process is stopped afterwards; page rendering never waits on it. Where the host cannot spawn the CLI (e.g. a container-only deployment), discovery fails and scenario S06 applies

- **S08 [OC03] A resolved default the catalogue does not list**
  - **Given** Claude's `applied.model` matches no row's `resolvedModel`, or Codex's `thread/start` model is not among the non-hidden entries
  - **When** the Model popover and pill render with Default selected
  - **Then** the Default option reads plain "Default" and the pill shows the provider alone – no raw id is shown in its place


## Structural Criteria

- **SC01** `EffectiveContextCapabilities` carries only the transport flags (`model`, `effort`); no harness declares a static model or effort list, and no host-side table maps model ids to names.
- **SC02** The picker option list – values, labels, the Default label and per-model efforts – is built once, on the server; the chat controller renders the server's option data verbatim instead of re-deriving it (the `_contextOptions` / `renderContextOptions` rebuild pairing is gone).
- **SC03** `control-protocol.md` documents the Claude `get_settings` request and the Codex `model/list` + ephemeral `thread/start` discovery; the guide's **Effective context** bullet, the DECISIONS Still Current bullet and `CHANGELOG.md` state the shipped behaviour.


## Scope & Boundaries

### Work Areas
- `packages/dartclaw_core/lib/src/harness/agent_harness.dart` – `EffectiveContextCapabilities` reduced to flags; the catalogue value type beside it
- `packages/dartclaw_core/lib/src/harness/claude_code_harness.dart` (+ its protocol files) – catalogue from `initialize` `models` + `get_settings`
- `packages/dartclaw_core/lib/src/harness/codex_harness.dart`, `codex_protocol_adapter.dart` – catalogue from `model/list` + ephemeral `thread/start`
- `packages/dartclaw_core/lib/src/harness/harness_factory.dart` – discovery harness built on the host from the worker's provider inputs
- `packages/dartclaw_runtime/lib/src/runtime/harness_wiring.dart` – the one runtime owner of discovered catalogues
- `packages/dartclaw_runtime/lib/src/api/session_routes_support.dart` – option projection, Default label, pill label
- `packages/dartclaw_runtime/lib/src/web/web_routes.dart` + `templates/topbar.dart` – crumb model label
- `packages/dartclaw_runtime/lib/src/templates/chat.html`, `static/controllers/dc_chat_controller.js` – server option data rendered verbatim, effort rebuilt on model change
- Tests beside each; docs per SC03

### What We're NOT Doing
- Showing a model's `description` in the picker – the provider's `displayName` is the label; a second text line is a later design choice.
- Offering hidden Codex models or `disabled` Claude rows – they are not selectable for the account.
- A persisted catalogue cache, TTL or refresh config – a catalogue lives for the process; only a failed discovery retries (scenario S06).
- Discovery inside a container – a container-only deployment without a host CLI keeps Default plus staged values (scenario S07).
- Labelling the effort Default with its resolved effort, or giving providers display names – not requested.
- ACP providers – they transport no model or effort (`model: false`), so they get no catalogue.
- Model fields outside the chat composer (settings, task and agent definitions) – unchanged.


## Architecture Decision

**Approach**: Each harness reports its model catalogue from its own provider process, and one runtime owner discovers it in the background at startup on the host from the worker's provider inputs and serves it to the views; labels are the provider's `displayName` verbatim.
**Why this over the floor**: the floor – extending the static per-harness lists – fails the owner's requirement for a robust, maintainable list with human-readable names: the lists already drifted (Codex `max`/`ultra`, Claude Fable and 1M) and carry no names without a host-maintained table; both CLIs report the list, names, per-model efforts and the resolved default without a turn.


## Code Patterns & External References

```
# type | path#anchor                                                                  | why needed (intent)
file   | packages/dartclaw_core/lib/src/harness/claude_code_harness.dart#_initCompleter | where the initialize control_response is awaited; models ride in it
file   | packages/dartclaw_core/lib/src/harness/codex_protocol_adapter.dart#buildThreadStartRequest | request-builder pattern for model/list and thread/start
file   | packages/dartclaw_core/lib/src/harness/harness_factory.dart#probeEffectiveContextCapabilities | today's static probe; discovery replaces its list half
file   | packages/dartclaw_runtime/lib/src/runtime/harness_wiring.dart#effectiveContextCapabilities | executable-provider set the discovery covers
file   | packages/dartclaw_runtime/lib/src/api/session_routes_support.dart#effectiveContextView | the projection the labels and options move into
url    | https://github.com/openclaw/openclaw/blob/f804111014bc503b7bb977a253ab9872449d8b63/extensions/codex/src/app-server/models.ts | prior art: paged model/list discovery with a page guard
```


## Constraints & Gotchas

- **Constraint**: `get_settings`, `resolvedModel` and the Claude `models` rows are undocumented CLI surface and may drift – a response missing a field this story reads fails that provider's discovery as a whole (scenario S06), never a guessed or partial catalogue.
- **Constraint**: discovery must use the worker's executable, provider options (configured `--model` included), credential environment and subscription home (dedicated `CODEX_HOME`), or the list and resolved default describe a different account or model than the turns run; it takes none of the worker's container, guard chain, workspace roots or MCP wiring (scenario S07).
- **Constraint**: `.dart` code compiles into a running serve VM – validate in a fresh server on a free port.
- **Constraint**: this story edits the same composer controller code as `dev/bundle/docs/specs/0.27-menu-palette-fixes/` S01 – start from a tree where that story has landed.


## Implementation Plan

### Implementation Tasks

- **TI01** A model catalogue value type exists beside `EffectiveContextCapabilities` (entries of id, label, efforts; the resolved default id or none), and `EffectiveContextCapabilities` carries only the `model`/`effort` flags
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_core/test/harness/effective_context_capability_test.dart` – passes with assertions that Claude and Codex declare no model or effort list
  - **SATISFIES**: SC01

- **TI02** The Claude harness reports its catalogue from the `initialize` response's `models` and a `get_settings` request: `default` and `disabled` rows dropped, efforts from `supportedEffortLevels` (none when absent), default resolved via `applied.model` ↔ `resolvedModel`; a missing required field fails discovery
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_core/test/harness/claude_protocol_test.dart --name "model catalogue"` – raw-literal fixtures of the wire shapes above: five rows → four entries with Haiku effortless and default `opus[1m]`; an `applied.model` matching no row yields no default; a row without `displayName` fails; the only control requests sent are `initialize` and `get_settings`
  - **SATISFIES**: S01, S03, S07, S08

- **TI03** The Codex harness reports its catalogue from every `model/list` page (hidden entries dropped, efforts from `supportedReasoningEfforts[].reasoningEffort`) and the resolved default from an ephemeral `thread/start`, sending no turn
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_core/test/harness/codex_harness_test.dart --name "model catalogue"` – fake app-server over two pages with one hidden entry; asserts the entries, default `gpt-5.5`, no default when the `thread/start` model is not among the non-hidden entries, the exact request methods sent, and that no `turn/start` is sent
  - **SATISFIES**: S02, S03, S07, S08

- **TI04** One runtime owner discovers each executable provider's catalogue in the background at startup on the host from the worker's executable, provider options, credential environment and subscription home, stops each probe process, logs each failure, and re-discovers a failed provider on a read at least 5 minutes after its last attempt
  - Depends on TI02/TI03. Rendering reads whatever the owner holds; it never awaits discovery. The capability map is copied at startup into `ServerDeps`, `ConversationService` and the session/web route builders today, so views must read the owner live, not a startup snapshot. The 5-minute spacing is a constant, not config; inject the clock for the test.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/runtime --name "model catalogue discovery"` – fake factory and clock: startup discovery uses the worker's inputs without a container and stops the probe; after a failure, reads within 5 minutes start nothing, the first read after starts exactly one retry, concurrent reads start no second, and a success is never re-probed
  - **SATISFIES**: S06, S07

- **TI05** `effectiveContextView` projects the server-built option data for every provider – labels, the "Default · <resolved label>" entry, off-catalogue staged values as their id, per-model efforts – and the pill label and the popover's current/next context labels (`contextLabel`) name the model by the same labels
  - Depends on TI04.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/api/effective_context_view_test.dart --name "model catalogue"` – covers S01/S02 option lists, S04 pill texts, S05 staged id, S06 no-catalogue options and pill, S08 unresolved default, and a catalogued model in the current/next labels
  - **SATISFIES**: S01, S02, S04, S05, S06, S08, SC02

- **TI06** The chat controller renders the server's option data verbatim on provider change and reconcile, and rebuilds Effort from the selected model's efforts on model change (a staged effort the new model lacks becomes Default)
  - Depends on TI05's option data. No client-side option builder remains.
  - **Verify**: `cmd: bash -c 'dart test --reporter=failures-only packages/dartclaw_runtime/test/static/effective_context_controller_test.dart --name "model catalogue" && ! rg -q "renderContextOptions|_contextOptions" packages/dartclaw_runtime/lib'` – the rebuild pairing is gone; Node harness: provider switch renders the server list, picking Haiku disables Effort and applies `effort: null`, picking Sonnet offers its five efforts
  - **SATISFIES**: S03, SC02

- **TI07** The topbar crumb names the current context's model by its catalogue label (its id when uncatalogued, the resolved default's label when the model is Default, no model when that default is unresolved)
  - Depends on TI05: the crumb reuses TI05's label projection, not a second lookup.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/templates --name "crumb model label"` – crumb renders "Sonnet" for `sonnet` and the id for an uncatalogued model
  - **SATISFIES**: S04, S05

- **TI08** The protocol doc, the guide, the DECISIONS Still Current bullet and the changelog state the provider-reported catalogue
  - **Verify**: `cmd: bash -c 'rg -q "get_settings" dev/architecture/control-protocol.md && rg -q "model/list" dev/architecture/control-protocol.md && ! rg -q "EffectiveContextCapabilities.models" dev/state/DECISIONS.md'` – fails on the pre-change tree
  - **SATISFIES**: SC03

### Validation

- In a fresh server (`bash examples/run.sh dev --port <free port>`) with the local `claude` login, at 800×600: the Model popover lists the account's models by name with "Default · <name>" first, picking Haiku disables Effort, and the pill reads "claude · <name>". Where a Codex login is present, repeat for `codex` by adding it to a scratch copy of the config under `.agent_temp/`. Screenshots under `.agent_temp/`.


## Discovered Requirements

> _Managed by exec-spec during implementation – append-only, one bullet per requirement in the shape fis-mutability.md states. Spec authors: leave this section empty._

_No requirements discovered yet._

- **DR01 [S04] The inbox row carries the crumb's model label** (2026-09-21): `dc_shell_controller.js#syncTopbarCrumb` rebuilds the topbar crumb's provider/model tail from the `/api/inbox` row on every inbox render, so a server-rendered label was replaced by the raw `model` id (and Default by nothing). `session_inbox_routes.dart` now adds `model_label` (from `contextModelLabel`, the same projection as the pill) to each row and the shell renders it; the rail keeps `model` unchanged. Pinned by `session_inbox_routes_test.dart` "an inbox row names its model by the catalogue label".
- **DR02 [OC03] Session info and the rail name the model by the same label** (2026-09-21, owner rule "no names like opus[1m]" in the chat UI): the Session info Model row (`effectiveContextView` `model`, rendered by `session_info.html`) now uses `contextModelLabel` (Default by what it resolves to, plain `Default` when unresolved; the effort fallback reads `Default` too), and the rail row renders the inbox row's `model_label`, superseding DR01's "the rail keeps `model`". No second lookup. Pinned by `effective_context_view_test.dart` "Session info names the model by the same label, never the raw id" and `inbox_controller_test.dart` "rail rows and the topbar crumb name the model by its catalogue label".


## Implementation Observations

> _Append-only: Preflight records a deferred decision here while authoring, exec-spec its observations post-implementation. Nothing else is written here._

_No observations recorded yet._

- 2026-09-21 – Task order: TI04's Verify could only run after TI05's edits, because `dartclaw_runtime` did not compile while `effectiveContextView` still read the removed `EffectiveContextCapabilities.models/.efforts`. Each Verify then passed in TI order.
- 2026-09-21 – Live wire check (claude 2.1.278): the `get_settings` payload is `{applied:{model,effort,advisor,ultracode},effective,sources}`; the Fable row is `value: claude-fable-5-1[1m]` with `resolvedModel: claude-fable-5-1`, so a deployment configured with `--model claude-fable-5-1[1m]` likely resolves no Default (S08 path) – not exercised. codex-cli 0.155.1 returns `nextCursor` as a string and the ephemeral `thread/start` result names `model` as specified.
- 2026-09-21 – Choices where the contract is silent: Default's Effort picker is the resolved entry's efforts; with Default unresolved, no catalogue, or an off-catalogue staged model, efforts are unknown and Effort offers Default plus the staged effort, editable. A staged effort a known list lacks stays representable on the staged model only (server render); a client model change drops it to Default. Codex discovery sends the configured `agent.model` on the ephemeral `thread/start` so Default resolves to what turns run. `ModelCatalogueDiscovery.start()` never re-attempts a failed provider; only a read past the 5-minute window does. Discovery is started by `HarnessWiring.startModelCatalogueDiscovery`, which `DartclawRuntime.build` calls after primary startup only when it composed a server (starting it inside `startPrimary` spawned probes in every harness-wiring test fixture), and applies the same host credential verdict a worker must pass.
- 2026-09-21 – Not handled: shutdown neither awaits nor kills an in-flight discovery probe (bounded by the 10 s initialize/request timeouts; both CLIs exit on stdin EOF). With a dedicated Codex subscription home, the probe runs `completeDedicatedCodexHome` with an empty generated half (no developer instructions or MCP stanza), so a worker spawning in the same instant could read that `config.toml` – the same shared-file exposure workers with different prompts already have. The rail row still shows the raw model id.
- 2026-09-21 – Review follow-up: the dedicated-home exposure above was worse than a race – the probe rewrote the shared `config.toml` without developer instructions or `[mcp_servers]` on every discovery, and Codex re-reads it per thread start. Fixed: the probe gets the home the probe-lane way (`prepareCodexSubscriptionHome`, no generated half) and spawns with `CodexEnvironment.dedicated(writesConfig: false)`, writing neither `config.toml` nor `AGENTS.md`; pinned byte-identical by `codex_model_catalogue_cases.dart`. The rail now uses `model_label` (DR02). Claude Default also resolves by an exact `value` match. Live check, claude 2.1.278 spawned with `--model claude-fable-5-1[1m]` (initialize + get_settings only): `applied.model` is `claude-fable-5-1`, which matches the Fable row's `resolvedModel`, so Default resolves to Fable either way.
