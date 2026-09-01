# Observability & Operations Architecture

Comprehensive reference for DartClaw's observability stack: alert routing, health monitoring, audit logging, usage tracking, structured logging, real-time streaming, context intelligence, and governance visibility.

**Current through**: 0.25 worker capacity, capacity-only lane retirement, alert re-cut, kernel formation, and storage absorption.

---

## 1. Overview

DartClaw provides observability across multiple dimensions, each serving a different operational need:

| Dimension | Purpose | Primary Consumer |
|-----------|---------|-----------------|
| **Alerts** | Proactive notification of critical events via channels | Operator (WhatsApp/Signal/Google Chat) |
| **Health** | Runtime status and component readiness | Monitoring dashboards, load balancers |
| **Audit** | Security-relevant guard decisions and tool permission events | Security review, compliance |
| **Usage** | Token consumption and cost accounting | Budget management, capacity planning |
| **Logging** | Structured operational logs with redaction | Debugging, incident response |
| **SSE Streaming** | Real-time task/execution/workflow state to web UI | Web UI, live dashboards |
| **Context** | Context window tracking and compaction awareness | Turn orchestration, session management |
| **Self-Improvement** | Agent-authored learnings and error records | Agent behavior refinement |
| **Governance** | Rate limits, budgets, loop detection visibility | Operator safety controls |

### Design Principles

1. **Operator-visible** -- critical events surface to operators via their preferred channel, not buried in logs
2. **Channel-routable** -- alerts flow through the same channel infrastructure as user messages
3. **File-based where possible** -- audit logs, usage records, and learnings use append-only files with atomic writes, no external database required
4. **Fire-and-forget writes** -- observability never blocks the critical path; all file writes are unawaited
5. **Defense-in-depth** -- audit, governance, and logging form independent layers that each contribute to safety


## 2. Alert System (0.16)

Maps internal EventBus events to operator notifications delivered through configured channels. Disabled by default -- requires explicit opt-in via `alerts.enabled: true`.

### Component Architecture

```
┌──────────┐  on<DartclawEvent>  ┌─────────────┐  classify  ┌───────────────┐
│ EventBus ├────────────────────►│ AlertRouter  ├───────────►│ classifyAlert │
└──────────┘                     │(Reconfigurable)│          └───────┬───────┘
                                 └──────┬────────┘                   │
                                        │ throttle    ┌──────────────┘
                                        ▼             ▼
                                 ┌──────────────┐ ┌──────────────┐
                                 │AlertThrottle │ │AlertFormatter│
                                 └──────┬───────┘ └──────┬───────┘
                                        │                │
                                        ▼                ▼
                                 ┌────────────────────────────┐
                                 │  AlertDeliveryAdapter      │
                                 │  → WhatsApp/Signal/GChat   │
                                 └────────────────────────────┘
```

### classifyAlert

Pure function that maps `DartclawEvent` subtypes to an alert's identity *and* its content -- type identifier, severity, body text and detail fields, returned together. It is the only place any of those are decided, and its switch names every event subtype explicitly with no wildcard arm, so a new event type fails the build until it is consciously classified ([ADR-057](../adrs/057-workflow-events-stay-in-the-sealed-event-library.md)):

| Event Type | Alert Type | Severity |
|------------|-----------|----------|
| `GuardBlockEvent` | `guard_block` | warning |
| `ContainerCrashedEvent` | `container_crash` | critical |
| `TaskStatusChangedEvent` (failed) | `task_failure` | warning |
| `ScheduledJobFailedEvent` | `job_failure` | critical |
| `BudgetWarningEvent` | `budget_warning` | warning |
| `WorkflowBudgetWarningEvent` | `budget_warning` | warning |
| `CompactionCompletedEvent` | `compaction` | info |
| `LoopDetectedEvent` | `loop_detected` | critical |
| `EmergencyStopEvent` | `emergency_stop` | critical |
| `CredentialHealthChangedEvent` (`nearing-expiry`) | `credential_expiry` | warning |
| `CredentialHealthChangedEvent` (`refresh-failure`) | `credential_refresh_failure` | warning |
| `CredentialHealthChangedEvent` (`reauth-required`) | `credential_reauth_required` | critical |
| `CredentialHealthChangedEvent` (`contract-break`) | `credential_contract_break` | critical |

Non-alertable events return `null` and are silently dropped -- including the `healthy` and `unknown` credential-health states, since a recovery message is noise and an uncheckable credential is not a fault.

**Non-channel filter**: Task failure alerts for tasks originating from DM or group channel sessions are suppressed -- those users are already notified via `TaskNotificationSubscriber`. Tasks with web/cron/API origin always generate alerts. On malformed `SessionKey`, the filter fails open (alert delivered rather than silently dropped).

Source: `packages/dartclaw_runtime/lib/src/alerts/alert_classifier.dart`

### AlertRouter

Subscribes to `EventBus.on<DartclawEvent>()` and orchestrates the full pipeline: classify, resolve targets, format, check throttle, deliver. Implements `Reconfigurable` -- watches `alerts.*` config keys and applies changes to the next event without restarting the subscription.

Target resolution via `AlertsConfig.routes`:
- Empty routes map: all events go to all targets
- `routes['guard_block'] = ['*']`: this type goes to all targets
- `routes['compaction'] = ['0', '2']`: this type goes to target indices 0 and 2
- No entry for a type: event is not routed (silently dropped)

Source: `packages/dartclaw_runtime/lib/src/alerts/alert_router.dart`

