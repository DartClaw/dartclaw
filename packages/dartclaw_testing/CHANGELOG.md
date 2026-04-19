All DartClaw packages use lock-step versioning. This changelog tracks changes
relevant to `dartclaw_testing`.

## Unreleased

### Added
- `InMemoryAgentExecutionRepository` for repository tests and parity checks
- S34 task/execution test helpers for AE-backed task hydration and workflow-step persistence

## 0.9.0

### Added
- Canonical shared test doubles for harness, channel, guard, process, session,
  task repository, and event bus testing
- Package-local test suite covering the shared doubles
- Runnable example showing `FakeAgentHarness` and `TestEventBus` usage
