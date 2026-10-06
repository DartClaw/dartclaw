# Run origin

**Plan**: dev/bundle/docs/specs/0.28/plan.json
**Story-ID**: S04

## Feature Overview and Goal

**Intent**: A workflow run has to remember where it came from, so the chat stories after this one can post a run's lifecycle to the thread that started it and gate approvals on who asked, without trusting anything the model says.

**Expected Outcomes**:

- [OC01] A 0.27 PostgreSQL store keeps its workflow runs through one bounded transition to 0.28 and reads them as origin `unknown`; every other schema shape is still refused untouched.
- [OC02] Every workflow run records, once and immutably, the surface that started it, and the run detail API shows it.
- [OC03] A run started by an agent's tool call records the chat thread, web chat or scheduled job that turn came from, on every execution lane, taken from host-held turn state and never from model-supplied arguments.


## Required Context

- `docs/specs/0.28/prd.md#fr4-run-origin-and-chat-threaded-run-lifecycle` – FR4 acceptance criterion 1 and the surface list
- `docs/specs/0.28/prd.md#data-requirements` – the run-origin fields and their nullability
- `docs/specs/0.28/prd.md#non-functional-requirements` – the bound-agent execution row this story must not disturb
- `docs/research/slack-threaded-runs-0.28/recommendation.md#f4-immutable-origin-json-value` – value, codec, wiring list, the surface-marker rule
- `docs/research/slack-threaded-runs-0.28/adr-045-amendment.md` – the admitted transition, its refusals and its test list


## Acceptance Scenarios

- **S01 [OC01] [runtime] A released-0.27 store transitions and its runs read `unknown`**
  - **Given** a PostgreSQL store at the released 0.27 shape (epoch 1 marker, `workflow_runs` without `origin_json`) holding runs
  - **When** the runtime prepares it
  - **Then** `origin_json` exists as nullable text, added in one transaction with the marker unchanged and every existing row byte-identical; each run hydrates with origin `unknown`; a second prepare issues no write; a fresh store bootstraps with the column and an exact current store is untouched

- **S02 [OC01] [runtime] Every other shape refuses without mutation**
  - **Given** a store that is legacy and also lacks another required object, or carries `origin_json` with a different type, or has an absent, duplicated, malformed or non-1 marker
  - **When** the runtime prepares it
  - **Then** it throws `SchemaIncompatibleException` with backup/reset guidance and the catalog is unchanged; `validateCurrent` on the exact legacy shape also changes nothing, and its refusal names starting `dartclaw serve` as the way to apply the transition, not reset or recreate

- **S03 [OC01] [runtime] A failed transition rolls back whole**
  - **Given** an exact legacy store
  - **When** a statement of the transition fails, injected at each position in turn
  - **Then** the store is still the exact legacy shape (no column, marker intact) and a retry without the fault converges to the current shape

- **S04 [OC02] Origin never changes after start**
  - **Given** a run started with origin O in the PostgreSQL repository and in the standalone file repository
  - **When** it is paused, resumed, resolved at an approval, updated with an expected status or timestamp, and status-transitioned, including an update handed a run object carrying a different origin
  - **Then** every read returns O

- **S05 [OC02] Each start path records its own surface**
  - **Given** a run started from the web run form, the JSON API, the connected CLI, the standalone CLI, and a GitHub webhook
  - **When** each reaches `WorkflowService.start`
  - **Then** the stored surface is `web`, `api`, `cli`, `cli` and `github` in that order, with no channel fields; the JSON API accepts a `surface` marker only as `cli`, answers any other value (`slack` included) with `400 INVALID_INPUT` and creates no run, and no request field can set recipient, thread, session or sender

- **S06 [OC02] The run detail API shows origin**
  - **Given** a run started from a Google Chat thread and a legacy run with SQL NULL origin
  - **When** `GET /api/workflows/runs/<id>` is called for each
  - **Then** the first returns an `origin` object with surface, channel type, recipient, thread, session key and sender, and the second returns surface `unknown` with the rest null

- **S07 [OC03] [runtime] An agent turn on the host lane records the thread it came from**
  - **Given** a Google Chat thread message from sender X in space R, thread T, session key K, handled by the primary agent on a host harness
  - **When** the agent calls `workflow_run`
  - **Then** the run's origin is surface `googlechat` with recipient R, thread T, session key K and sender X; and a call that adds origin-like arguments is refused as an unknown argument

