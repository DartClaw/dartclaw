All DartClaw packages use lock-step versioning. This changelog tracks changes relevant to `dartclaw_core`.

## Unreleased

### Added
- `AgentExecution` and `AgentExecutionRepository` as task-agnostic execution primitives
- `AgentExecutionStatusChangedEvent` for future execution lifecycle wiring
- `Task.agentExecution` / `Task.workflowStepExecution` hydration with lazy accessors that resolve runtime fields through the shared execution tables

### Changed
- `Task.toJson()` / `Task.fromJson()` now use nested `agentExecution` and `workflowStepExecution` objects instead of re-emitting provider/session/budget/workflow fields at the top level
- `Task.toJson()` emits `workflowStepExecution` only when a real hydrated `WorkflowStepExecution` is present. The legacy synthesis that fabricated a stand-in nested object from bare `workflowRunId`/`stepIndex` flat fields (producing `stepId: 'legacy-step-<n>'` and `agentExecutionId: 'legacy-ae:<id>'` placeholders) has been removed — the public task payload must reflect actual persistence state, not back-compat reconstruction

## 0.9.0

### Added
- MIT LICENSE, pubspec metadata, and a package-level changelog
- `ChannelConfigProvider` and shared channel primitives for the decomposed workspace
- Sqlite-free harness, bridge, configuration, task, and event abstractions

### Changed
- Extracted the security framework to `dartclaw_security`
- Extracted WhatsApp, Signal, and Google Chat integrations to dedicated channel packages
- Kept the core package focused on reusable SDK surfaces and file-based services
