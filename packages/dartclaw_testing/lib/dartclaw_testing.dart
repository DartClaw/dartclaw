/// Shared test doubles and in-memory helpers for DartClaw packages.
///
/// The public surface stays intentionally narrow: only the canonical shared
/// doubles that are reused across package test suites are exported here.
library;

export 'src/fake_agent_harness.dart' show FakeAgentHarness;
export 'src/fake_channel.dart' show FakeChannel;
export 'src/fake_guard.dart' show FakeGuard;
export 'src/fake_process.dart' show CapturingFakeProcess, FakeProcess;
export 'src/in_memory_session_service.dart' show InMemorySessionService;
export 'src/in_memory_task_repository.dart' show InMemoryTaskRepository;
export 'src/test_event_bus.dart' show TestEventBus;
