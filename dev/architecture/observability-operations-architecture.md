# Observability & Operations Architecture

Comprehensive reference for DartClaw's observability stack: alert routing, health monitoring, audit logging, usage tracking, structured logging, real-time streaming, context intelligence, and governance visibility.

**Current through**: 0.20

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
| **SSE Streaming** | Real-time task/agent/workflow state to web UI | Web UI, live dashboards |
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
│ EventBus ├────────────────────►│ AlertRouter  ├───────────►│AlertClassifier│
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

### AlertClassifier

Pure function that maps `DartclawEvent` subtypes to alert type identifiers and severity levels:

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
| `AdvisorInsightEvent` (status `stuck`) | `advisor_insight` | warning |
| `AdvisorInsightEvent` (status `concerning`) | `advisor_insight` | critical |

Non-alertable events return `null` and are silently dropped.

**Non-channel filter**: Task failure alerts for tasks originating from DM or group channel sessions are suppressed -- those users are already notified via `TaskNotificationSubscriber`. Tasks with web/cron/API origin always generate alerts. On malformed `SessionKey`, the filter fails open (alert delivered rather than silently dropped).

Source: `packages/dartclaw_server/lib/src/alerts/alert_classifier.dart`

### AlertRouter

Subscribes to `EventBus.on<DartclawEvent>()` and orchestrates the full pipeline: classify, resolve targets, check throttle, format, deliver. Implements `Reconfigurable` -- watches `alerts.*` config keys and applies changes to the next event without restarting the subscription.

Target resolution via `AlertsConfig.routes`:
- Empty routes map: all events go to all targets
- `routes['guard_block'] = ['*']`: this type goes to all targets
- `routes['compaction'] = ['0', '2']`: this type goes to target indices 0 and 2
- No entry for a type: event is not routed (silently dropped)

Source: `packages/dartclaw_server/lib/src/alerts/alert_router.dart`

### AlertFormatter

Stateless formatter producing channel-appropriate `ChannelResponse` objects. Google Chat gets Cards v2 with severity-colored headers; all other channels get plain text (`[SEVERITY] Title: body`). Also handles burst summary formatting.

Source: `packages/dartclaw_server/lib/src/alerts/alert_formatter.dart`

### AlertThrottle

Per-key cooldown tracker. Key: `eventType:channelType:recipient`. First event delivers immediately; subsequent events within cooldown are suppressed. When cooldown expires, if `suppressedCount >= burstThreshold`, a summary is delivered. Each target+type combination is throttled independently.

Source: `packages/dartclaw_server/lib/src/alerts/alert_throttle.dart`

### AlertsConfig

| Field | Default | Description |
|-------|---------|-------------|
| `enabled` | `false` | Master switch for alert routing |
| `cooldownSeconds` | `300` | Min seconds between repeated alerts per type |
| `burstThreshold` | `5` | Events before burst-summary mode activates |
| `targets` | `[]` | Channel + recipient pairs (`AlertTarget`) |
| `routes` | `{}` | Event type to target index mapping |

Source: `packages/dartclaw_config/lib/src/alerts_config.dart`


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

Source: `packages/dartclaw_server/lib/src/health/health_service.dart`

### Health Endpoint

`GET /health` returns JSON via shelf `Handler`. Used by load balancers, monitoring systems, and the web UI health dashboard (`health_page.dart` + `health_dashboard.html`).

Source: `packages/dartclaw_server/lib/src/health/health_route.dart`

### ContainerHealthMonitor

Periodic check (default: 10s) for all container profiles. Fires `ContainerCrashedEvent` on healthy-to-unhealthy transitions (triggers alert routing) and `ContainerStartedEvent` on recovery. Tasks in a crashed container fail naturally via subprocess termination; this monitor provides structured event notification.

Source: `packages/dartclaw_server/lib/src/container/container_health_monitor.dart`

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
│  (dartclaw_server)       │
│  Bridges EventBus →      │
│  GuardAuditLogger        │
└──────────┬───────────────┘
           ▼
┌──────────────────────────┐     ┌────────────────────────────┐
│  GuardAuditLogger        │────►│  audit-YYYY-MM-DD.ndjson   │
│  (dartclaw_security)     │     │  Date-partitioned files    │
│  Stdout + file sink      │     │  in dataDir                │
└──────────────────────────┘     └────────────────────────────┘
                                          │
                                          ▼
                                 ┌────────────────────────────┐
                                 │  AuditLogReader            │
                                 │  (dartclaw_server)         │
                                 │  Paginated read + filter   │
                                 └────────────┬───────────────┘
                                              ▼
                                 ┌────────────────────────────┐
                                 │  Web UI Audit Table        │
                                 │  (audit_table.dart)        │
                                 └────────────────────────────┘
