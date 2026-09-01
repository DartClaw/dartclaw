# DartClaw CLI & API Architecture

Reference for DartClaw's operational command-line surface and the server APIs that back it: CLI runner, connected-vs-standalone execution, the shared API client, workflow control, and how command groups map onto server routes.

**Current through**: 0.25

---

## 1. Design Goal

The CLI is an operational surface for a running DartClaw instance, not just a lifecycle wrapper around `serve`, `service`, and token management:

- inspect and control live runtime state
- trigger workflows against the server-owned execution model
- query sessions, traces, jobs, runners, tasks, and projects
- keep local-only commands explicit rather than silently mixing local and server state

The design preserves a clean split:

| Concern | CLI | Server API |
|---|---|---|
| Argument parsing and UX | Yes | No |
| Auth resolution and base-URL resolution | Yes | No |
| Persistent state mutation | No | Yes |
| Runtime orchestration | No | Yes |
| Workflow execution ownership in connected mode | No | Yes |
| Local maintenance / validation commands | Yes | No |

This keeps operational authority in the Dart host while letting terminal users access the same system that the web UI uses.

## 2. Boundary Overview

At a high level, the CLI/API stack looks like this:

```
┌──────────────────────────────────────────────┐
│ dartclaw CLI                                │
│ - DartclawRunner                            │
│ - command groups                            │
│ - DartclawApiClient                         │
│ - local-only helpers                        │
└──────────────────┬───────────────────────────┘
                   │ HTTP + SSE
                   ▼
┌──────────────────────────────────────────────┐
│ dartclaw_runtime                             │
│ - shelf routers                             │
│ - auth middleware                           │
│ - workflow/task/project/session services    │
│ - SSE endpoints                             │
└──────────────────┬───────────────────────────┘
                   │ service calls
                   ▼
┌──────────────────────────────────────────────┐
│ core / workflow packages                    │
│ - runtime orchestration                     │
│ - typed config                              │
│ - SQLite repositories                       │
│ - workflow engine                           │
└──────────────────────────────────────────────┘
```

The key package boundary is:

- `dartclaw_cli` owns command UX, transport, and process-local helpers.
- `dartclaw_runtime` owns HTTP routing, auth, and operational state transitions.
- `dartclaw_workflow` owns workflow execution semantics used by both server and standalone CLI execution.

## 3. CLI Runtime Structure

The CLI entry point lives in:

- `apps/dartclaw_cli/bin/dartclaw.dart`

`DartclawRunner` registers the top-level command families. The operational set is:

- `workflow`
- `tasks`
- `config`
- `projects`
- `sessions`
- `runners`
- `traces`
- `jobs`

Local process/lifecycle command families coexist with them:

- `serve`
- `status`
- `init` / `setup`
- `service`
- `token`
- `rebuild-index`
- `google-auth`

The CLI is intentionally mixed-mode: some commands are local process utilities, others are remote operations over the loopback API.

## 4. Connected vs Standalone

Workflows use an explicit connected-vs-standalone execution split.

### Connected Mode

Connected mode is the default for:

- `workflow run`
- `workflow status`
- `workflow runs`
- `workflow pause`
- `workflow resume`
- `workflow cancel`
- `workflow retry`
- all `tasks`, `config`, `projects`, `sessions`, `runners`, `traces`, and `jobs` commands

In connected mode:

1. The CLI resolves the server address from `--server`, then config, then loopback defaults.
2. It resolves auth from config or the persisted gateway token, unless `auth_mode:none`.
3. It calls the server route.
4. For long-running workflow commands, it also consumes SSE.

The connected path is the preferred operational surface because it preserves:

- guard-chain enforcement
- shared observability
- web/UI visibility
- a single source of truth for runtime state

### Standalone Mode

Standalone mode is available for workflow commands with meaningful local semantics:

- `workflow run --standalone`
- `workflow status --standalone`
- `workflow pause/resume/cancel/retry --standalone`

The standalone path stages the shared composition root headlessly (`DartclawRuntime.stageHeadless`) and drives `dartclaw_workflow` through it, without starting the HTTP server. The write commands (`run`, `pause`, `resume`, `cancel`, `retry`) probe `/health` first and abort unless `--force` is set when a server is already running, preventing accidental state-split or concurrent SQLite use; `status --standalone` is a read against the local tasks database with no probe.

## 5. Shared API Client

The connected command path uses:

- `packages/dartclaw_client/lib/src/dartclaw_api_client.dart` — the transport, owned by `dartclaw_client`
- `apps/dartclaw_cli/lib/src/commands/connected_command_support.dart` — CLI-side construction (`resolveServerUri`, `apiClientFromConfig`, `resolveCliApiClient`) and the shared `DartclawApiException` error policy

`DartclawApiClient` is a dependency-free transport layer built on `dart:io`, published as the client tier rather than owned by the CLI:

- applies Bearer auth when a token is supplied
- normalizes error handling
- supports JSON GET/POST/PATCH/DELETE helpers
- opens SSE streams for workflow progress

The transport is intentionally simple:

| Concern | Behavior |
|---|---|
| Base URI | `--server` override, then config-derived loopback address |
| Auth | `gateway.token`, persisted `gateway_token`, or no header when auth is disabled |
| Errors | Maps connection/auth/version failures to CLI-friendly messages |
| SSE | Used for `workflow run` progress and reconnect-aware lifecycle tracking |

The client is not a general SDK surface; it exists to support the CLI application layer.

## 6. Server API Surface

The CLI primarily talks to these server route families:

| Domain | Routes | Primary CLI family |
|---|---|---|
| Workflow execution | `/api/workflows/*` | `workflow` |
| Tasks | `/api/tasks*` | `tasks` |
| Config | `/api/config`, `/api/settings/*`, `/api/scheduling/jobs*` | `config`, `jobs` |
| Projects | `/api/projects*` | `projects` |
| Sessions | `/api/sessions*` | `sessions` |
| Runners | `/api/runners*` | `runners` |
| Traces | `/api/traces*` | `traces` |

The important design property is that these are the same server APIs used by the web UI and background integrations. The CLI is not a privileged side-channel.

The `/api/scheduling/jobs*` and `/api/scheduling/tasks*` handlers are likewise not the scheduling-mutation authority. Cron validation, the fresh read of `scheduling.jobs`, the modify-write and the restart-pending marker all live in `ScheduleMutationService` (`dartclaw_runtime/lib/src/scheduling/schedule_mutation.dart`); the routes map its outcome onto their status and error codes, and the `schedule_upsert` agent tool consumes the same seam. Neither surface can drift from the other's cron rule, and neither writes `scheduling.jobs` on its own. A written job takes effect only at the next restart: `ScheduleService` takes its job list at construction, which is why every write records the restart marker and why `schedule_list` reports what the running server actually loaded rather than what config says.

## 7. Workflow Control Path

Workflow operations are the richest example of the CLI/API architecture.

### Connected Workflow Run

`workflow run <name>` in connected mode:

1. sends `POST /api/workflows/run`
2. receives the created `WorkflowRun`
3. opens `GET /api/workflows/runs/<id>/events`
4. renders progress with `CliProgressPrinter`
5. maps terminal workflow state to exit code

Current connected-mode exit codes:

| Status | Exit code |
|---|---|
| `completed` | `0` |
| `failed` | `1` |
| `paused` | `2` |
| `cancelled` | `2` |

SIGINT on a connected run becomes a control action, not a local hard abort:

1. CLI sends `POST /api/workflows/runs/<id>/cancel`
2. waits for terminal SSE state when possible
3. exits with the mapped workflow result

### Workflow Lifecycle Commands

Server-backed control commands:

- `workflow runs`
- `workflow pause <id>`
- `workflow resume <id>`
- `workflow cancel <id>`
- `workflow retry <id>`

These default to connected mode. `workflow runs` is connected-only. `pause`, `resume`, `cancel`, and `retry` accept an explicit `--standalone` opt-in (guarded by the same `/health` probe + `--force` safety check); they never silently fall back to local DB state.

### Standalone Workflow Run

The standalone path still calls the same workflow package, but through local wiring:

- builds local repositories and task services
- calls `WorkflowService.start(..., headless: true)`
- auto-accepts review-mode steps for unattended execution

This keeps behavioral parity where practical, but the authoritative operational model is the connected one.

## 8. Workflow Trigger Surfaces

Workflow trigger surfaces, direct and indirect:

| Surface | Entry point | Handler |
|---|---|---|
| CLI / JSON API | `POST /api/workflows/run` | `workflow_routes.dart` |
| Web UI form | `POST /api/workflows/run-form` | `workflow_routes.dart` |
| Agent tool | `workflow_list` and `workflow_run` through the registered MCP surface | `WorkflowListTool` / `WorkflowRunTool` |
| GitHub PR webhook | `POST /webhook/github` | `GitHubWebhookHandler` |

These are all server-owned surfaces. The CLI does not implement separate logic for them; it interoperates with the same workflow runtime through the API.

The two launch routes are one request shaping behind two encodings: both read through the shared capped reader in
`api_helpers.dart`, then share the definition resolution, `PROJECT` injection and required-variable validation. Only the
field extraction and the rendering differ – the JSON route reads a `variables` object and can set `approvals`/`inline`
and answers `errorResponse` envelopes; the form route reads `var_`-prefixed fields and answers an HTMX-swappable HTTP
200 fragment on failure, because HTMX drops the body on a 4xx and the launch error would vanish from `/workflows`.

## 9. Local-Only Commands

Not every CLI command is server-backed. Some remain intentionally local:

| Command | Why local |
|---|---|
| `workflow list` | Reads workflow definitions from disk without requiring a server |
| `workflow validate` | Parser/validator preflight for authoring |
| `sessions cleanup` | Local maintenance against the filesystem/data directory |
| `token *` | Local gateway token management |
| `rebuild-index` | Local rebuild of the derived search index |
| `serve` / `service` / `init` | Process and installation lifecycle |

This split is important because it keeps low-level maintenance available even when the server is not running.

## 10. Source Map

Primary implementation files:

```
apps/dartclaw_cli/bin/dartclaw.dart
apps/dartclaw_cli/lib/src/runner.dart
apps/dartclaw_cli/lib/src/commands/connected_command_support.dart
apps/dartclaw_cli/lib/src/commands/
  workflow/
  tasks/
  config/
  projects/
  sessions/
  runners/
  traces/
  jobs/

packages/dartclaw_runtime/lib/src/api/
  workflow_routes.dart
  task_routes.dart
  config_api_routes.dart
  project_routes.dart
  session_routes.dart
  trace_routes.dart
  chat_command_handler.dart
  github_webhook.dart
```

## 11. Related Documents

- [system-architecture.md](system-architecture.md)
- [workflow-architecture.md](workflow-architecture.md)
- [configuration-architecture.md](configuration-architecture.md)
- [observability-operations-architecture.md](observability-operations-architecture.md)
- [ADR-018](../adrs/018-cli-onboarding-architecture.md)