### AlertFormatter

Stateless formatter producing channel-appropriate `ChannelResponse` objects from an already-classified alert. Google Chat gets Cards v2 with severity-colored headers; all other channels get plain text (`[SEVERITY] Title: body`). It owns the alert-type-to-title table and burst summary formatting, and switches on no event type at all -- an event the classifier dropped cannot be rendered.

Source: `packages/dartclaw_runtime/lib/src/alerts/alert_formatter.dart`

### AlertThrottle

Per-key cooldown tracker. Key: `eventType:channelType:recipient`. First event delivers immediately; subsequent events within cooldown are suppressed. When cooldown expires, if `suppressedCount >= burstThreshold`, a summary is delivered, carrying the classified severity of the alerts it summarises. Each target+type combination is throttled independently.

Source: `packages/dartclaw_runtime/lib/src/alerts/alert_throttle.dart`

### AlertsConfig

| Field | Default | Description |
|-------|---------|-------------|
| `enabled` | `false` | Master switch for alert routing |
| `cooldownSeconds` | `300` | Min seconds between repeated alerts per type |
| `burstThreshold` | `5` | Events before burst-summary mode activates |
| `targets` | `[]` | Channel + recipient pairs (`AlertTarget`) |
| `routes` | `{}` | Event type to target index mapping |

Source: `packages/dartclaw_kernel/lib/src/alerts_config.dart`


## 3. Health Monitoring

### HealthService

Collects runtime health metrics with a 60-second cache TTL to avoid expensive filesystem scans on every request.

Reported metrics:

| Metric | Source | Description |
|--------|--------|-------------|
| `status` | Worker state machine | `healthy` / `degraded` / `unhealthy` |
| `uptime_s` | Process start time | Seconds since server start |
| `worker_state` | `AgentHarness.state` | `idle` / `busy` / `stopped` / `crashed` |
| `session_count` | Directory listing | Count of session subdirectories |
| `db_size_bytes` | File stat | Search index SQLite file size |
| `artifact_disk_bytes` | Recursive scan | Total size of task artifact files |
| `version` | `dartclawVersion` constant | Current DartClaw version |
| `daily_usage` | `UsageTracker.dailySummary()` | Today's token consumption aggregate |
| `pubsub` | `PubSubHealthReporter` | Pub/Sub subsystem status (if configured) |
| `execution` | `ExecutionCoordinator.snapshot` | Primary activity plus per-provider configured/effective/active/queued/cached/quarantined worker counts |

Execution health is lease-derived. A provider is capacity-degraded when quarantine reduces effective capacity, even if cached harness objects appear idle. Workflow executions count as active provider work through their leased worker.

**Host health is not provider availability.** `status` is the sole projection of one worker's lifecycle
(`healthStatusForWorkerState` in `health_service.dart`, the only worker-state → health-string mapping in the
workspace): `idle`/`busy` → `healthy`, `crashed` or no worker → `degraded`, `stopped` → `unhealthy`. Provider
availability (`ProviderStatus.health` on `/api/providers` and the settings provider cards) answers a different
question from different inputs — binary presence, credential resolution, credential health and capacity — and
never reads a worker
lifecycle: a provider whose binary is missing is `unavailable`, and one whose binary and credential resolve is
`healthy` even with no worker running at all. Neither answer is expressible as a worker lifecycle, so the two
vocabularies stay separate; neither derives from the other.

Source: `packages/dartclaw_runtime/lib/src/health/health_service.dart`

### Health Endpoint

`GET /health` returns JSON via shelf `Handler`. Used by load balancers, monitoring systems, and the web UI health dashboard (`health_page.dart` + `health_dashboard.html`).

Source: `packages/dartclaw_runtime/lib/src/health/health_route.dart`

### ContainerHealthMonitor

Periodic check (default: 10s) for all container profiles. Fires `ContainerCrashedEvent` on healthy-to-unhealthy transitions (triggers alert routing) and `ContainerStartedEvent` on recovery. Tasks in a crashed container fail naturally via subprocess termination; this monitor provides structured event notification.

Source: `packages/dartclaw_runtime/lib/src/container/container_health_monitor.dart`

### PubSubHealthReporter

Bridges Google Cloud Pub/Sub health into the HealthService pipeline. Reports `status`, `enabled`, `last_successful_pull`, `consecutive_errors`, and `active_subscriptions`. Always returns a map (never null) so the dashboard displays a clear "Not configured" state when Pub/Sub is disabled.

Source: `packages/dartclaw_google_chat/lib/src/pubsub_health_reporter.dart`


## 4. Audit Logging

### Architecture

```
┌─────────────────────────────────────────────────────┐
│                  Guard Pipeline                      │
│  PreToolUse / PostToolUse guard evaluations          │
└──────────────┬──────────────────────────────────────┘
               │ GuardBlockEvent / ToolPermissionDeniedEvent
               ▼
┌──────────────────────────┐
│  GuardAuditSubscriber    │
│  (dartclaw_runtime)       │
│  Bridges EventBus →      │
│  GuardAuditLogger        │
└──────────┬───────────────┘
           ▼
┌──────────────────────────┐     ┌────────────────────────────┐
│  GuardAuditLogger        │────►│  audit-YYYY-MM-DD.ndjson   │
│  (dartclaw_kernel)     │     │  Date-partitioned files    │
│  Stdout + file sink      │     │  in dataDir                │
└──────────────────────────┘     └────────────────────────────┘
                                          │
                                          ▼
                                 ┌────────────────────────────┐
                                 │  AuditLogReader            │
                                 │  (dartclaw_runtime)         │
                                 │  Paginated read + filter   │
                                 └────────────┬───────────────┘
                                              ▼
                                 ┌────────────────────────────┐
                                 │  Web UI Audit Table        │
                                 │  (audit_table.dart)        │
                                 └────────────────────────────┘
```

