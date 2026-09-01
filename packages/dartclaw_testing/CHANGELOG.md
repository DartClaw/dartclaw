All DartClaw packages use lock-step versioning. This changelog tracks changes
relevant to `dartclaw_testing`.

## Unreleased

### Added
- Task/execution test helpers for agent-execution-backed task hydration
- `FakeGoogleJwtVerifier` as the single shared fake for the core-owned verifier port

### Changed
- Production dependencies reduced to `dartclaw_core` and `dartclaw_kernel`, so consuming a shared
  double no longer pulls the Google Chat channel or the workflow engine into a suite's dependency closure
- `FakeGoogleChatRestClient` moved to `package:dartclaw_google_chat/testing.dart`; `FakeGitGateway`,
  `FakeSkillIntrospector` and `FakeProviderAuthPreflight` moved to
  `package:dartclaw_workflow/testing.dart` — a fake of a port owned above `dartclaw_core` now lives with the port's owner
- `InMemoryWorkflowStepExecutionRepository` returns to the shared barrel after its port moved to `dartclaw_kernel`
- `WorkflowGitFixture`, `InMemoryAgentExecutionRepository`, `InMemoryExecutionRepositoryTransactor` and
  `captureRootLogs` moved into their single consuming package's test tree

## 0.9.0

### Added
- Canonical shared test doubles for harness, channel, guard, process, session,
  task repository, and event bus testing
- Package-local test suite covering the shared doubles
- Runnable example showing `FakeAgentHarness` and `TestEventBus` usage
