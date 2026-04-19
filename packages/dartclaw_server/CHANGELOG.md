All DartClaw packages use lock-step versioning. This changelog tracks changes relevant to `dartclaw_server`.

## Unreleased

### Changed
- `TaskExecutor` collapses the 14 workflow-context branch points onto a single `_isWorkflowOrchestrated(Task)` helper that reads hydrated `task.workflowStepExecution`; removes the `_skipAutoAcceptForWorkflowTask` and `_isCodingReviewStep` special cases
- `TaskService.create` now creates an `AgentExecution` row atomically alongside the Task and links it via `agent_execution_id`; non-workflow tasks no longer persist `provider` / `model` / `sessionId` / `maxTokens` on the Task row or in `configJson`
- Task REST/CLI/SSE consumers now treat execution metadata as nested `agentExecution` / `workflowStepExecution` payloads, while `task_status_changed` remains stable and `/api/agent-executions/events` exposes execution-lifecycle SSE separately
- `TaskExecutor` one-shot workflow path fails fast (`StateError`) when a `WorkflowStepExecutionRepository` is not wired, instead of silently writing workflow-private `_workflowProviderSessionId` / token-breakdown / `_workflowStructuredOutputPayload` keys back into `Task.configJson` — the WSE repository is now the sole carrier for those runtime signals

## 0.9.0

### Added
- MIT LICENSE, pubspec metadata, and a package-level changelog
- Shelf server, HTMX web UI, MCP endpoints, and runtime composition for DartClaw
- Task execution, agent observability, scheduling, audit, and dashboard surfaces moved into the server package
- Web and API support for Google Chat, Signal pairing, sessions, memory, and task workflows
- `SlashCommandHandler` — server-side dispatcher for Google Chat slash commands, wired into `GoogleChatWebhookHandler`
- `TaskNotificationSubscriber` upgraded to deliver Cards v2 notifications for Google Chat channels