### GuardAuditLogger

Structured audit logger in `dartclaw_kernel`. Dual output:

1. **Stdout logging** (always): log level varies by verdict -- INFO for pass, WARNING for warn, SEVERE for block
2. **File sink** (when `dataDir` is set): NDJSON entries appended to date-partitioned files

File operations are fire-and-forget via `unawaited` to avoid affecting guard verdict latency. Write serialization is enforced via a `_pendingWrite` future chain.

**AuditEntry fields**: `timestamp`, `guard`, `hook`, `verdict`, `reason`, `rawProviderToolName`, `agentId`, `sessionId`, `channel`, `peerId`, `server`, `tool`, `decision`, `principal`, `credentialRef`. Guard verdicts preserve the logical agent, canonical tool, and provider-native tool identity end to end.

**Date partitioning**: New entries use `audit-YYYY-MM-DD.ndjson`. A legacy `audit.ndjson` remains readable alongside dated partitions and ages out by file modification date under `cleanOldFiles(maxRetentionDays)`, avoiding non-idempotent copy migration. Dated partitions age out by the date in their filename.

**PermissionDenied logging**: Claude Code's own permission layer events are also captured with `guard: 'PermissionDenied'` and `verdict: 'denied'`.

Source: `packages/dartclaw_kernel/lib/src/guard_audit.dart`

### GuardAuditSubscriber

Bridges `GuardBlockEvent` and `ToolPermissionDeniedEvent` from the core EventBus into the `GuardAuditLogger`. Runs in `dartclaw_runtime` to avoid coupling the security package to the event bus.

Source: `packages/dartclaw_runtime/lib/src/audit/guard_audit_subscriber.dart`

### AuditLogReader

Reads every retained audit NDJSON file on each call, combines legacy and dated entries, and orders equal-timestamp entries by append sequence before filtering and pagination. File read failures propagate so the dashboard cannot present a partial audit trail as complete.

Filters (AND-combined):
- `verdictFilter`: exact match on verdict string (`pass`, `warn`, `block`)
- `guardFilter`: case-insensitive substring match on guard name

Source: `packages/dartclaw_runtime/lib/src/audit/audit_log_reader.dart`


## 5. Usage Tracking

### UsageTracker

Append-only JSONL tracker with daily KV aggregates and per-agent token breakdowns.

```
Turn completes
      │
      ▼
┌──────────────────┐     append     ┌────────────────┐
│  UsageTracker    ├───────────────►│  usage.jsonl   │
│                  │                └────────────────┘
│  record(event)   │     upsert     ┌────────────────┐
│                  ├───────────────►│  KV daily      │
│                  │                │  aggregate     │
│                  │                └────────────────┘
│                  │     check      ┌────────────────┐
│                  ├───────────────►│  File rotation │
│                  │                │  (10MB cap)    │
│                  │                └────────────────┘
│                  │     check      ┌────────────────┐
│                  ├───────────────►│  Budget warn   │
└──────────────────┘                └────────────────┘
```

**UsageEvent fields**: `timestamp`, `sessionId`, `agentName` (values: `main`, `search`, `cron:<jobId>` -- the heartbeat is a scheduled job, so its turns carry `cron:heartbeat` rather than a `heartbeat` value of their own), `inputTokens`, `outputTokens`, `durationMs`.

**Daily KV aggregate structure**:
```json
{
  "total_input_tokens": 42000,
  "total_output_tokens": 8500,
  "by_agent": {
    "main": { "input": 30000, "output": 6000, "turns": 12 },
    "cron:daily-review": { "input": 12000, "output": 2500, "turns": 1 }
  },
  "budget_warning_posted_at": "2026-04-11T14:30:00.000Z"
}
```

**File rotation**: When `usage.jsonl` exceeds `maxFileSizeBytes` (default: 10MB), it is renamed to `usage.jsonl.1` (single backup).

**Budget warning**: When daily total exceeds `budgetWarningTokens`, logs a warning. The `budget_warning_posted_at` marker in KV ensures once-per-day semantics that survive process restarts.

Source: `packages/dartclaw_runtime/lib/src/observability/usage_tracker.dart`

### Token Accounting (0.16.4)

Workflow-owned harness turns treat **observability** and **persistence** as separate concerns:

- Codex app-server `turn.completed` usage is **cumulative per thread**, not a per-turn delta. A resumed probe on 2026-04-22 moved from `input_tokens=27401 / cached_input_tokens=20992 / output_tokens=19` to `input_tokens=54832 / cached_input_tokens=48256 / output_tokens=25`, which confirms overwrite-not-add semantics for the live usage payload.
- Codex emits `cached_input_tokens`; older persisted KV records use the normalized name `cache_read_tokens`. Protocol adaptation normalizes onto the unified schema.
- Persisted task/session usage remains cumulative and uses the unified keys `input_tokens`, `cache_read_tokens`, `cache_write_tokens`, `output_tokens`, `total_tokens`, `effective_tokens`, `estimated_cost_usd`, `turn_count`, and `provider`.
- For Codex, fresh input is derived as `input_tokens - cache_read_tokens`; for Claude, the provider already reports fresh input directly. This keeps budget checks and per-turn attribution on the same semantic footing across harnesses.
- Legacy `session_cost:*` KV entries carrying the old workflow-only schema are dropped once at boot. Readers null-coalesce missing keys so the first post-upgrade render remains safe even before a fresh turn lands.
- Long-running workflow-owned harness runs emit the legacy-named `WorkflowCliTurnProgressEvent`, so operators can observe a 40-minute `implement` step without waiting for process exit. Codex emits on `turn.completed` based on **delta from the previous cumulative snapshot**; Claude emits once per completed assistant message using latest input/cache tokens and summed output tokens.

