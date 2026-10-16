# Observability & Operations Architecture

How a running DartClaw reports on itself: alerts, health, audit log, usage accounting, structured logs, SSE streams, context and compaction tracking, scheduled operations, and the observable side of governance. Enforcement of rate limits, budgets, loop detection and emergency controls is owned by [Security Architecture](security-architecture.md); this document covers only what those controls emit. Event-bus mechanics are in [Session & State Architecture](session-state-architecture.md), task events and turn traces in [Task & Execution Architecture](task-execution-architecture.md), and stores in [Data Model & Persistence](data-model.md).

**Current through**: 0.28.0

---

## 1. Overview

| Dimension | Purpose | Consumer |
|-----------|---------|----------|
| Alerts | Push critical events to channels | Operator (WhatsApp, Signal, Google Chat, Slack) |
| Health | Worker, provider, credential and container readiness | Load balancers, health dashboard |
| Audit | Guard verdicts and fail-closed decisions | Security review |
| Usage | Token and cost accounting | Budgets, capacity planning |
| Logging | Redacted, session-correlated logs | Debugging |
| SSE | Live task, runner, workflow and system state | Web UI |
| Context | Context-window warnings, compaction lifecycle | Turn orchestration |
| Governance signals | Budget, rate-limit, loop and stop notifications | Operator |

Design rules that hold across the stack:

1. **Operator-visible.** Critical events reach the operator's channel through the same channel infrastructure as user messages, not only a log file.
2. **Observability stays off the critical path.** Usage, trace and guard-verdict writes are unawaited and log their own failures. The exception is deliberate: producers that must fail closed (egress, approvals, refusals) call `GuardAuditLogger.writeEntry`, which is awaited and propagates a write failure to the caller (§4).
3. **One producer per signal.** Credential health, capacity lifecycle and alert classification each have a single writer so two paths cannot report divergent state (§2, §3, §7).

### Signal flow

[![Observability signal flow: sources, collectors, sinks](diagrams/observability-signal-flow.svg)](diagrams/observability-signal-flow.svg)

---

## 2. Alerts

`AlertRouter` maps `DartclawEvent`s to operator notifications. Disabled by default (`alerts.enabled: false`) and needs at least one target.

[![Alert pipeline: classify, route, throttle, deliver](diagrams/observability-alert-pipeline.svg)](diagrams/observability-alert-pipeline.svg)

### classifyAlert

A pure function returning alert type, severity, body and detail fields together; nothing else decides any of them. Its switch names every `DartclawEvent` subtype with no wildcard arm, so a new event type fails the build until it is classified or explicitly mapped to `null` ([ADR-057](../adrs/057-workflow-events-stay-in-the-sealed-event-library.md)).

| Event | Alert type | Severity |
|-------|-----------|----------|
| `GuardBlockEvent` | `guard_block` | warning |
| `ContainerCrashedEvent` | `container_crash` | critical |
| `TaskStatusChangedEvent` (to `failed`) | `task_failure` | warning |
| `ScheduledJobFailedEvent` | `job_failure` | critical |
| `BudgetWarningEvent`, `WorkflowBudgetWarningEvent` | `budget_warning` | warning |
| `CompactionCompletedEvent` | `compaction` | info |
| `LoopDetectedEvent` | `loop_detected` | critical |
| `EmergencyStopEvent` | `emergency_stop` | critical |
| `CredentialHealthChangedEvent` `nearing-expiry` / `refresh-failure` | `credential_expiry` / `credential_refresh_failure` | warning |
| `CredentialHealthChangedEvent` `reauth-required` / `contract-break` | `credential_reauth_required` / `credential_contract_break` | critical |

`healthy` and `unknown` credential states are recorded but never alerted: a recovery message is noise and an uncheckable credential is not a fault. The daily token budget does not appear here: it has no EventBus event, only an SSE broadcast and a channel notification (§11).

**Task-failure filter.** A failed task that originated from a DM or group channel session is not alerted, because `TaskNotificationSubscriber` already told that user. Web, cron and API origins always alert. A task that cannot be looked up is skipped; a malformed session key fails open (alert delivered). `shouldAlertTaskFailure` in `alert_classifier.dart`.

### Routing, formatting, throttling

- **Targets** (`AlertsConfig.routes`): no targets means nothing is sent; empty `routes` sends every classified event to all targets; `routes[type] = ['*']` means all; indices select targets; a type with no entry is dropped; an out-of-range index logs a warning and is skipped.
- **Formatter** is stateless and event-agnostic. Google Chat gets a Cards v2 card with a severity-colored header; every other channel gets `[SEVERITY] Title: body`. It owns the alert-type-to-title table and the burst summary text.
- **Throttle** keys on `alertType:channel:recipient`. The first alert delivers immediately; later ones inside `cooldownSeconds` are suppressed and counted; when the window ends, `suppressedCount >= burstThreshold` delivers one summary carrying the type's severity, otherwise nothing. Reconfiguration applies to windows opened afterwards.
- **Delivery** is best effort: an unknown channel type logs a warning, a send failure logs an error, nothing retries.
- **Reconfigure.** `AlertRouter` watches `alerts.*` and applies changes to the next event without resubscribing.