```

### GuardAuditLogger

Structured audit logger in `dartclaw_security`. Dual output:

1. **Stdout logging** (always): log level varies by verdict -- INFO for pass, WARNING for warn, SEVERE for block
2. **File sink** (when `dataDir` is set): NDJSON entries appended to date-partitioned files

File operations are fire-and-forget via `unawaited` to avoid affecting guard verdict latency. Write serialization is enforced via a `_pendingWrite` future chain.

**AuditEntry fields**: `timestamp`, `guard`, `hook`, `verdict`, `reason`, `rawProviderToolName`, `sessionId`, `channel`, `peerId`.

**Date partitioning**: Files are named `audit-YYYY-MM-DD.ndjson`. Legacy `audit.ndjson` files are auto-migrated on first write. Old partitions are cleaned via `cleanOldFiles(maxRetentionDays)`.

**PermissionDenied logging**: Claude Code's own permission layer events are also captured with `guard: 'PermissionDenied'` and `verdict: 'denied'`.

Source: `packages/dartclaw_security/lib/src/guard_audit.dart`

### GuardAuditSubscriber

Bridges `GuardBlockEvent` and `ToolPermissionDeniedEvent` from the core EventBus into the `GuardAuditLogger`. Runs in `dartclaw_server` to avoid coupling the security package to the event bus.

Source: `packages/dartclaw_server/lib/src/audit/guard_audit_subscriber.dart`

### AuditLogReader

Reads and parses audit NDJSON with filtering and pagination. Reads the full file on each call (no caching) -- acceptable at 10K entries per PRD note. Returns newest entries first.

Filters (AND-combined):
- `verdictFilter`: exact match on verdict string (`pass`, `warn`, `block`)
- `guardFilter`: case-insensitive substring match on guard name

Source: `packages/dartclaw_server/lib/src/audit/audit_log_reader.dart`


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

**UsageEvent fields**: `timestamp`, `sessionId`, `agentName` (values: `main`, `search`, `heartbeat`, `cron:<jobId>`), `model`, `inputTokens`, `outputTokens`, `durationMs`.

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

Source: `packages/dartclaw_server/lib/src/observability/usage_tracker.dart`

### Token Accounting (0.16.4)

Workflow-owned one-shot CLI turns now treat **observability** and **persistence** as separate concerns:

- Codex CLI `turn.completed` usage is **cumulative per thread**, not a per-turn delta. A resumed probe on 2026-04-22 moved from `input_tokens=27401 / cached_input_tokens=20992 / output_tokens=19` to `input_tokens=54832 / cached_input_tokens=48256 / output_tokens=25`, which confirms overwrite-not-add semantics for the live usage payload.
- The live Codex CLI currently emits `cached_input_tokens`; older internal adapters and persisted KV records use the normalized name `cache_read_tokens`. Workflow-side parsing must accept both names and normalize onto the unified schema.
- Persisted task/session usage remains cumulative and uses the unified keys `input_tokens`, `cache_read_tokens`, `cache_write_tokens`, `output_tokens`, `total_tokens`, `effective_tokens`, `estimated_cost_usd`, `turn_count`, and `provider`.
- For Codex, fresh input is derived as `input_tokens - cache_read_tokens`; for Claude, the provider already reports fresh input directly. This keeps budget checks and per-turn attribution on the same semantic footing across harnesses.
- Legacy `session_cost:*` KV entries carrying the old workflow-only schema are dropped once at boot. Readers null-coalesce missing keys so the first post-upgrade render remains safe even before a fresh turn lands.
- Long-running workflow-owned one-shot provider runs emit `WorkflowCliTurnProgressEvent`, so operators can observe a 40-minute `implement` step without waiting for process exit. Codex emits on `turn.completed` based on **delta from the previous cumulative snapshot**; claude emits once per completed assistant message using latest input/cache tokens and summed output tokens.

Budget semantics are intentionally layered:

- `governance.budget.daily_tokens` is an instance-wide daily guardrail.
- `tasks.budget.default_max_tokens` is a per-task cap resolved after explicit task and goal budgets. This is the control that stops a single runaway `implement` task before it can consume the whole daily allowance.
- The `workflows` testing profile (in `dev/testing/profiles/workflows/`) sets `tasks.budget.default_max_tokens: 5000000` so workflow E2E runs fail early and visibly when a single step goes pathological.

### UsageConfig

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `budgetWarningTokens` | `int?` | `null` | Daily token threshold for warning (null = disabled) |
| `maxFileSizeBytes` | `int` | 10MB | JSONL file rotation threshold |

Source: `packages/dartclaw_config/lib/src/usage_config.dart`

### Turn Traces

Each agent turn produces a `TurnTrace` record: `id`, `sessionId`, `taskId`, `runnerId`, `model`, `provider`, `startedAt`/`endedAt`, `inputTokens`/`outputTokens`, `cacheReadTokens`/`cacheWriteTokens`, `isError`/`errorType`, and `toolCalls` (`List<ToolCallRecord>`). Computed properties: `totalTokens`, `durationMs`.

Source: `packages/dartclaw_core/lib/src/turn/turn_trace.dart`

### TurnTraceService

SQLite-backed persistence in `turns` table (co-located in tasks.db). Indexed on `session_id`, `task_id`, `started_at`, `model`, `provider`. Query API filters by task/session/runner/model/provider/time range with pagination (max 500). Returns traces + aggregate `TurnTraceSummary` (total tokens, duration, tool call count). Exposed via `GET /api/traces`, with single-trace detail via `GET /api/traces/<id>`. The connected CLI `traces list` / `traces show` commands are thin clients over the same query surface.

Source: `packages/dartclaw_storage/lib/src/storage/turn_trace_service.dart`


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

Source: `packages/dartclaw_server/lib/src/logging/log_service.dart`

### LogFormatter

Two implementations:

- **HumanFormatter**: `LEVEL: timestamp [session=X turn=Y] Logger: message`. ANSI color-coded by level (red/yellow/cyan/dim) with per-logger name coloring from a 7-color palette
- **JsonFormatter**: NDJSON with `level`, `time`, `logger`, `message`, optional `sessionId`, `turnId`, `error`, `stackTrace`

Both apply `LogRedactor` (delegates to `MessageRedactor` from `dartclaw_core`) before output.

Sources: `packages/dartclaw_server/lib/src/logging/log_formatter.dart`, `log_redactor.dart`

### LogContext

Zone-based log correlation. Set session/turn IDs once via `runWith()`; read anywhere downstream via static getters. Zone values are immutable per zone.

Source: `packages/dartclaw_server/lib/src/logging/log_context.dart`

### LoggingConfig

| Field | Default | Description |
|-------|---------|-------------|
| `format` | `human` | Output format: `human` or `json` |
| `file` | `null` | Optional log file path |
| `level` | `INFO` | Minimum log level |
| `redactPatterns` | `[]` | Additional redaction patterns |

Source: `packages/dartclaw_config/lib/src/logging_config.dart`


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
     │  AgentStateChangedEvent               │
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
| `connected` | Client connects | Review count, active tasks, agent pool status, projects, active workflows |
| `task_status_changed` | `TaskStatusChangedEvent` | Task ID, old/new status, trigger, review count, active tasks |
| `agent_state` | `AgentStateChangedEvent` | Runner ID, state, current task |
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

Source: `packages/dartclaw_server/lib/src/api/task_sse_routes.dart`

### Chat SSE (Per-Turn Streaming)

`sseStreamResponse()` creates a per-turn SSE stream for chat UI. Events: `delta` (text chunks), tool call status, turn completion. Source: `packages/dartclaw_server/lib/src/api/stream_handler.dart`

### SseBroadcast

Global broadcast channel for system-level SSE events (budget warnings, rate limit warnings, loop detection, emergency stop). Separate from per-turn and task SSE. Manages client list with automatic stale-connection cleanup. Source: `packages/dartclaw_server/lib/src/api/sse_broadcast.dart`

### TaskProgressTracker

Throttled progress tracker (max 1 emit/second/task). Subscribes to `TaskEventCreatedEvent`, accumulates token usage and current tool activity, emits `TaskProgressSnapshot` with: `progress` (0--100% against token budget), `currentActivity` (human-readable tool description), `tokensUsed`, `tokenBudget`, `isComplete`. Supports `seedFromEvents()` for mid-task page loads.

Source: `packages/dartclaw_server/lib/src/task/task_progress_tracker.dart`

### AgentObserver

Per-runner runtime metrics for all runners in a `HarnessPool`. Callback-based: `markBusy`/`markIdle` on acquire/release, `recordTurn` after each turn. Tracks: `tokensConsumed`, `turnsCompleted`, `errorCount`, `cacheReadTokens`, `cacheWriteTokens`, `totalTurnDurationMs`, `totalToolCalls`, `failedToolCalls`. State changes fire `AgentStateChangedEvent` for SSE propagation.

Source: `packages/dartclaw_server/lib/src/task/agent_observer.dart`


## 8. Context Monitoring

### ContextMonitor

Tracks context token usage and manages pre-compaction flush timing. Shared across all `TurnRunner` instances in the harness pool. Implements `Reconfigurable` -- watches `context.*` config keys.

Key behaviors:

1. **Context tracking**: `update()` receives `contextWindow` and `contextTokens` from turn results
2. **Warning threshold**: `checkThreshold()` returns `true` exactly once per session when usage exceeds `warningThreshold%` (default: 80%)
3. **Pre-compaction flush**: `shouldFlushForCompactionSignal(compactionSignalAvailable:)` returns `true` when tokens exceed `contextWindow - reserveTokens` and no flush is pending. Suppressed when the `compactionSignalAvailable` argument is `true` (the harness delivers a deterministic signal, passed from `AgentHarness.supportsPreCompactHook`)
4. **Compaction cycle dedup**: `shouldSkipFlush()` + `markFlushed()` prevent redundant flushes within the same compaction cycle or with identical content (SHA-256 hash)

Source: `packages/dartclaw_server/lib/src/context/context_monitor.dart`

### ExplorationSummarizer

Type-aware structural summarization for tool output exceeding `thresholdTokens` (default: 25K tokens). Detects JSON/YAML (schema extraction), CSV/TSV (headers + sample rows), and source code (Dart/TypeScript/Python/Go -- class/function signatures). Falls back to `ResultTrimmer` head+tail truncation for unrecognized types.

Source: `packages/dartclaw_server/lib/src/context/exploration_summarizer.dart`

### ResultTrimmer

Soft-trims oversized tool results: head (2KB) + `...[trimmed N bytes]...` + tail (2KB). Default cap: 50KB. Reconfigurable via `context.maxResultBytes`. Full result preserved in NDJSON transcript.

Source: `packages/dartclaw_server/lib/src/context/result_trimmer.dart`

### ContextConfig

| Field | Default | Description |
|-------|---------|-------------|
| `reserveTokens` | `20000` | Token reserve before pre-compaction flush |
| `maxResultBytes` | 50KB | ResultTrimmer byte cap |
| `warningThreshold` | `80` | Context warning percentage threshold (50--99) |
| `explorationSummaryThreshold` | `25000` | Token threshold for structural summarization |
| `compactInstructions` | (built-in) | Custom compact instructions |
| `identifierPreservation` | `strict` | Mode: `strict`/`off`/`custom` |

Source: `packages/dartclaw_config/lib/src/context_config.dart`


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

Manages `errors.md` and `learnings.md` in the workspace directory. Both files are capped at `maxEntries` (default: 50) entries, with oldest entries trimmed on write. Uses a `StreamController`-based write queue for serialized, non-blocking file access.

**errors.md**: Auto-populated on turn failures, guard blocks, and crashes. Format:
```markdown
## [2026-04-11T10:30:00.000Z] GuardBlock
- Session: agent:main:chat:default
- Context: BashTool attempted to access /etc/shadow
- Resolution: Pattern added to blocked paths
```

**learnings.md**: Written via `memory_save` MCP tool with `category='learning'`. Format:
```markdown
- [2026-04-11 10:30] Always check file permissions before atomic rename
```

Atomic writes via temp file + rename pattern.

Source: `packages/dartclaw_server/lib/src/behavior/self_improvement_service.dart`

### BehaviorFileService

Manages the suite of agent behavior prompt files: `SOUL.md` (identity), `AGENTS.md`/`CLAUDE.md` (harness-specific instructions), `USER.md` (preferences), `TOOLS.md` (tool guidance), `MEMORY.md` (persisted memory), `HEARTBEAT.md` (periodic check-in). Composes the full system prompt per scope with compact instructions and identifier preservation.

Source: `packages/dartclaw_server/lib/src/behavior/behavior_file_service.dart`


## 11. Heartbeat & Scheduling

### HeartbeatScheduler

Periodic agent check-ins via `HEARTBEAT.md`. Each cycle:
1. Reads `HEARTBEAT.md` from workspace
2. Dispatches content as a turn in a unique isolated session (`agent:main:heartbeat:<timestamp>`)
3. Optionally triggers `MemoryConsolidator` if `MEMORY.md` exceeds threshold (default: 32KB)
4. Optionally commits workspace changes via `WorkspaceGitSync`

Implements `Reconfigurable` -- watches `scheduling.*` for interval changes. Restarts timer if interval changes while running.

Source: `packages/dartclaw_server/lib/src/behavior/heartbeat_scheduler.dart`

### ScheduleService

Manages cron, interval, and one-time job execution. Each job runs in an isolated session (`SessionKey.cronSession`). Single-shot `Timer` + reschedule pattern handles variable intervals. Features: overlap prevention, retry logic (`retryAttempts` + `retryDelaySeconds`), per-job pause/resume, delivery modes (none/channel/webhook/SSE). Fires `ScheduledJobFailedEvent` after all retries exhausted. Reconfigurable (job list changes require restart).

Source: `packages/dartclaw_server/lib/src/scheduling/schedule_service.dart`

### ScheduledTaskRunner

Bridges `ScheduledTaskDefinition` into callback-based `ScheduledJob` instances. Dedup: checks for non-terminal tasks with matching `scheduleId` before creating new tasks via `TaskService`.

Source: `packages/dartclaw_server/lib/src/scheduling/scheduled_task_runner.dart`

### SchedulingConfig

| Field | Default | Description |
|-------|---------|-------------|
| `jobs` | `[]` | Prompt-based scheduled job definitions |
| `taskDefinitions` | `[]` | Task-based schedule definitions |
| `heartbeatEnabled` | `true` | Whether heartbeat scheduler runs |
| `heartbeatIntervalMinutes` | `30` | Minutes between heartbeat cycles |

Source: `packages/dartclaw_config/lib/src/scheduling_config.dart`


## 12. Governance Observability

Governance controls (rate limiting, budgets, loop detection, emergency controls) each produce observable side effects for operator awareness.

### TurnGovernanceEnforcer

Central coordination point for all pre-turn governance checks. Runs before each turn reservation.

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

`BudgetEnforcer` checks daily token consumption against configured budget:

| Threshold | Decision | Observable Effect |
|-----------|----------|-------------------|
| < 80% | `allow` | None |
| >= 80% (first time today) | `warn` | `budget_warning` SSE broadcast, channel notification, KV marker |
| >= 80% (repeat) | `allow` | None (warning already posted) |
| >= 100% (warn mode) | `warn` / `allow` | Warning + allow through |
| >= 100% (block mode) | `block` | `BudgetExhaustedException` -- turn rejected |

Budget status exposed via `/status` endpoint for dashboards.

Source: `packages/dartclaw_server/lib/src/governance/budget_enforcer.dart`

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

Source: `packages/dartclaw_server/lib/src/emergency/emergency_stop_handler.dart`
Source: `packages/dartclaw_server/lib/src/governance/pause_controller.dart`


## 13. Observability Data Flow Summary

```
Agent Turn Execution
  ├─► EventBus ──► AlertRouter ──► Channel delivery (WhatsApp/Signal/GChat)
  │             └─► SSE Routes ──► Web UI
  ├─► UsageTracker ──► usage.jsonl + KV daily aggregate
  ├─► GuardAuditLogger ──► audit-YYYY-MM-DD.ndjson
  ├─► LogService ──► stderr + optional file sink
  └─► ContextMonitor ──► Compaction lifecycle events