Budget semantics are intentionally layered:

- `governance.budget.daily_tokens` is an instance-wide daily guardrail.
- `tasks.budget.default_max_tokens` is a per-task cap resolved after explicit task and goal budgets. This is the control that stops a single runaway `implement` task before it can consume the whole daily allowance.
- The `workflows` testing profile (in `dev/testing/profiles/workflows/`) sets `tasks.budget.default_max_tokens: 5000000` so workflow E2E runs fail early and visibly when a single step goes pathological.

### UsageConfig

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `budgetWarningTokens` | `int?` | `null` | Daily token threshold for warning (null = disabled) |
| `maxFileSizeBytes` | `int` | 10MB | JSONL file rotation threshold |

Source: `packages/dartclaw_kernel/lib/src/usage_config.dart`

### Turn Traces

Each agent turn produces a `TurnTrace` record with identity, timing, token and error fields, bounded `toolCalls` detail, exact `toolCallCount`/`failedToolCallCount`, and `toolCallsTruncated`. Computed properties include `totalTokens` and `durationMs`.

Source: `packages/dartclaw_core/lib/src/turn/turn_trace.dart`

### TurnTraceService

SQLite-backed persistence in `turns` table (co-located in tasks.db). Indexed on `session_id`, `task_id`, `started_at`, `model`, `provider`. The `tool_calls` JSON envelope stores bounded records plus exact counts; legacy list rows remain readable. Query API filters by task/session/runner/model/provider/time range with pagination (max 500) and returns exact tool-call aggregates. Exposed via `GET /api/traces`, with single-trace detail via `GET /api/traces/<id>`.

Source: `packages/dartclaw_core/lib/src/storage/turn_trace_service.dart`


## 6. Structured Logging

### Component Stack

```
Logger.root.onRecord → LogService → LogFormatter → LogRedactor → output (stderr + file)
                                         │
                                    ┌────┴────┐
                                    │LogContext│  Zone-based session/turn correlation
                                    └─────────┘
```

### LogService

Configures Dart's `logging` package. Two output targets: stderr (always) and optional file sink (append mode). Factory `LogService.fromConfig()` accepts string config values from `LoggingConfig`.

Source: `packages/dartclaw_runtime/lib/src/logging/log_service.dart`

### LogFormatter

Two implementations:

- **HumanFormatter**: `LEVEL: timestamp [session=X turn=Y] Logger: message`. ANSI color-coded by level (red/yellow/cyan/dim) with per-logger name coloring from a 7-color palette
- **JsonFormatter**: NDJSON with `level`, `time`, `logger`, `message`, optional `sessionId`, `turnId`, `error`, `stackTrace`

Both apply `LogRedactor` (delegates to `MessageRedactor` from `dartclaw_core`) before output.

Sources: `packages/dartclaw_runtime/lib/src/logging/log_formatter.dart`, `log_redactor.dart`

### LogContext

Zone-based log correlation. Set session/turn IDs once via `runWith()`; read anywhere downstream via static getters. Zone values are immutable per zone.

Source: `packages/dartclaw_runtime/lib/src/logging/log_context.dart`

### LoggingConfig

| Field | Default | Description |
|-------|---------|-------------|
| `format` | `human` | Output format: `human` or `json` |
| `file` | `null` | Optional log file path |
| `level` | `INFO` | Minimum log level |
| `redactPatterns` | `[]` | Additional redaction patterns |

Source: `packages/dartclaw_kernel/lib/src/logging_config.dart`


## 7. Real-Time Streaming (SSE)

DartClaw uses Server-Sent Events for all real-time communication with the web UI. No WebSocket -- SSE is simpler, works through reverse proxies, and auto-reconnects natively.

### SSE Architecture

```
┌──────────────────────────────────────────────────────────────┐
│                       Web UI (Browser)                       │
│  EventSource('/api/tasks/events')  EventSource('/chat/sse')  │
└────────────────┬──────────────────────┬──────────────────────┘
                 │                      │
     ┌───────────▼───────────┐  ┌───────▼────────────────────┐
     │  task_sse_routes.dart │  │  stream_handler.dart       │
     │  Global task/agent    │  │  Per-turn chat streaming   │
     │  state SSE            │  │  (delta, tool, result)     │
     └───────────┬───────────┘  └────────────────────────────┘
                 │
     ┌───────────┴──────────────────────────┐
     │              EventBus                 │
     │  TaskStatusChangedEvent               │
     │  RunnerStateChangedEvent               │
     │  ProjectStatusChangedEvent            │
     │  TaskEventCreatedEvent                │
     │  WorkflowRunStatusChangedEvent        │
     │  WorkflowStepCompletedEvent           │
     └──────────────────────────────────────┘
```

### Task SSE Endpoint (`GET /api/tasks/events`)

