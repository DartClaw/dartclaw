# DartClaw CLI & API Architecture

The operational command-line surface and the HTTP API behind it: the two CLI binaries, connected vs standalone
execution, the shared API client, the server route families, and the workflow trigger surfaces. Workflow semantics are in
[workflow-architecture.md](workflow-architecture.md); config loading and hot reload in
[configuration-architecture.md](configuration-architecture.md); SSE streaming, health and audit mechanics in
[observability-operations-architecture.md](observability-operations-architecture.md); package topology and the
composition root in [system-architecture.md](system-architecture.md).

**Current through**: 0.28.0

---

## 1. Design Goal

The CLI is an operational surface for a running instance, not only a wrapper around `serve`: it inspects and controls
live runtime state, triggers workflows against the server-owned execution model, and keeps local-only commands explicit
instead of silently mixing local and server state. The CLI is not a privileged side channel; it uses the same routes as
the web UI and integrations ([ADR-030](../adrs/030-connected-by-default-workflow-execution.md)).

| Concern | CLI | Server |
|---|---|---|
| Argument parsing, UX, server-address and token resolution | Yes | No |
| Persistent state mutation, runtime orchestration | No | Yes |
| Workflow execution in connected mode | No | Yes |
| Local maintenance, setup and validation | Yes | No |

`dartclaw_cli` owns command UX, transport use and process-local helpers; `dartclaw_runtime` owns routing, auth and
state transitions; `dartclaw_workflow` owns execution semantics used by both the server and standalone runs.

## 2. CLI Structure

Two binaries share one runner class (`apps/dartclaw_cli/lib/src/runner.dart`):

| Binary | Builder | Surface |
|---|---|---|
| `bin/dartclaw.dart` | `buildDartclawRunner()` | Full CLI. Global options `--config`, `--server`, `--token`, `--version` |
| `bin/dartclaw_workflow.dart` | `buildDartclawWorkflowRunner()` | Lean `dartclaw-workflow`: workflow verbs at the root (`run`, `list`, `show`, `validate`, `status`, `cancel`, `pause`, `resume`, `retry`, `cleanup-skills`) plus `init` and `rebuild-index`. Global options `--config`, `--version` only |

Registration lives in `runner.dart` so the shipped command set is reachable from tests. Both runners mount the same
`workflowSubcommands()` list; the full tree also gets connected-only `workflow runs`.

The lean runner always takes the standalone lane: it accepts and ignores `--standalone`, exposes no `--server` or
`--token`, and registers neither `serve` nor the server `status`. Its commands hold a client-free `WorkflowConnection`
interface; only the full runner supplies `ApiWorkflowConnection`. A `dart:io` health probe (`server_reachability.dart`)
keeps the live-server writer guard without the API client. `apps/dartclaw_cli/test/tool/build_tool_test.dart` builds both
artifacts and asserts that the server, API, web and channel-adapter libraries are absent from the lean one and present in
the full one.

Command families (`apps/dartclaw_cli/lib/src/commands/`):

| Kind | Commands |
|---|---|
| Server-backed (`ConnectedCommand`) | `tasks`, `projects`, `sessions` (list, show, messages, delete, archive), `runners`, `traces`, `jobs`, `config get\|set\|show`, `search inspect`, `status`, `stop`, `workflow runs` |
| Mixed (connected default, `--standalone` opt-in) | `workflow run\|status\|pause\|resume\|cancel\|retry\|show` |
| Local only | `serve`, `service`, `init`/`setup`, `doctor`, `token`, `auth`, `secrets`, `google-auth`, `rebuild-index`, `sessions cleanup`, `search download-model`, `config schema`, `workflow list\|validate\|cleanup-skills` |

Local commands stay available when no server runs: they touch the filesystem or data directory, manage the process or
installation, or (for `workflow list`, `validate`) read definitions from disk. `stop` posts `/api/emergency-stop`.

## 3. Connected vs Standalone