```

### Package Ownership

- **`dartclaw_core`**: `DartclawEvent` subtypes, `EventBus`, compaction events, `TurnTrace`, `TurnTraceSummary`, `ToolCallRecord`
- **`dartclaw_security`**: `GuardAuditLogger`, `AuditEntry`
- **`dartclaw_config`**: `AlertsConfig`, `LoggingConfig`, `UsageConfig`, `ContextConfig`, `SchedulingConfig`
- **`dartclaw_storage`**: `TurnTraceService` (SQLite persistence)
- **`dartclaw_google_chat`**: `PubSubHealthReporter`
- **`dartclaw_server`**: All other observability components (alerts, audit bridging, health, usage, logging, SSE, context, governance, scheduling)


---

## Cross-References

- [System Architecture](system-architecture.md) -- component map, package DAG, deployment model
- [Security Architecture](security-architecture.md) -- guard pipeline, guard audit, governance controls, credential security
- [Data Model & Persistence](data-model.md) -- audit files, usage files, turn traces, thread binding persistence, governance state
- [Task & Execution Architecture](task-execution-architecture.md) -- task events, turn lifecycle, agent observer, progress tracking
- [Control Protocol & Harness](control-protocol.md) -- JSONL protocol, stream events, compaction hooks
- [Workflow Architecture](workflow-architecture.md) -- workflow SSE events, workflow budget warnings
- [Channel Messaging Architecture](channel-messaging-architecture.md) -- channel-routed alerts, governance enforcement