Central SSE endpoint that multiplexes multiple event types to all connected web UI clients:

| SSE Event Type | Trigger | Payload |
|----------------|---------|---------|
| `connected` | Client connects | Review count, active tasks, execution-capacity snapshot, projects, active workflows |
| `task_status_changed` | `TaskStatusChangedEvent` | Task ID, old/new status, trigger, review count, active tasks |
| `runner_state` | Coordinator lease transition / `RunnerStateChangedEvent` | Execution ID, optional runner ID, lane, provider, state, current task/session |
| `project_status` | `ProjectStatusChangedEvent` | Project ID, old/new status |
| `task_progress` | `TaskProgressTracker` stream | Progress %, current activity, tokens used/budget |
| `task_event` | `TaskEventCreatedEvent` | Kind, details, icon, compact text for dashboard |
| `workflow_sidebar_update` | `WorkflowRunStatusChangedEvent` / `WorkflowStepCompletedEvent` | Active workflows with step progress |

Implementation pattern:
```dart
return Response.ok(
  controller.stream,
  headers: {
    'Content-Type': 'text/event-stream',
    'Cache-Control': 'no-cache',
    'Connection': 'keep-alive',
    'X-Accel-Buffering': 'no',
  },
);
```

Cleanup on client disconnect: all EventBus subscriptions are cancelled in `controller.onCancel`.

Source: `packages/dartclaw_runtime/lib/src/api/task_sse_routes.dart`

### Chat SSE (Per-Turn Streaming)

`sseStreamResponse()` creates a per-turn SSE stream for chat UI. Events: `delta` (text chunks), tool call status, turn completion. Source: `packages/dartclaw_runtime/lib/src/api/stream_handler.dart`

### SseBroadcast

Global broadcast channel for system-level SSE events (budget warnings, rate limit warnings, loop detection, emergency stop). Separate from per-turn and task SSE. Manages client list with automatic stale-connection cleanup. Source: `packages/dartclaw_runtime/lib/src/api/sse_broadcast.dart`

### TaskProgressTracker

Throttled progress tracker (max 1 emit/second/task). Subscribes to `TaskEventCreatedEvent`, accumulates token usage and current tool activity, emits `TaskProgressSnapshot` with: `progress` (0--100% against token budget), `currentActivity` (human-readable tool description), `tokensUsed`, `tokenBudget`, `isComplete`. Supports `seedFromEvents()` for mid-task page loads.

Source: `packages/dartclaw_runtime/lib/src/task/task_progress_tracker.dart`

### RunnerObserver

Per-runner cumulative metrics remain attached to current reusable runners: `tokensConsumed`, `turnsCompleted`,
`errorCount`, `cacheReadTokens`, `cacheWriteTokens`, `totalTurnDurationMs`, exact `totalToolCalls`, and exact
`failedToolCalls`.
`TurnRunner` emits each terminal outcome once through `ExecutionCoordinator`, which keys the outcome to the active runner
ID before `RunnerObserver` accumulates it. The same coordinator event stream is authoritative for busy/free/current
task/current session state. Disposal is delivered before the coordinator and observer remove the runner from their
current registries, preventing stale runner accumulation without retaining historical runner objects.

### Execution Capacity and Lease Observability

`ExecutionCoordinator.snapshot` reports:

- `primaryActive` for the fixed serialized primary-interactive lane;
- per provider: `configured`, `effective`, `active`, `queued`, `cached`, and `quarantined` worker counts;
- aggregate configured, active, available, queued, cached, and quarantined counts.

`available = effective - active`. Cached harness count is diagnostic only and never increases capacity. Quarantined slots reduce `effective` until recovery/restart. Workflow steps emit acquire/release transitions with their request, provider, and runner ID, so the same API/SSE state remains truthful.

Coordinator events cover `acquired`, `released`, `disposed`, `quarantined`, `runnerCreated`, and `turnSettled`. Cache state is visible in lease snapshots; it does not need a separate lifecycle event.

An observed worker teardown publishes exactly **one** terminal event carrying that worker's runner ID: `disposed` when
teardown and root-process termination are confirmed, `quarantined` when they are not — and wherever a slot can still be
withheld it is withheld first, so the crash is never reported ahead of the degradation it explains
([ADR-058](../adrs/058-report-quarantined-workers-truthfully.md)). Coordinator shutdown is the one place it cannot: the
gates are already closed and no replacement can be admitted at all, so that tombstone is reported without a matching
quarantined slot rather than being reported as a clean teardown.
`RunnerObserver` maps `quarantined` to `crashed`, clears the runner's task and session IDs, and retains that tombstone
in `/api/runners` until restart; runner bookkeeping is dropped immediately after the terminal event, so the
lease-release notification that follows carries no runner ID and cannot overwrite the outcome. A teardown with no
observed runner ID (a pre-registration factory failure) stays capacity-only — no identity is invented.
Surfaces must not emit independent lifecycle or outcome transitions; doing so would race with lease release or double-count
turn metrics.

The cache is intentionally opportunistic and unconfigured. Observability may report cache outcomes for diagnosis, but there are no cache target, TTL, hit-rate policy, or prewarm settings. Container health/lifetime is reported separately from the harness cache: only host harnesses are cacheable, and each container is bound to the single authority that owns it.

Source: `packages/dartclaw_runtime/lib/src/task/runner_observer.dart`


## 8. Context Monitoring

### ContextMonitor