[![CLI paths: connected and standalone](diagrams/cli-api-paths.svg)](diagrams/cli-api-paths.svg)

### Connected mode (default)

`ConnectedCommand` (`connected_command_support.dart`) resolves a `DartclawApiClient` per call:

1. **Address**: `--server` (bare port, host, or URL), else `http://localhost:<server.port>` from config.
2. **Token**: `--token`, else `gateway.token`, else the `gateway_token` file in the data directory; none when
   `gateway.auth_mode` is `none`.
3. Call the route; long-running workflow commands also consume SSE.

Connected mode is preferred because it keeps guard-chain enforcement, shared observability, web UI visibility and a
single source of truth for runtime state. API failures map to exit codes by `connectedExitCode`:

| Failure | Exit |
|---|---|
| Transport (`CONNECTION_REFUSED`, `NETWORK_ERROR`, `TLS_HANDSHAKE_FAILED`) | 3 |
| HTTP 401/403 | 4 |
| Other 4xx | 5 |
| 5xx | 6 |
| Anything else | 1 |

### Standalone mode

`workflow run|status|pause|resume|cancel|retry --standalone` (always on in the lean binary) runs the shared composition
root headlessly (`DartclawRuntime.stageHeadless`, then `completeForExecution`) and drives `dartclaw_workflow` in-process,
with no HTTP server.

- **Writer guard.** The write verbs probe `GET /health` at the resolved server address (200, 401 and 403 count as
  reachable) and abort when a server is up unless `--force`, preventing concurrent writers to shared project and
  workflow files. The probe gives up after 5 s and then counts as no server. A separate exclusive file lock,
  `standalone/execution.owner.lock` (`StandaloneExecutionLease`), refuses a second standalone execution on one data
  directory even under `--force`.
- **Storage.** State lives under `<data_dir>/standalone/`: `execution.json` (`FileExecutionStore`, an atomic checkpoint
  shared by task and workflow repositories), `sessions/`, `turn_state.json` and `kv.json`. `status --standalone` reads
  the same checkpoint. No PostgreSQL connection or schema gate runs, and workflow-only `init` neither writes a database
  reference nor probes readiness. Definitions, credentials and workflow artifacts keep their normal paths. Existing
  database histories stay separate.
- **What headless composition omits** (the `headless` flag of the assembly in `service_wiring.dart`): the HTTP/web/MCP surface, channels,
  personal memory, and recovery of incomplete runs; the project registry is wired read-only. Task, session and turn
  persistence and guarded workflow execution remain. This is the existing headless mode, not a user setting.
- **Credentials and skills.** `CredentialPreflight` and a referenced-provider auth preflight run before execution;
  `--no-skill-bootstrap` skips native skill provisioning. `DARTCLAW_WORKFLOWS_PREFER_SOURCE=1` makes source-tree
  skills and workflow YAML win over embedded built-ins (maintainer profile, standalone path only).

## 4. API Client

`packages/dartclaw_client/lib/src/dartclaw_api_client.dart` is a zero-dependency `dart:io` transport published as the
client tier (re-exported by the `dartclaw` umbrella; also consumed by the desktop app). It applies Bearer auth, offers
JSON GET/POST/PATCH/DELETE helpers, surfaces failures as `DartclawApiException` (`code`, `statusCode`, `details`), and
opens SSE streams with up to three reconnects through an `onDisconnect` callback. It resolves no config and no token;
`apiClientFromConfig` in the CLI does. It mints no per-endpoint DTOs: types the endpoints carry stay owned by core and
workflow. Package rules are in `packages/dartclaw_client/AGENTS.md`.

## 5. Server Route Families

Route files live in `packages/dartclaw_runtime/lib/src/api/`. `authMiddleware` guards everything except `/health`,
`/login`, `/webhook/*` and `/static/*`; webhook routes authenticate per source.