| Key | Default |
|-----|---------|
| `alerts.enabled` | `false` |
| `alerts.cooldown_seconds` | `300` |
| `alerts.burst_threshold` | `5` |
| `alerts.targets`, `alerts.routes` | empty |

Sources: `packages/dartclaw_runtime/lib/src/alerts/` (`alert_classifier.dart`, `alert_router.dart`, `alert_formatter.dart`, `alert_throttle.dart`, `alert_delivery_adapter.dart`), `packages/dartclaw_kernel/lib/src/alerts_config.dart`.

---

## 3. Health

### HealthService and `GET /health`

`HealthService.getStatus()` backs the unauthenticated `GET /health` route and the health dashboard (`/health-dashboard`, `HealthDashboardPage`). Filesystem-derived values are cached for 60 seconds.

| Field | Source |
|-------|--------|
| `status` | `healthStatusForWorkerState(worker.state)`: `idle`/`busy` → `healthy`, `crashed` or no worker → `degraded`, `stopped` → `unhealthy` |
| `uptime_s`, `version` | process start, `dartclawVersion` |
| `worker_state` | primary `AgentHarness.state` |
| `session_count` | session directories under the sessions dir |
| `db_size_bytes` | byte length of `<data_dir>/search.db`. Known defect: PostgreSQL storage never creates that file, so it always reports 0 (`HealthService._dbSize` catches the missing file); it should read the database health projection |
| `artifact_disk_bytes` | recursive size of `tasks/*/artifacts` |
| `daily_usage` | `UsageTracker.dailySummary()`, when present |
| `pubsub`, `slack` | `PubSubHealthReporter` (`dartclaw_google_chat`), `SlackHealthReporter` (`dartclaw_slack`), when the channel is configured |

`/health` is unauthenticated, so reporters expose counters, timestamps and reason codes only, never IDs, secrets or message content. `PubSubHealthReporter` always returns a map (`status: disabled` when unconfigured) so the dashboard can render "Not configured".

`healthStatusForWorkerState` is the only worker-state to health-string mapping in the workspace. Every `WorkerState` is named so a new state fails to compile instead of reading as healthy.

**Host health is not provider availability.** `status` projects one worker's lifecycle. Provider availability (`ProviderStatus.health` on `GET /api/providers` and the settings provider cards) is computed from different inputs and never reads a worker: `unavailable` when the binary is missing, `degraded` when the credential is absent or degraded or capacity is reduced (quarantined slots, `effective < configured`), else `healthy`, even with no worker running. The vocabularies stay separate. `ProviderStatusService` also carries per-provider capacity counts and the credential-health block.

Execution capacity is not on `/health`; see §7.

### CredentialHealthMonitor

The single writer of per-provider credential health (`alerts/credential_health_monitor.dart`). Three producers enter through it: the hourly `credential-health` scheduled job (`probe()`), the fail-closed admission refusal, and upstream adapter classifications (`report()`). It keeps last-known state per provider (process-local) and acts only on a transition: it records the state on `ProviderStatusService`, fires `CredentialHealthChangedEvent` (consumed by `AlertRouter`), and logs a warning for degraded states. The warning is unconditional because `AlertRouter` returns early when alerts are off, unrouted or untargeted, and credential health must never be silent. A restart re-announces a condition that is still true.

Producers must call `report()`; firing the event directly would reintroduce divergent per-path reports. Credential mechanics are in [Security Architecture](security-architecture.md).

### Container health

`ContainerHealthMonitor` polls each watched container (default every 10 s, 5 s per check) and fires `ContainerCrashedEvent` on a running-to-not-running transition and `ContainerStartedEvent` on recovery. An `unknown` result (daemon blip) holds the last state. An authority is unwatched before its teardown, so a normal release is never reported as a crash. See [Security Architecture](security-architecture.md) § Container Health Monitoring.

---

## 4. Audit Logging

Guard verdicts and Claude permission denials reach the logger through `GuardAuditSubscriber`, which bridges `GuardBlockEvent` and `ToolPermissionDeniedEvent` from the EventBus (it lives in `dartclaw_runtime` so the kernel logger stays free of the bus). Producers that must fail closed call the logger directly. Both paths append to `{dataDir}/audit-YYYY-MM-DD.ndjson`, which `AuditLogReader` serves to the audit table.