Tracks context token usage and manages pre-compaction flush timing. Shared across all coordinator-managed `TurnRunner` instances. Implements `Reconfigurable` -- watches `context.*` config keys.

Key behaviors:

1. **Context tracking**: `update()` receives `contextWindow` and `contextTokens` from turn results
2. **Warning threshold**: `checkThreshold()` returns `true` exactly once per session when usage exceeds `warningThreshold%` (default: 80%)
3. **Pre-compaction flush**: `shouldFlushForCompactionSignal(compactionSignalAvailable:)` returns `true` when tokens exceed `contextWindow - reserveTokens` and no flush is pending. Suppressed when the `compactionSignalAvailable` argument is `true` (the harness delivers a deterministic signal, passed from `AgentHarness.supportsPreCompactHook`)
4. **Compaction cycle dedup**: `shouldSkipFlush()` + `markFlushed()` prevent redundant flushes within the same compaction cycle or with identical content (SHA-256 hash)

Source: `packages/dartclaw_runtime/lib/src/context/context_monitor.dart`

### ResultTrimmer

Soft-trims oversized tool results: head + `...[trimmed N bytes]...` + tail, each slice up to 2KB and smaller when the cap cannot fit that much, so the returned text fits `maxResultBytes`. Default cap: 50KB. Reconfigurable via `context.maxResultBytes`. Applied by `McpProtocolHandler` to the successful text result of every `tools/call` it dispatches -- every tool registered on the handler, including `OutboundMcpToolAdapter` relays of a configured MCP server, and no other surface. A tool's error result passes through as produced. The marker is the only record that bytes were dropped; the untrimmed result is not retained.

Source: `packages/dartclaw_runtime/lib/src/context/result_trimmer.dart`

### ContextConfig

| Field | Default | Description |
|-------|---------|-------------|
| `reserveTokens` | `20000` | Token reserve before pre-compaction flush |
| `maxResultBytes` | 50KB | ResultTrimmer byte cap |
| `warningThreshold` | `80` | Context warning percentage threshold (50--99) |
| `compactInstructions` | (built-in) | Custom compact instructions |
| `identifierPreservation` | `strict` | Mode: `strict`/`off`/`custom` |

Source: `packages/dartclaw_kernel/lib/src/context_config.dart`


## 9. Compaction Observability (0.16)

Context compaction is a lifecycle event where the agent provider reduces its context window. DartClaw tracks both sides of this transition.

### Compaction Events

```
┌─────────────────────────────────────────────────┐
│  Agent Harness (Claude Code / Codex)            │
│  PreCompact hook callback                       │
└───────────────────────┬─────────────────────────┘
                        │
                        ▼
            ┌───────────────────────┐
            │ CompactionStartingEvent│
            │  sessionId, trigger    │
            └───────────┬───────────┘
                        │
                        ▼
            ┌───────────────────────┐
            │ Pre-compaction flush   │
            │ (ContextMonitor)       │
            │ Persist pending state  │
            └───────────┬───────────┘
                        │
                        ▼
            ┌───────────────────────┐
            │ compact_boundary msg   │
            │ from claude binary     │
            └───────────┬───────────┘
                        │
                        ▼
            ┌────────────────────────┐
            │ CompactionCompletedEvent│
            │  sessionId, trigger,   │
            │  preTokens, summary    │
            └───────────┬────────────┘
                        │
              ┌─────────┴─────────┐
              ▼                   ▼
     ┌────────────────┐  ┌────────────────┐
     │ AlertRouter     │  │ TaskEvent      │
     │ (compaction     │  │ kind=Compaction│
     │  alert)         │  │ (if task       │
     └────────────────┘  │  active)       │
                         └────────────────┘
```

**CompactionStartingEvent**: Fired from the `PreCompact` hook callback before compaction occurs. Downstream systems use this to flush pending state.

**CompactionCompletedEvent**: Fired on receipt of the `compact_boundary` system message. Includes `preTokens` (token count before compaction, if available from wire format). Alert classification: `compaction` / `info` severity.

**Identifier preservation**: Compact instructions include identifier preservation text (configurable via `identifierPreservation` setting) to ensure UUIDs, session keys, task IDs, file paths, and URLs survive compaction verbatim.

**Provider-specific handling**: Each harness's `supportsPreCompactHook` capability is threaded into `ContextMonitor.shouldFlushForCompactionSignal()` as the `compactionSignalAvailable` argument, adapting behavior per harness -- providers with deterministic compaction signals skip the heuristic flush, while others rely on the token-based threshold.

Source: `packages/dartclaw_core/lib/src/events/compaction_events.dart`


## 10. Self-Improvement & Learning

### SelfImprovementService

Manages the separate `errors.md` runtime log and canonical learning entries. Each retains at most `maxEntries` (default: 50) writes, evicting the earliest retained insertion rather than rewriting capture timestamps. Error writes use the local serialized queue; canonical learnings commit through the shared memory-corpus authority and remain available through `memory_search` and `memory_read`.

**errors.md**: Auto-populated on turn failures, guard blocks, and crashes. Format:
```markdown
## [2026-04-11T10:30:00.000Z] GuardBlock
- Session: agent:main:chat:default
- Context: BashTool attempted to access /etc/shadow
- Resolution: Pattern added to blocked paths
```

**Canonical learnings**: Written via `memory_observe` with `role='learning'`, bounded to the retained set, and included in the corpus transaction and derived-index lifecycle.

Writes use the workspace authority's atomic transaction protocol.

