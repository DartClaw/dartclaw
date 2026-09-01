All DartClaw packages use lock-step versioning. This changelog tracks changes relevant to `dartclaw_runtime` (named `dartclaw_server` before 0.25).

## Unreleased

### Fixed
- Workspace git sync runs on heartbeat timer cycles without requiring `HEARTBEAT.md` content and supplements cloned repositories with missing default ignore entries
- The default SOUL scaffold defers to active onboarding's direct-or-draft mutation policy
- Signal pairing preserves indeterminate registration state instead of starting a competing link flow
- Responsive memory, channel, composer-palette, and pairing surfaces contain long values without page-wide overflow

### Added
- `WorkflowGitPortProcess`, the production adapter for workflow-layer git operations using DartClaw's sanitized git subprocess path
- Refined Web UI canon adoption with reusable form, tab, and dialog primitives plus locally served browser dependencies
- Persistent New Chat and System navigation with authoritative session turn-status controls

### Changed
- Session draft eligibility is serialized with rename/send mutations, and the Running sidebar now lists only executing tasks
- `TaskExecutor` collapses the 14 workflow-context branch points onto a single `_isWorkflowOrchestrated(Task)` helper that reads hydrated `task.workflowStepExecution`; removes the `_skipAutoAcceptForWorkflowTask` and `_isCodingReviewStep` special cases
- `TaskService.create` now creates an `AgentExecution` row atomically alongside the Task and links it via `agent_execution_id`; non-workflow tasks no longer persist `provider` / `model` / `sessionId` / `maxTokens` on the Task row or in `configJson`
- Task REST/CLI/SSE consumers now treat execution metadata as nested `agentExecution` / `workflowStepExecution` payloads, while `task_status_changed` remains stable and `/api/agent-executions/events` exposes execution-lifecycle SSE separately
- `TaskExecutor` one-shot workflow path fails fast (`StateError`) when a `WorkflowStepExecutionRepository` is not wired, instead of silently writing workflow-private `_workflowProviderSessionId` / token-breakdown / `_workflowStructuredOutputPayload` keys back into `Task.configJson` — the WSE repository is now the sole carrier for those runtime signals
- `MergeExecutor.merge` now enforces typed pre-merge invariants for clean tracked state, untracked/stash overlap, and target-SHA drift before mutating the worktree
- Workflow task execution now preflights mapped story `spec_path` inputs after worktree/materialization and before starting the workflow runner

## 0.9.0

### Added
- MIT LICENSE, pubspec metadata, and a package-level changelog
- Shelf server, HTMX web UI, MCP endpoints, and runtime composition for DartClaw
- Task execution, agent observability, scheduling, audit, and dashboard surfaces moved into the server package
- Web and API support for Google Chat, Signal pairing, sessions, memory, and task workflows
- `SlashCommandHandler` — server-side dispatcher for Google Chat slash commands, wired into `GoogleChatWebhookHandler`
- `TaskNotificationSubscriber` upgraded to deliver Cards v2 notifications for Google Chat channels