- **S08 [OC03] [runtime] An agent turn on the container lane records the same, per turn**
  - **Given** a bound agent's turn in a container authority, and a containerized primary serving an unbound channel turn
  - **When** two turns by different senders run in one shared session and each calls `workflow_run`
  - **Then** each run carries its own turn's sender and thread, from the host's record of that turn; a call arriving after the turn ended carries no context

- **S09 [OC03] [runtime] Callers that are not a channel turn never inherit one**
  - **Given** a channel turn running on the primary harness, and meanwhile `workflow_run` called with the shared gateway token, by a host worker harness serving another session, and by a named MCP client
  - **When** each starts a run
  - **Then** none receives the channel turn's context; the gateway-token call and a host-worker call made outside any turn record surface `api`, and a host worker reused for a second session carries the second session's context only while that turn runs

- **S10 [OC03] A scheduled prompt turn records `cron`**
  - **Given** a scheduled prompt job whose turn calls `workflow_run`
  - **When** the job fires
  - **Then** the run's origin is surface `cron` with no channel fields

- **S11 [OC03] Channel dispatch keeps its execution routing**
  - **Given** an unbound row and a bound agent row
  - **When** a channel message reaches `dispatchChannelTurn` with provenance attached
  - **Then** the unbound turn still starts on the primary lane and the bound turn still reserves with the logical-agent surface, its session still pinned to the agent's provider and policy
  - **Proof**: `packages/dartclaw_runtime/test/runtime/channel_wiring_test.dart` – green – parity/regression

- **S12 [OC03] [runtime] A web-chat turn records `web` and carries no sender**
  - **Given** a web-chat turn started by the session message route and one started by the conversation context-turn route, each on a host harness
  - **When** the agent calls `workflow_run`
  - **Then** the run's origin is surface `web` with the session's key and no channel type, recipient, thread or sender; the turn context the tool received is surface `web`, that session key and no sender, so a gate reading a sender sees a non-channel turn; a gateway-token call made while that turn runs carries no `web` context


## Structural Criteria

- **SC01** `origin` is a required argument of `WorkflowService.start`, so a start surface cannot omit it.
- **SC02** The schema gate is the only owner of the `origin_json` DDL on an existing store.
- **SC03** MCP tools that do not read the turn context behave as before on every lane, including the existing contextual memory, knowledge and schedule tools.


## Scope & Boundaries

### Work Areas
- Workflow package: origin value and codec, `WorkflowRun`, `WorkflowService.start`, the PostgreSQL and file run repositories.
- Core storage: workflow-run schema identity, bootstrap DDL, the schema gate's transition.
- Runtime: run routes, GitHub webhook, `workflow_run` tool, MCP dispatch and caller context, MCP route credentials, harness wiring, channel dispatch, scheduled turns, turn manager and runner.
- CLI: connected and standalone `workflow run`.
- Docs: ADR-045 amendment applied, decisions index, data-model, workflow and system architecture, web-UI/API guide, CHANGELOG.

### What We're NOT Doing
- Posting run lifecycle, thread bindings, the threaded-notification capability, reading `origin` to choose destinations – story S05.
- Slack thread extraction – story S05 redirects the one thread-resolution call used here (`extractThreadId`, Google Chat only today) to its capability; until then a Slack-started run records a null thread.
- Run-control tools and the admin gate – stories S06 and S07 read the delivered turn context; this story adds no tool beyond `workflow_run` reading it. Whether a turn without a sender is refused or bypassed is each reading story's own rule (S06, S07, S09).
- Giving a web-chat turn a sender, recipient, thread or channel type – it carries surface `web` and its session key only.
- A scheduler call to `WorkflowService.start` – none exists; `cron` comes only from a scheduled prompt turn's tool call.
- An epoch bump, history table, transition chain, migration runner or SQLite path – the amendment forbids them.
- Showing origin on the run page or in SSE payloads – the PRD adds no web UI; the API is the exposure.
- Putting `cron` or recipient fields on `TurnOrigin` – it stays the prompt-facing value (see Constraints).


## Architecture Decision