Source: `packages/dartclaw_runtime/lib/src/behavior/self_improvement_service.dart`

### BehaviorFileService

Manages behavior prompt files: `SOUL.md` (identity), `AGENTS.md`/`CLAUDE.md` (harness-specific instructions), `USER.md` (preferences), `TOOLS.md` (tool guidance), and `HEARTBEAT.md` (periodic check-in). It composes each scope's prompt with compact instructions and identifier preservation; primary turns additionally receive the fresh bounded canonical memory index projection.

Source: `packages/dartclaw_runtime/lib/src/behavior/behavior_file_service.dart`


## 11. Heartbeat & Scheduling

### Heartbeat job

Periodic agent check-ins via `HEARTBEAT.md`, registered as the built-in `heartbeat` `ScheduledJob`. Each fire:
1. Reads `HEARTBEAT.md` from workspace
2. If present and non-empty, dispatches content as a turn in a session unique to that cycle (`SessionKey.cronSession(jobId: 'heartbeat:<timestamp>')`, so the stored key URI-encodes the inner separator) through provider worker capacity, never the primary-interactive lane. Turns carry the scheduler's `cron` source and `cron:heartbeat` agent name
3. If missing, empty, or undecodable, ends the fire quietly -- no turn, no session, no failure event, no retry attempt, and the next fire stays on schedule
4. Completes the dispatched checklist without a memory-curation turn; curation runs only as its own opt-in `memory-curation` job

The job is always registered and starts paused when `scheduling.heartbeat.enabled` is false, so the live toggle takes effect from either boot state. `scheduling.heartbeat.interval_minutes` requires a restart: a job's schedule is fixed at registration.

Workspace git sync is a separate built-in job (`git-sync`) on `workspace.git_sync.interval_minutes`; it no longer rides the heartbeat cycle, so a disabled heartbeat leaves workspace versioning running.

Source: `packages/dartclaw_runtime/lib/src/behavior/heartbeat_job.dart`, `packages/dartclaw_runtime/lib/src/workspace/workspace_git_sync_job.dart`

### ScheduleService

Manages cron, interval, and one-time job execution. Each job runs in an isolated session (`SessionKey.cronSession`). Single-shot `Timer` + reschedule pattern handles variable intervals. Features: overlap prevention, retry logic (`retryAttempts` + `retryDelaySeconds`), per-job pause/resume, delivery modes (none/channel/webhook/SSE), and an on-demand prompt-job seam that reuses execution policy without changing timers or pause state. Fires `ScheduledJobFailedEvent` after all retries exhausted. Reconfigurable (job list changes require restart).

A `ScheduledJob` may compose its prompt when it fires instead of carrying a static one, and hand back a release for whatever per-run authority the composition established; `ScheduleService` runs that release once the turn has an outcome, whatever the outcome. The opt-in `memory-curation` job is the one consumer: each fire composes a bounded corpus snapshot into its prompt and registers that snapshot's entry IDs as the run's apply scope. `MemoryApplyService.apply` then refuses, as a whole set, any change set from that session naming an entry outside the scope, so a run can only change entries it was shown. Curation keeps no durable run record: it is observable through the same scheduling surface, delivery, and logs as any other prompt job. Heartbeat, corpus size, scheduled-job completion, and apply completion never dispatch it.

Cron, system, and on-demand scheduled turns acquire provider worker leases. They never compete with user/channel turns for the fixed primary-interactive lane. Workflow-owned steps are reported through worker leases.

Source: `packages/dartclaw_runtime/lib/src/scheduling/schedule_service.dart`

### ScheduledTaskRunner

Bridges `ScheduledTaskDefinition` into callback-based `ScheduledJob` instances. Dedup: checks for non-terminal tasks with matching `scheduleId` before creating new tasks via `TaskService`.

Source: `packages/dartclaw_runtime/lib/src/scheduling/scheduled_task_runner.dart`

### SchedulingConfig

| Field | Default | Description |
|-------|---------|-------------|
| `jobs` | `[]` | Prompt-based scheduled job definitions |
| `taskDefinitions` | `[]` | Task-based schedule definitions |
| `heartbeatEnabled` | `true` | Whether the built-in `heartbeat` job runs (live-togglable; the job is registered either way) |
| `heartbeatIntervalMinutes` | `30` | Minutes between heartbeat fires (restart required) |

Source: `packages/dartclaw_kernel/lib/src/scheduling_config.dart`


## 12. Governance Observability

Governance controls (rate limiting, budgets, loop detection, emergency controls) each produce observable side effects for operator awareness.

### TurnGovernanceEnforcer

Central coordination point for all pre-turn governance checks. Runs before each turn reservation.

When governance admits the request, execution allocation passes to `ExecutionCoordinator`. The coordinator is the only post-governance authority; its request and runner identity correlate capacity, runner activity, and quarantine observability. Provider-specific adapters may add protocol telemetry, but routing and capacity views do not branch on provider identity.

```
Inbound turn request
        │
        ▼
┌───────────────────────────────────┐
│     TurnGovernanceEnforcer        │
│                                   │
│  1. checkBudget(sessionId)        │──► BudgetEnforcer.check()
│     → BudgetExhaustedException    │    → BudgetWarningEvent (SSE)
│                                   │    → Channel notification
│  2. awaitRateLimitWindow()        │──► SlidingWindowRateLimiter
│     → rate_limit_warning (SSE)    │    → Backpressure (1s delay loop)
│                                   │
│  3. checkLoopPreTurn(sessionId)   │──► LoopDetector
│     → LoopDetectedEvent (EventBus)│    → loop_detected (SSE)
│     → LoopDetectedException       │    → Channel notification
│                                   │
│  4. recordToolCall(...)           │──► Per-tool fingerprint detection
│  5. recordTokensAndCheckVelocity  │──► Token velocity monitoring
└───────────────────────────────────┘
```