| Family | Routes | File(s) | CLI |
|---|---|---|---|
| Workflows | `/api/workflows/definitions*`, `/run`, `/run-form`, `/runs*` (`/cancel`, `/pause`, `/resume`, `/retry`, `/request-changes`, `/events` SSE) | `workflow_routes.dart` | `workflow` |
| Tasks, goals | `/api/tasks*` (`/start`, `/cancel`, `/review`, `/checkout`, `/artifacts`, `/bindings`), `/api/goals*`, SSE `/api/tasks/events`, `/api/agent-executions/events` | `task_routes.dart`, `goal_routes.dart`, `task_sse_routes.dart` | `tasks` |
| Sessions, conversation | `/api/sessions*` (messages, send, steer, stream, queue, attempts, context, export, attachments, turn-status), `/api/inbox*`, `/api/attention*`, `/api/conversation-search*`, `/api/command-catalog`, `/api/command-actions` | `session_*_routes.dart`, `conversation_search_command_routes.dart` | `sessions` |
| Config and settings | `/api/config*` (including guards and channel allowlists), `/api/settings/*`, `/api/scheduling/jobs*`, `/api/scheduling/tasks*`, `/api/system/restart` | `config_api_routes.dart`, `config_routes.dart` | `config`, `jobs` |
| Projects | `/api/projects*` | `project_routes.dart` | `projects` |
| Runners, providers | `/api/runners*`, `/api/providers` | `runner_routes.dart`, `provider_routes.dart` | `runners` |
| Traces | `/api/traces*` | `trace_routes.dart` | `traces` |
| Memory | `/api/memory/*` | `memory_routes.dart` | none |
| Search inspection | `POST /api/search/inspect` | `search_inspection_routes.dart` | `search inspect` |
| Emergency stop | `/api/emergency-stop` | `emergency_stop_routes.dart` | `stop` |
| Channel pairing | `/api/channels/<type>/dm-pairing*`, `/api/channels/pairing-counts` | `config_api_routes.dart` | none |
| Webhooks | `/webhook/whatsapp`, plus the configured `webhook_path` of Google Chat, GitHub (default `/webhook/github`) and Slack events | `webhook_routes.dart` | none |
| Other | `/health`, `/mcp`, global SSE broadcast `/api/events` | `server.dart`, `config_api_routes.dart` | `status` |

### Behaviors worth knowing

- **Search inspection** (`search inspect --corpus memory|conversation --query <text> [--limit 1..20]`) is opt-in
  diagnostic output over the existing corpus query owners: bounded result identity and provenance, lexical/vector ranks,
  unembedded count and structured degradations. It does not widen agent retrieval payloads. Missing diagnostics return
  `503 SEARCH_INSPECTION_UNAVAILABLE` with no hits.
- **Memory administration** is owner-only (`403` otherwise). `GET /api/memory/corpora` returns opaque selectors;
  `MemoryAdminService` maps a selector only to an already-validated configured or retained `StorageWiring` context, and
  a missing or forged selector is `404 CORPUS_UNAVAILABLE`, never a fallback to the owner corpus. Reads use
  `GET /api/memory/entries[/<id>]`; `POST .../revise|remove` require the selector plus expected collection and entry
  revisions and write through `MemoryApplyService`. The legacy `status`, `files` and `prune` routes are default-corpus
  only and reject any query string. The web Memory page uses the same service.
- **Scheduling mutation** has one authority, `ScheduleMutationService`
  (`scheduling/schedule_mutation.dart`). The `/api/scheduling/*` handlers, the scheduling page and the `schedule_upsert`
  tool all consume it, so the cron rule and the write path cannot fork. A write commits and then applies the jobs to the
  running `ScheduleService`, so it is live before the caller is answered. Under the operator approval mode, a
  model-originated upsert is parked in a pending store and committed only by an operator approval through the same path.

## 6. Workflow Control Path

### Connected run

`workflow run <name>` is implemented by `ApiWorkflowConnection`:

[![Connected workflow run](diagrams/cli-api-workflow-run.svg)](diagrams/cli-api-workflow-run.svg)