**Approach**: One immutable `WorkflowRunOrigin` in the workflow package, a single codec for the `origin_json` column and the API, set by a required `WorkflowService.start(origin:)`. The admitted transition lives in `PostgresSchemaGate.prepare` over its existing `_differences` inspection: legacy means epoch 1 and exactly one difference, the missing `workflow_runs.origin_json`. The host-built turn provenance rides the `HarnessTurnContext` the runner already sets and clears per turn, and each MCP authority resolves it per call from the harness it is bound to. See ADR: `docs/research/slack-threaded-runs-0.28/adr-045-amendment.md`.
**Why this over the floor**: The floor is a refusal-only gate and origin captured on web paths only. FR4 requires retained runs to read `unknown` and chat starts to record their thread, and no model-supplied field may carry that: host harnesses are shared across sessions and share one gateway token, so only a host-held per-turn record can attribute a call to a turn.
**Flow**: inbound dispatch (message queue dispatcher or Google Chat's direct dispatch), a web-chat turn site, or a scheduled job builds the provenance → reserved turn → `HarnessTurnContext` → authority resolver → `McpCallerContext.turn` → `workflow_run` → `start(origin:)` → `origin_json`.


## Constraints & Gotchas

- **Constraint**: Schema epoch stays 1, as `schema_identity_test.dart` and the shared `epoch 2` refusal mutation assert – Workaround: detect legacy by its single missing column, not by marker. There is no epoch bump, so a 0.27 binary still opens a transitioned store (extra columns are tolerated).
- **Constraint**: `PostgresSchemaGate.validateCurrent` has read-only callers (`cleanup`, `workflow status`, `doctor`, interlock recovery) – Workaround: only `prepare` transitions; the others refuse the exact legacy shape with a message naming `dartclaw serve` as the way to apply the transition, never reset or recreate (scenario S02).
- **Constraint**: A `WorkflowRun` hydrates `origin` from a missing key or SQL NULL as `unknown`; a non-null malformed value fails decoding rather than inventing provenance. The surface set is the PRD's closed list, and a chat surface is the turn's `ChannelType` name, `web` included, though a web-chat origin carries no channel type (story S01 adds `slack` in parallel; never hard-code the channel list from the enum).
- **Constraint**: The container authority is acquired before its harness exists, container workers are pinned to one session, but host workers are cached and reused across sessions, and the primary container's principal has no session – Workaround: bind authority to harness after construction and resolve the harness's active turn at call time, never a session captured at creation.
- **Constraint**: A harness's bearer is the shared gateway token today, so nothing identifies the calling harness – Workaround: each host harness presents its own host-minted bearer, valid only while that harness lives; gateway-token and named-client callers carry no turn.
- **Constraint**: `TurnOrigin` is composed into the system prompt under `## Channel` for task scope as well, so giving scheduled turns one would change their prompts – Workaround: provenance is a sibling value on the same reserve/start calls, built beside `TurnOrigin` at the same sites.
- **Constraint**: Existing contextual tools take the identity-bearing path when a call has an identity and `call(args)` otherwise (the memory tools differ between them) – Workaround: a tool opts in to the turn; dispatch hands a turn to no other tool and gives host-harness callers no identity they lack today (scenario S09, SC03).
- **Constraint**: Both inbound routes reach `dispatchChannelTurn` (the `MessageQueue` dispatcher and Google Chat's direct `dispatchMessage`), and neither carries thread today; `TurnDispatcher`, `TurnManager` and every implementer, `dartclaw_testing` fakes included, change together.
- **Constraint**: `dispatchChannelTurn` must keep the unbound primary-lane and bound logical-agent routing, scenario S11 (PRD bound-agent execution row).
- **Constraint**: A web-chat turn is identifiable, so the runs its agent starts record `web`, not `api` – Workaround: the two web turn sites that already build a `TurnOrigin` (`session_message_routes.dart` `reserveTurn`, `conversation_service.dart` `reserveContextTurn`) also build the provenance, with surface `web`, the session's stored key (null when the session has none) and no channel type, recipient, thread or sender.
- **Constraint**: The contract for every reader of `McpCallerContext.turn`: a turn context with no sender is a non-channel turn (web chat, scheduled `cron`), and a sender gate refuses or bypasses it by its own rule; S04 adds no gate.
- **Constraint**: Only `cli` is claimable through the API `surface` marker; any other value is refused, `slack` and `web` included.


## Implementation Plan

### Implementation Tasks

- **TI01** `WorkflowRunOrigin` and its codec exist in the workflow package, and `WorkflowRun` carries it through constructor, `toJson`, `fromJson` and `copyWith`, which offers no way to change it
  - Camel-case keys matching `WorkflowRun.toJson`; one codec serves the column and the API.
  - **Verify**: `packages/dartclaw_workflow/test/workflow/workflow_run_test.dart#WorkflowRun origin` – round-trip of every field, missing and null reading `unknown`, malformed non-null and an unlisted surface failing to decode, `copyWith` preserving origin
  - **SATISFIES**: S04, S06

- **TI02** The workflow-run schema identity and bootstrap DDL carry nullable `origin_json TEXT`, and `PostgresSchemaGate.prepare` admits the one transition
  - Reuse `_differences`; validate the full identity inside the same transaction as the `ALTER`. Extend `FailingDatabaseBackend` use as in `postgres_schema_gate_live_test.dart` "every bootstrap prefix rolls back".
  - **Verify**: `cmd: bash dev/tools/postgres_contract.sh && test "$(git grep --untracked -l 'ADD COLUMN origin_json' -- 'packages/*/lib/*' 'apps/*/lib/*')" = packages/dartclaw_core/lib/src/storage/postgres_schema_gate.dart` – new live tests in `packages/dartclaw_core/test/storage/postgres_schema_gate_live_test.dart` cover scenarios S01 to S03 (fresh, exact current, exact legacy with rows, each refused shape, injected failure at every statement, restart after success), and the gate file is the only `lib/` source naming the DDL; a skipped run is not evidence
  - **SATISFIES**: S01, S02, S03, SC02

- **TI03** Both run repositories persist and hydrate origin and never rewrite it after insert
  - `DatabaseWorkflowRunRepository` writes it only in `insert` and decodes it in `_workflowRunFromRow` (so `transitionStatus ... RETURNING *` carries it); `FileWorkflowRunRepository.update` keeps the stored origin as it keeps `workflowWorktrees`.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_workflow/test/workflow/file_workflow_run_repository_test.dart --name "run origin" && bash dev/tools/postgres_contract.sh` – the file repository keeps origin through every update path and ignores a differing one; the `repository.workflow_run` group gains the same assertions plus a NULL row reading `unknown`
  - **SATISFIES**: S01, S04

- **TI04** `WorkflowService.start` requires `origin` and persists it in the initial insert, before any run event is fired
  - **Verify**: `cmd: dart analyze --fatal-infos && dart test --reporter=failures-only packages/dartclaw_workflow/test/workflow/workflow_service_test.dart --name "start run origin"` – every start caller, tests included, compiles with an explicit origin, and a listener on the first status event reads the run from the repository and finds the supplied origin
  - **SATISFIES**: S04, SC01

- **TI05** The HTTP start routes, GitHub webhook and run detail responses record and expose surface and origin
  - Run form `web`; JSON `api`, or `cli` on the validated marker, refused otherwise per scenario S05; webhook `github`. `_enrichRunDetail` and the other `run.toJson()` responses carry `origin`.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/api/workflow_routes_test.dart packages/dartclaw_runtime/test/api/workflow_run_form_route_test.dart packages/dartclaw_runtime/test/api/github_webhook_test.dart --name "run origin"` – marker acceptance and refusal with no run created on refusal, `origin` in detail and list for a stored run and a legacy run, form `web`, webhook `github`
  - **SATISFIES**: S05, S06

- **TI06** The connected CLI sends the `cli` marker and the standalone CLI starts runs with origin `cli`
  - **Verify**: `cmd: dart test --reporter=failures-only apps/dartclaw_cli/test/commands/workflow/workflow_run_command_connected_test.dart apps/dartclaw_cli/test/commands/workflow/workflow_run_command_standalone_test.dart --name "run origin"` – the connected body carries the marker, the standalone run's stored surface is `cli`
  - **SATISFIES**: S05

- **TI07** A host-built turn provenance is created at both inbound dispatch routes, at the two web-chat turn sites and by scheduled prompt turns, and travels `TurnManager` reserve/start → `TurnContext` → `HarnessTurnContext`, set and cleared with the turn
  - Chat fields: channel type, `resolveRecipientId`, the thread from `extractThreadId`, the derived session key, the sender JID; web chat: surface `web` and the session's key only; scheduled: surface `cron` only. Follow `HarnessTurnContext` and the runner's `setTurnContext` set/clear in `turn_runner_execution_loop.dart`.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/runtime/channel_wiring_test.dart packages/dartclaw_runtime/test/scheduling/schedule_service_test.dart packages/dartclaw_runtime/test/api/session_routes_test.dart packages/dartclaw_runtime/test/conversation/effective_session_context_test.dart --name "trusted turn context"` – the queue route and the direct route produce the same provenance for a Google Chat thread message, bound and unbound, a prompt job's turn carries `cron`, and each web-chat site's reserved turn carries surface `web`, the session key and no sender
  - **SATISFIES**: S07, S08, S10, S11, S12

- **TI08** An MCP call on a container authority, bound agent or primary, receives the active turn's provenance as `McpCallerContext.turn`
  - Resolver bound late to the authority's harness (`HarnessWiring` primary and `createWorker`, `McpBridgeSurface`); `McpProtocolHandler` is the only place that fills `turn`.
  - **Verify**: `packages/dartclaw_runtime/test/container/gateway/mcp_bridge_surface_test.dart#trusted turn context` – two sequential turns in one session see their own sender, none after the turn clears, primary authority resolves the primary harness's turn
  - **SATISFIES**: S08, SC03

- **TI09** Every host harness, primary and worker, presents its own host-minted MCP bearer that `mcpRoute` resolves to that harness's turn provenance
  - Revoked when the harness is disposed; gateway-token and named-client resolution unchanged. Must reach `HarnessLaunchOptions.mcpGatewayToken` for Claude and the Codex bearer env var alike.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/mcp/mcp_router_test.dart packages/dartclaw_runtime/test/runtime/harness_wiring_gateway_token_test.dart --name "trusted turn context" && dart test --reporter=failures-only packages/dartclaw_runtime/test/mcp` – a per-harness bearer yields its harness's turn, the gateway token and a named client yield none, a revoked bearer is `401`; through the real `HarnessWiring` the primary and a worker harness are built with distinct minted bearers, not the shared token; the existing MCP suites stay green
  - **SATISFIES**: S07, S09, S12, SC03

- **TI10** `workflow_run` opts in to the turn and derives its origin from it alone
  - Chat provenance maps one to one onto `WorkflowRunOrigin`; `web` and `cron` likewise; no provenance, including `call(args)`, gives `api`. The input schema stays closed.
  - **Verify**: `packages/dartclaw_runtime/test/mcp/workflow_tools_test.dart#run origin` – chat, web, cron, none and the refused origin-like argument, each through `McpProtocolHandler`
  - **SATISFIES**: S07, S08, S09, S10, S12

- **TI11** The records say what shipped: the ADR-045 amendment is applied, the decisions index and affected architecture, guide and CHANGELOG entries describe the origin, the transition and the turn provenance, and "Current through" markers move with them
  - Amendment text is `docs/research/slack-threaded-runs-0.28/adr-045-amendment.md`; update ADR-045's status note and its `dev/state/DECISIONS.md` row. Touch `dev/architecture/data-model.md`, `dev/architecture/workflow-architecture.md` (§ 15.1), `dev/architecture/system-architecture.md` (the `McpCallerContext` paragraph), `docs/guide/web-ui-and-api.md` (run detail `origin`, the `surface` marker, `workflow_run` origin).
  - **Verify**: `cmd: for f in dev/adrs/045-pluggable-database-backend.md dev/architecture/data-model.md; do git grep -q origin_json -- "$f" || exit 1; done; for f in CHANGELOG.md dev/architecture/workflow-architecture.md docs/guide/web-ui-and-api.md; do git grep -qi 'run origin' -- "$f" || exit 1; done; git grep -q '0\.28' -- dev/state/DECISIONS.md` – each doc names what it owns, and the ADR-045 index row reflects the amendment
  - **SATISFIES**: S01, S05, S06


## Final Validation Checklist

- `bash dev/tools/postgres_contract.sh` runs to completion with the new groups executed, not skipped.
- `dart run dev/tools/arch_check.dart` and `bash dev/tools/fitness/run_all.sh` pass: the story adds code to three packages with per-package LOC targets.