### Budget Enforcement Observability

`BudgetEnforcer` is the daily scope over the shared `BudgetEngine`. It reports
an outcome plus `warningIsNew`; `TurnGovernanceEnforcer` maps that onto the
configured action:

| Threshold | Outcome | Observable Effect |
|-----------|---------|-------------------|
| < 80% | `under` | None |
| >= 80% (first time today) | `warning` (`warningIsNew`) | `budget_warning` SSE broadcast, channel notification, KV marker |
| >= 80% (repeat) | `warning` | None (warning already posted) |
| >= 100% (warn mode, first time today) | `exceeded` (`warningIsNew`) | Warning + allow through |
| >= 100% (block mode, first time today) | `exceeded` (`warningIsNew`) | Warning with `action: block`, then `BudgetExhaustedException` -- turn rejected |
| >= 100% (block mode, repeat) | `exceeded` | `BudgetExhaustedException` -- turn rejected, no repeat warning |

Reaching 100% consumes the day's single warning, so a turn that lands straight
at the limit still notifies the operator once.

Budget status exposed via `/status` endpoint for dashboards.

Source: `packages/dartclaw_runtime/lib/src/governance/budget_engine.dart`,
`packages/dartclaw_runtime/lib/src/governance/budget_enforcer.dart`

### Rate Limiter Visibility

Global turn rate limiter uses `SlidingWindowRateLimiter`. When usage reaches 80%, a `rate_limit_warning` SSE event is broadcast (once until usage drops below 60%). Turns that exceed the limit are deferred with 1-second backpressure delays.

### Loop Detection Alerts

`LoopDetector` detects three loop patterns:

1. **Turn depth**: excessive consecutive agent turns without human input
2. **Token velocity**: abnormally high token consumption rate
3. **Tool fingerprinting**: repeated identical tool calls

Each detection fires:
- `LoopDetectedEvent` on EventBus
- `loop_detected` SSE broadcast with mechanism, message, and action
- Channel notification (if `loopDetectionNotifier` is wired)

Configurable action: `warn` (log + notify) or `abort` (`LoopDetectedException`).

### Emergency Controls

| Command | Handler | Observable Effect |
|---------|---------|-------------------|
| `/stop` | `EmergencyStopHandler` | Cancels all active turns, transitions running/queued tasks to cancelled, fires `EmergencyStopEvent`, broadcasts SSE |
| `/pause` | `PauseController` | Sets paused state, queues inbound messages (up to `maxQueueSize`=200) |
| `/resume` | `PauseController` | Drains queued messages as structured per-sender concatenation, resumes processing |

All emergency controls are admin-only. `PauseController` state is in-memory -- resets automatically on server restart.

Source: `packages/dartclaw_runtime/lib/src/emergency/emergency_stop_handler.dart`
Source: `packages/dartclaw_runtime/lib/src/governance/pause_controller.dart`


## 13. Observability Data Flow Summary

```
Agent Turn Execution
  ├─► ExecutionCoordinator leases ──► capacity/runner SSE + health snapshot
  ├─► EventBus ──► AlertRouter ──► Channel delivery (WhatsApp/Signal/GChat)
  │             └─► SSE Routes ──► Web UI
  ├─► UsageTracker ──► usage.jsonl + KV daily aggregate
  ├─► GuardAuditLogger ──► audit-YYYY-MM-DD.ndjson
  ├─► LogService ──► stderr + optional file sink
  └─► ContextMonitor ──► Compaction lifecycle events
```

### Package Ownership

- **`dartclaw_core`**: `DartclawEvent` subtypes, `EventBus`, compaction events, `TurnTrace`, `TurnTraceSummary`, `ToolCallRecord`
- **`dartclaw_kernel`**: `GuardAuditLogger`, `AuditEntry`, `AlertsConfig`, `LoggingConfig`, `UsageConfig`, `ContextConfig`, `SchedulingConfig`
- **`dartclaw_core`**: `TurnTraceService` (SQLite persistence)
- **`dartclaw_google_chat`**: `PubSubHealthReporter`
- **`dartclaw_runtime`**: All other observability components (alerts, audit bridging, health, usage, logging, SSE, context, governance, scheduling)

Execution allocation sources: `packages/dartclaw_runtime/lib/src/execution_coordinator.dart` and `worker_capacity_gate.dart`.


---

## Cross-References

- [System Architecture](system-architecture.md) -- component map, package DAG, deployment model
- [Security Architecture](security-architecture.md) -- guard pipeline, guard audit, governance controls, credential security
- [Data Model & Persistence](data-model.md) -- audit files, usage files, turn traces, thread binding persistence, governance state
- [Task & Execution Architecture](task-execution-architecture.md) -- task events, turn lifecycle, runner observer, progress tracking
- [Control Protocol & Harness](control-protocol.md) -- JSONL protocol, stream events, compaction hooks
- [Workflow Architecture](workflow-architecture.md) -- workflow SSE events, workflow budget warnings
- [Channel Messaging Architecture](channel-messaging-architecture.md) -- channel-routed alerts, governance enforcement