A launch the server refuses (400 `INVALID_INPUT`, 404 `DEFINITION_NOT_FOUND`, 409 `WORKFLOW_PRECONDITION_FAILED`) creates
no run; the CLI prints the message and exits 5. The per-run stream opens with a `connected` frame holding the run status
and one status per step. When it drops, the client re-fetches the run and reconnects up to three times, waiting 1, 2
and 4 s, unless the run is already terminal, paused or awaiting approval.

Progress renders through `CliProgressPrinter`, or frames are echoed with `--json`. The final status maps to an exit code
(`standaloneWorkflowExitCode`, shared by both lanes):

| Status | Exit |
|---|---|
| `completed` | 0 |
| `failed` | 1 |
| `cancelled`, `paused`, `awaitingApproval` | 2 |

SIGINT on a connected run is a control action, not a local abort: the first sends `POST /api/workflows/runs/<id>/cancel`
and keeps waiting for the terminal state; a second exits immediately with 1.

### Lifecycle commands

`pause`, `resume`, `cancel` and `retry` POST to `/api/workflows/runs/<id>/<verb>` in connected mode. `workflow runs` is
connected-only. With `--standalone` they drive the in-process engine under the same `/health` guard and `--force`
rule; they never silently fall back to local state. Standalone `workflow run` calls `WorkflowService.start(...)` with
`WorkflowRunOrigin(surface: 'cli')` on the headless runtime.

## 7. Workflow Trigger Surfaces

| Surface | Entry point | Handler |
|---|---|---|
| CLI / JSON API | `POST /api/workflows/run` | `workflow_routes.dart` |
| Web UI form | `POST /api/workflows/run-form` | `workflow_routes.dart` |
| Agent tool | `workflow_list`, `workflow_run` via MCP | `WorkflowListTool` / `WorkflowRunTool` (`mcp/workflow_tools.dart`) |
| GitHub PR webhook | `POST` to `github.webhook_path` (default `/webhook/github`) | `GitHubWebhookHandler` (`github_webhook.dart`) |

All are server-owned; the CLI has no separate trigger logic. The two launch routes share one request shaping behind two
encodings: both read through the capped readers in `api_helpers.dart` and share definition resolution, `PROJECT`
injection and required-variable validation. The JSON route reads a `variables` object, accepts `approvals` and `inline`,
and answers `errorResponse` envelopes. The form route reads `var_`-prefixed fields and answers an HTMX-swappable HTTP
200 fragment on validation failure, because the layout suppresses 4xx/5xx swaps in HTMX 4 and reserves those statuses
for auth and route refusals; a 4xx validation error would vanish from `/workflows`.

## 8. Source Map

```
apps/dartclaw_cli/bin/{dartclaw,dartclaw_workflow}.dart
apps/dartclaw_cli/lib/src/runner.dart
apps/dartclaw_cli/lib/src/commands/
  connected_command_support.dart      ConnectedCommand, client/URI/token resolution, exit codes
  server_reachability.dart            /health probe for the standalone writer guard
  workflow/                           workflow commands, ApiWorkflowConnection, standalone harness, progress rendering
  {tasks,projects,sessions,runners,traces,jobs,config,secrets,auth,service,init}/
  search_command.dart, search_inspect_command.dart
packages/dartclaw_client/lib/src/dartclaw_api_client.dart
packages/dartclaw_runtime/lib/src/api/                      route files (section 5)
packages/dartclaw_runtime/lib/src/runtime/service_wiring.dart   stageHeadless / HeadlessRuntimeStaging
```

## 9. Related Documents

- [system-architecture.md](system-architecture.md)
- [workflow-architecture.md](workflow-architecture.md)
- [configuration-architecture.md](configuration-architecture.md)
- [observability-operations-architecture.md](observability-operations-architecture.md)
- [ADR-018](../adrs/018-cli-onboarding-architecture.md), [ADR-030](../adrs/030-connected-by-default-workflow-execution.md)