### GuardAuditLogger

`GuardAuditLogger` (`dartclaw_kernel`) writes every entry to the logger (INFO pass, WARNING warn, SEVERE block) and, when `dataDir` is set, appends an NDJSON line to the partition for the entry's date. All appends share one `_pendingWrite` future chain, which serializes them and is reset after a failed awaited write so one failure cannot silence the trail.

| Method | Write | Used by |
|--------|-------|---------|
| `logVerdict`, `logPermissionDenied` | unawaited, failures logged | `GuardAuditSubscriber` (guard verdicts; `guard: 'PermissionDenied'`, `verdict: 'denied'` for Claude's own permission layer) |
| `writeEntry` | awaited, failure propagates | producers that must fail closed: outbound MCP and egress, knowledge writes, review and run-approval gates, refusal audits, Slack webhook, database egress |
| `flush()` | awaits appends queued at call time | shutdown; never throws |

`AuditEntry` carries `timestamp`, `guard`, `hook`, `verdict`, optional `reason`, `rawProviderToolName`, `agentId`, `sessionId`, `channel`, `peerId`, `server`, `tool`, `decision`, `principal`, `credentialRef` (a reference name, never a value), `runId` and `stepId`. Null fields are omitted from the JSON, so older lines parse unchanged. Guard verdicts keep the logical agent, canonical tool and provider-native tool name end to end.

**Run-resolution entries.** `WorkflowRunControl` writes one entry per attempt to resolve a workflow approval: guard `RunApprovalGate`, `runId`/`stepId` set, no nonce. Filter the audit table by that guard to list them. The rule and the entry fields are in [Security Architecture](security-architecture.md) § Run approval gate.

### Partitions and retention

New entries go to `audit-YYYY-MM-DD.ndjson`. A legacy `audit.ndjson` stays readable and ages out by modification date. `cleanOldFiles(guard_audit.max_retention_days)` (default 30, `0` disables) runs inside the `session-maintenance` job and deletes dated partitions older than the window. Chain integrity and tamper resistance are not provided here; see [Security Architecture](security-architecture.md) § Audit Chain.

### AuditLogReader

`AuditLogReader.read` reads every retained audit file on each call (no cache), orders newest first with ties broken by append order, then filters and paginates (25 per page). Filters AND together: `verdictFilter` (exact) and `guardFilter` (case-insensitive substring). A file read failure throws, so the dashboard never presents a partial trail as complete; malformed lines are skipped with a warning. The web UI renders it as `audit_table.dart` inside `/health-dashboard`, with an HTMX fragment at `/health-dashboard/audit` (`verdict`, `guard`, `page` query parameters).

Sources: `packages/dartclaw_kernel/lib/src/guard_audit.dart`, `packages/dartclaw_runtime/lib/src/audit/`.

---

## 5. Usage and Token Accounting

### UsageTracker

After each completed turn `TurnRunner` calls `UsageTracker.record(UsageEvent)` unawaited. Each of its four steps (append, aggregate, rotate, budget log) is independently guarded, so one failure skips only that step.

- **`usage.jsonl`** in the data dir: one line per turn (`timestamp`, `session_id`, `agent_name`, token counts, `token_usage_complete`, `duration_ms`). Past `usage.max_file_size_bytes` (10 MB) it is renamed to `usage.jsonl.1`, replacing any earlier backup.
- **Daily KV aggregate** `usage_daily:YYYY-MM-DD`: `total_input_tokens`, `total_output_tokens`, `token_usage_complete` (true only while every turn was fully measured), `by_agent` (`input`, `output`, `turns`), and `budget_warning_posted_at` once `BudgetEnforcer` has posted its warning. The date is the server-local date of the event.
- **`agent_name`** is the turn's agent: `main`, a logical or channel agent ID, `task`, or `cron:<jobId>` (the heartbeat is the job `heartbeat`, so `cron:heartbeat`).
- **`usage.budget_warning_tokens`** (default unset) only logs a warning on every record once the daily total crosses it. It is unrelated to the governance budget, which is `governance.budget.daily_tokens` (§11).

### Session and task cost accounting

Cumulative per-session usage lives in KV `session_cost:<sessionId>`, written by `TurnRunner` for durable sessions: `input_tokens`, `output_tokens`, `cache_read_tokens`, `cache_write_tokens`, `total_tokens`, `effective_tokens`, `estimated_cost_usd`, `cost_reported_turn_count`, `turn_count`, `provider`, `token_usage_complete`. Task budgets, workflow budgets and the web usage views read it. Rules that keep it comparable across harnesses:

- **Fresh input.** Counts mean fresh input only (excluding cache reads). Claude reports it directly; Codex input is normalized at the protocol boundary (`input_tokens - cache_read_tokens`). `effective_tokens` (`computeEffectiveTokens`, `dartclaw_core`) weights cache writes 1.25x and cache reads 0.1x.
- **Claude** usage covers the main conversation only. `TurnRunner._normalizeTurnUsage` diffs the CLI's cumulative per-model `modelUsage` snapshot (stored as `claude_native_snapshot`) against the previous one to credit subagent and delegated-model tokens once per turn. When the snapshot is missing or not comparable (new native session, shrinking counter, accounting that was interrupted), it falls back to the main-session tokens and marks usage incomplete. Cost comes from the provider's cumulative `total_cost_usd` when comparable.
- **Codex** reports on `thread/tokenUsage/updated`, not `turn/completed`. `total` is cumulative per thread and `last` is only the latest model request, so `CodexProtocolAdapter` keeps the latest `total` per `threadId` and credits a settled turn with every thread's growth since the previous settled turn. A subagent runs on its own thread whose counter starts at zero; `CodexHarness` lets usage notifications from any thread through its turn-correlation filter while still dropping a child's `turn/*` frames (they would settle the parent). Codex has no price table, so `estimated_cost_usd` stays null (`supportsCostReporting` is false).
- **Cost visibility.** Readers (`readSessionUsage`) expose `estimated_cost_usd` only when `cost_reported_turn_count == turn_count`. Older entries that stored `cached_input_tokens` still read as cache-read tokens.
- **Interrupted accounting.** `pending_accounting_turn_id` is written before the provider call; a turn that finds a leftover marker marks usage incomplete rather than guessing.
- **Boot cleanup.** Legacy `session_cost:*` entries with the old workflow-only schema are dropped once at startup (`service_wiring_workflow.dart`).

**Workflow step progress.** The workflow one-shot runner fires `WorkflowCliTurnProgressEvent` after each completed turn of a step's prompt chain, carrying the step's accumulated tokens and `turnIndex`, so a long `implement` step is observable before it exits. It is forwarded on the per-run workflow SSE stream as `workflow_cli_turn_progress`.

Budget layering (daily `governance.budget.daily_tokens`, per-task `tasks.budget.default_max_tokens`) and its enforcement are in [Security Architecture](security-architecture.md) § Runtime Governance and [Task & Execution Architecture](task-execution-architecture.md).

### Turn traces and retrieval diagnostics

Each turn also produces a `TurnTrace` persisted by `TurnTraceService` (PostgreSQL `turns` table, or the file execution store for standalone runs) and served by `GET /api/traces` and `GET /api/traces/<id>` (limit capped at 500). Schema, the bounded `tool_calls` envelope and memory-search `sourceLocators` are in [Data Model & Persistence](data-model.md); the model and query surface in [Task & Execution Architecture](task-execution-architecture.md) § 8 (Turn Traces).

`POST /api/search/inspect` (`dartclaw search inspect`) returns result identity plus ranking evidence for the `memory` or `conversation` corpus: per candidate the one-based keyword and vector ranks, the weighted-RRF contributions (keyword 0.25, vector 0.75) and their fused sum, plus the corpus's unembedded count and any fallback or stale-vector degradations. Snippets are capped at 240 Unicode scalars. If diagnostics are unavailable (no evidence, unknown unembedded count, memory index not current) it answers `503 SEARCH_INSPECTION_UNAVAILABLE` with no hits. Responses carry no raw query, document body, vector, credential or provider error text. Code: `api/search_inspection_routes.dart`, `packages/dartclaw_search/lib/src/hybrid_search.dart`.

Sources: `packages/dartclaw_runtime/lib/src/observability/usage_tracker.dart`, `turn_runner_execution.dart`, `packages/dartclaw_kernel/lib/src/usage_config.dart`.

---

## 6. Structured Logging

Records flow `Logger.root.onRecord` → `LogService` → `LogFormatter` → `LogRedactor` → stderr (always) and the optional file sink (append).

- **`LogService.fromConfig`** builds the formatter from `logging.*`, sets the root level, and opens the optional file sink. It is installed by `serve` and by the standalone workflow lifecycle.
- **`HumanFormatter`**: `LEVEL: timestamp [session=X turn=Y] Logger: message`, ANSI-colored by level and per logger name only when stderr is a terminal. **`JsonFormatter`**: one NDJSON object per record (`level`, `time`, `logger`, `message`, optional `sessionId`, `turnId`, `error`, `stackTrace`).
- **`LogRedactor`** wraps `MessageRedactor` (`dartclaw_kernel`) and runs on the finished line in both formatters, so built-in patterns plus `logging.redact_patterns` apply to messages, errors and stack traces alike.
- **`LogContext.runWith`** binds session and turn IDs to a zone; `TurnRunner` wraps each turn so every record downstream is correlated.

Codex native questions DartClaw cannot answer are surfaced only as a WARNING through this path: source thread, turn and item IDs plus question titles and options, JSON-encoded so embedded newlines stay in one record. No rollout or full protocol frame is logged.

| Key | Default |
|-----|---------|
| `logging.format` | `human` (`json`) |
| `logging.level` | `INFO` |
| `logging.file` | unset (stderr only) |
| `logging.redact_patterns` | empty |

Sources: `packages/dartclaw_runtime/lib/src/logging/`, `packages/dartclaw_kernel/lib/src/logging_config.dart`, `message_redactor.dart`.

---

## 7. Real-Time Streaming (SSE)

All live UI updates use Server-Sent Events, not WebSocket: it works through reverse proxies and reconnects natively. Helpers in `api/sse_broadcast.dart` (`sseResponse`, `sseDataFrame`, `sseEventFrame`, `eventStreamHeadersNoBuffer`, which sets `X-Accel-Buffering: no`). Each stream cancels its EventBus subscriptions in `controller.onCancel`.

[![SSE topology: five streams and what feeds them](diagrams/observability-sse-topology.svg)](diagrams/observability-sse-topology.svg)

| Endpoint | Scope |
|----------|-------|
| `GET /api/tasks/events` | Tasks, runners, capacity, projects, workflow sidebar |
| `GET /api/events` | Global `SseBroadcast` (system signals) |
| `GET /api/sessions/<id>/stream?turn=<turnId>` | One turn's chat stream |
| `GET /api/workflows/runs/<id>/events` | One workflow run (wire format in [Workflow Architecture](workflow-architecture.md)) |
| `GET /api/agent-executions/events` | `agent_execution_status_changed` |
| `GET /api/tasks/sidebar-state` | JSON snapshot of the same sidebar state |

### Task stream (`GET /api/tasks/events`)

The first frame is `connected` with the review count, active tasks, runners plus capacity, projects and active workflows; clients then apply deltas. Frames carry a `type` field.

| `type` | Trigger |
|--------|---------|
| `task_status_changed` | `TaskStatusChangedEvent` (also re-sends review count, active tasks, active workflows) |
| `runner_state` | `RunnerStateChangedEvent` (`runnerId`, `state`, `currentTaskId`) |
| `execution_capacity` | `RunnerObserver.capacityChanges` |
| `project_status` | `ProjectStatusChangedEvent` |
| `task_progress` | `TaskProgressTracker` |
| `task_event` | `TaskEventCreatedEvent`, with compact icon/text for the dashboard |
| `turn_wait_state` | `TurnWaitStateChangedEvent` (waiting or stuck, reason, can-cancel) |
| `workflow_sidebar_update` | `WorkflowRunStatusChangedEvent`, `WorkflowStepCompletedEvent` |

`task_progress` snapshots are throttled to one per second per task. `TaskProgressTracker` internals are in [Task & Execution Architecture](task-execution-architecture.md) § 7 (Task Events and Live Progress).

### Global broadcast (`GET /api/events`)

`SseBroadcast` fans named events (`event: <name>`) out to every client and drops closed ones. Producers: `TurnGovernanceEnforcer` (`budget_warning`, `loop_detected`, `rate_limit_warning`), `EmergencyStopHandler` (`emergency_stop`), `TurnRunner` (`context_warning`, `turn_progress_stall`), `DeliveryService` (`announce`, scheduled-job results), `ConversationService` and `InboxService` (`conversation_changed`), and `EventBusSseBridge` (`loop_detected`, `task_review_ready`, `compaction_starting`, `conversation_changed` with `work_state` for wait-state changes). The bridge deliberately excludes `EmergencyStopEvent`: its SSE frame stays with `EmergencyStopHandler` to avoid duplicate critical-stop frames. `SseBroadcast` exists only when the primary lane is enabled; `/api/events` answers 503 otherwise.

### Chat stream

`sseStreamResponse` streams one turn: `delta`, `tool_use` and `tool_result` as HTML fragments (redacted and escaped), terminated by `done`, with `turn_error` or `turn_cancelled` before it. A turn that settled before the client connected replays its terminal frames from `TurnManager.recentOutcome`; an unknown turn is `404 TURN_NOT_FOUND`. The stream is transient: durable messages and `ConversationState` are the recovery authority, and clients answer `conversation_changed` (session ID plus revision) by refetching the snapshot instead of rebuilding state from events. Effective-context telemetry records its source and freshness when the adapter provides them; absence stays null. The attention feed derives from durable completion, failure and input-request records, and action availability is recomputed from the live request and owning turn, never from read or dismiss state (see [Session & State Architecture](session-state-architecture.md)).

### Runner and capacity observability

`ExecutionCoordinator` is the single authority for execution allocation after governance admits a turn. It publishes `ExecutionEvent`s (`capacityChanged`, `acquired`, `released`, `disposed`, `quarantined`, `runnerCreated`, `turnSettled`) that `RunnerObserver` folds into per-runner metrics and a capacity view; `RunnerObserver` and the SSE `runner_state` stream are fed from this stream alone.

- **`GET /api/runners[/<id>]`** returns per-runner metrics and an aggregate `capacity` object (`configured`, `effective`, `active`, `available`, `queued`, `cached`, `quarantined`, `runnerCount`, `primaryActive`); `ExecutionCoordinator.snapshot` holds the same counts per provider. `available = effective - active`; quarantined slots reduce `effective` until recovery or restart; the cached count is diagnostic and never adds capacity. Metric accumulation is `RunnerObserver`'s ([Task & Execution Architecture](task-execution-architecture.md) § 7).
- **One terminal event per observed teardown**, carrying the worker's runner ID: `disposed` when teardown and root-process termination are confirmed, `quarantined` when they are not. Where a slot can still be withheld, it is withheld first, so a crash is never reported ahead of the degradation it explains ([ADR-058](../adrs/058-report-quarantined-workers-truthfully.md)). Coordinator shutdown is the exception (gates are closed): its tombstone has no matching quarantined slot. A teardown with no observed runner ID (pre-registration factory failure) stays capacity-only.
- `RunnerObserver` maps `quarantined` to `crashed`, clears the runner's task and session IDs, and keeps that tombstone in `/api/runners` until restart. `disposed` removes the runner. The lease release that follows carries no runner ID, so it cannot overwrite the outcome.
- **Do not emit lifecycle or outcome transitions from anywhere else.** Another surface doing so races lease release or double-counts turn metrics. `TurnRunner` reports each terminal outcome once through the coordinator, which keys it to the active runner ID before `RunnerObserver` accumulates it.

Sources: `packages/dartclaw_runtime/lib/src/api/` (`task_sse_routes.dart`, `sse_broadcast.dart`, `event_bus_sse_bridge.dart`, `stream_handler.dart`, `runner_routes.dart`), `task/runner_observer.dart`, `task/task_progress_tracker.dart`, `execution_coordinator.dart` and its `part` files.

---

## 8. Context Monitoring and Compaction

### ContextMonitor

One `ContextMonitor` is shared by all `TurnRunner`s and reconfigures on `context.*`. It tracks the context window (from the harness `SystemInitEvent`) and the main conversation's input tokens (not billable delegated tokens).

- **Warning.** After a turn, `checkThreshold(sessionId)` returns true once per session when usage reaches `context.warning_threshold` percent (default 80, clamped 50 to 99); `TurnRunner` then broadcasts `context_warning` on the global SSE channel.
- **Pre-compaction flush.** After a turn, `shouldFlushForCompactionSignal` is true when tokens exceed `contextWindow - context.reserve_tokens` (default 20000) and no flush is pending, but it is suppressed when the harness has a deterministic pre-compact signal (`supportsPreCompactHook`: true for Claude, false for Codex and ACP). The flush turn asks the agent to persist state to memory. `shouldSkipFlush` deduplicates by compaction cycle and by a SHA-256 hash of the last three messages.

### ResultTrimmer

Soft-trims oversized tool results to head + `...[trimmed N bytes]...` + tail, each slice at most 2 KB and smaller when the cap cannot hold more, so the output fits `context.max_result_bytes` (default 50 KB, live). `McpProtocolHandler` applies it to the successful text result of every `tools/call` it dispatches, including relays of configured MCP servers; error results pass through untouched. The marker is the only record of dropped bytes. `context/result_trimmer.dart`.

### Compaction lifecycle

[![Compaction lifecycle: Claude and Codex sources, subscribers](diagrams/observability-compaction-lifecycle.svg)](diagrams/observability-compaction-lifecycle.svg)

`CompactionCompletedEvent.preTokens` is null for Codex and when the wire format omits it; `summary` is reserved and always null. Compact instructions (`context.compact_instructions`, with identifier-preservation text per `context.identifier_preservation`: `strict` default, `off`, `custom`) are composed into the system prompt by `BehaviorFileService` so UUIDs, session keys, task IDs, paths and URLs survive compaction.

| Key | Default |
|-----|---------|
| `context.reserve_tokens` | `20000` |
| `context.max_result_bytes` | 50 KB |
| `context.warning_threshold` | `80` |
| `context.identifier_preservation` | `strict` |

Sources: `packages/dartclaw_runtime/lib/src/context/`, `runtime/harness_wiring_memory.dart`, `turn_runner_execution_loop.dart`, `packages/dartclaw_core/lib/src/events/compaction_events.dart`.

---

## 9. Error and Learning Records

`SelfImprovementService` keeps two bounded record sets in the canonical memory corpus (format and retention in [Data Model & Persistence](data-model.md)): `errors.md` and learnings.

- **Errors** are appended unawaited with an error type (`GUARD_BLOCK`, `RESPONSE_BLOCKED`, `TURN_FAILURE`, `TURN_CANCELLED`), the session ID, the context text and an optional resolution. A failure to write is logged, never thrown. Each record is a canonical `error`-role entry, never searchable, retained up to `maxEntries` (50), earliest insertion evicted first.
- **Learnings** are written through `memory_observe` with `role='learning'`, committed in the same corpus transaction, and remain readable through `memory_search` and `memory_read`.

Writes use the workspace corpus authority's atomic transaction protocol (`changeSelected` with a stale-revision retry). Source: `packages/dartclaw_runtime/lib/src/behavior/self_improvement_service.dart`.

---

## 10. Scheduling and Heartbeat

`ScheduleService` (`scheduling/schedule_service.dart`) runs cron, interval and one-time jobs with a single-shot `Timer` that reschedules after each fire. Task-definition jobs and the task-creation dedup are in [Task & Execution Architecture](task-execution-architecture.md) § 11.

- **Execution.** A prompt job runs as a turn (`source: cron`, `agentName: cron:<jobId>`) in a `SessionKey.cronSession` session on a provider worker lease. Cron, system and on-demand turns never use the primary-interactive lane. Callback jobs (`onExecute`) run directly. Shell jobs are a third kind.
- **Failure.** `retryAttempts` + 1 attempts with `retryDelaySeconds` between; after the last, `ScheduledJobFailedEvent` fires (alert `job_failure`). A fire that overlaps a still-running previous fire is skipped.
- **Delivery** (`DeliveryService`): `announce` (SSE `announce` event plus a message to active DM channel sessions), `webhook`, or `none`.
- **Live change.** `replaceConfigJobs` applies the complete set of config-declared jobs to the running scheduler (new armed, changed re-armed keeping pause state, removed unloaded); built-in jobs are never replaced, and a config entry reusing a built-in ID is refused. Pause, resume and run-now do not change timers.
- **Composed prompts.** A job may supply `composePrompt` and get back a release that runs once the turn has an outcome. `memory-curation` uses it to register the snapshot's entry IDs as the run's apply scope, so `MemoryApplyService.apply` refuses a change set naming entries the run was not shown.

Built-in jobs, registered in `runtime/scheduling_wiring.dart`:

| Job | Notes |
|-----|-------|
| `heartbeat` | Interval `scheduling.heartbeat.interval_minutes` (restart required); always registered and paused when `scheduling.heartbeat.enabled` is false, so the live toggle works from either boot state |
| `git-sync` | Workspace git sync on `workspace.git_sync.interval_minutes`; independent of the heartbeat |
| `credential-health` | Hourly `CredentialHealthMonitor.probe()` (§3), plus one probe at startup |
| `session-maintenance` | Session archival, artifact retention, audit partition cleanup |
| `memory-journal`, `memory-curation` | One per writable memory context, when enabled |
| `memory-pruner` | When `memory.pruning` is enabled |
| `knowledge-inbox`, `knowledge-wiki-lint` | When enabled |

**Heartbeat.** Each fire reads `HEARTBEAT.md` from the workspace. A non-empty file is dispatched as `Process this checklist:` in a session unique to that fire (`cronSession(jobId: 'heartbeat:<timestamp>')`). A missing, empty or undecodable file ends the fire quietly: no turn, no session, no failure event, no retry. The heartbeat never runs a memory-curation turn.

Sources: `packages/dartclaw_runtime/lib/src/scheduling/`, `behavior/heartbeat_job.dart`, `workspace/workspace_git_sync_job.dart`.

---

## 11. Governance Observability

Enforcement lives in [Security Architecture](security-architecture.md) § Runtime Governance. This section lists what each control emits.

### Admission order

`TurnRunner.admitTurn` calls `TurnGovernanceEnforcer` in this order:

[![Turn admission order and governance signals](diagrams/observability-governance-admission.svg)](diagrams/observability-governance-admission.svg)

Steps 3 and 4 record state, which is why the lock precedes them: an attempt the cap rejects never counts. After admission, execution allocation passes to `ExecutionCoordinator` (§7). Per tool call, `recordToolCall` feeds fingerprint detection; after each turn `recordTokensAndCheckVelocity` runs velocity detection (it fires even in `abort` mode because the tokens are already spent; the next pre-turn check aborts).

### Signals by control

| Control | Event bus | SSE (`/api/events`) | Channel / other |
|---------|-----------|---------------------|-----------------|
| Daily budget (`BudgetEnforcer`) | none | `budget_warning` (`tokens_used`, `budget`, `percentage`, `action`) | `BudgetWarningNotifier` message to the originating channel; `/status` slash command shows usage |
| Global turn rate | none | `rate_limit_warning` at 80 % (re-armed below 60 %) | log warning |
| Loop detection | `LoopDetectedEvent` (alert `loop_detected`) | `loop_detected` via `EventBusSseBridge` (`mechanism`, `message`, `action`, `detail`) | `loopDetectionNotifier` |
| Emergency stop | `EmergencyStopEvent` (alert `emergency_stop`) | `emergency_stop` (from `EmergencyStopHandler`) | log |
| Context window | none | `context_warning` | none |

Per-task and per-workflow budgets are separate: `TaskBudgetPolicy` fires `BudgetWarningEvent` and the workflow budget monitor fires `WorkflowBudgetWarningEvent`; both are alerted (§2).

Loop mechanisms: `turnChainDepth`, `tokenVelocity`, `toolFingerprint` (`dartclaw_kernel/lib/src/loop_detection.dart`). The configured action is `warn` (log, notify, continue) or `abort`.

### Daily budget outcomes

`BudgetEnforcer` is the daily scope over the shared `BudgetEngine`. The warn-once marker is `budget_warning_posted_at` in the day's `usage_daily:` aggregate, so it survives restarts. "Today" follows `governance.budget.timezone`.

| Consumption | Outcome | Effect |
|-------------|---------|--------|
| < 80 % | `under` | none |
| >= 80 %, first time today | `warning` (`warningIsNew`) | SSE `budget_warning`, channel notification, marker written |
| >= 80 %, repeat | `warning` | none |
| >= 100 %, `warn` action | `exceeded` | warning if none was posted today; turn proceeds |
| >= 100 %, `block` action | `exceeded` | warning (`action: block`) if none was posted; `BudgetExhaustedException`, turn rejected on every attempt |

Reaching 100 % consumes the day's single warning, so a turn landing straight at the limit still notifies once. The storage read has no error handling on purpose: a failure surfaces instead of silently admitting an over-budget turn.

### Emergency controls

| Command | Handler | Observable effect |
|---------|---------|-------------------|
| `/stop`, `POST /api/emergency-stop` | `EmergencyStopHandler` | cancels active turns, moves running and queued tasks to `cancelled` (trigger `emergency_stop`), fires `EmergencyStopEvent`, broadcasts SSE |
| `/pause` | `PauseController` | queues inbound channel messages (up to `maxQueueSize`, 200) |
| `/resume` | `PauseController` | drains the queue as per-sender concatenation |

All are admin-only. `PauseController` state is in memory and resets on restart.

Sources: `packages/dartclaw_runtime/lib/src/turn_governance_enforcer.dart`, `governance/`, `emergency/emergency_stop_handler.dart`.

---

## 12. Package Ownership

| Package | Observability components |
|---------|--------------------------|
| `dartclaw_kernel` | `GuardAuditLogger`, `AuditEntry`, `MessageRedactor`, `LoopDetector`, `AlertsConfig`, `LoggingConfig`, `UsageConfig`, `ContextConfig`, `SchedulingConfig` |
| `dartclaw_core` | `DartclawEvent` hierarchy, `EventBus`, compaction events, `TurnTrace`, `TurnTraceService`, `computeEffectiveTokens` |
| `dartclaw_google_chat`, `dartclaw_slack` | `PubSubHealthReporter`, `SlackHealthReporter` |
| `dartclaw_runtime` | Everything else: alerts, credential and container health, audit bridging and reading, usage, logging, SSE routes, runner observer, context, scheduling, governance |

---

## Cross-References

- [System Architecture](system-architecture.md): package DAG, composition root, deployment
- [Security Architecture](security-architecture.md): guards, audit chain integrity, run approval gate, credential security, runtime governance enforcement, container health
- [Data Model & Persistence](data-model.md): usage and KV stores, `turns` table, canonical memory documents
- [Task & Execution Architecture](task-execution-architecture.md): task events, turn traces, scheduled tasks, budgets
- [Control Protocol & Harness](control-protocol.md): stream events, compaction hooks, turn lifecycle
- [Session & State Architecture](session-state-architecture.md): event bus, session locking, conversation state
- [Workflow Architecture](workflow-architecture.md): workflow SSE wire format, workflow budgets
- [Channel Messaging Architecture](channel-messaging-architecture.md): channel delivery, task notifications
