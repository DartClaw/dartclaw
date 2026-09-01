/// Shared test doubles and in-memory helpers for DartClaw packages.
///
/// The public surface stays intentionally narrow: only the canonical shared
/// doubles that are reused across package test suites are exported here.
///
/// A double for a port owned above `dartclaw_core` lives in the package that
/// owns the port, behind that package's `testing.dart` entry point.
library;

export 'package:dartclaw_core/dartclaw_core.dart'
    show
        AgentHarness,
        BridgeEvent,
        BusyTurnException,
        Channel,
        ChannelMessage,
        ChannelResponse,
        DartclawEvent,
        EventBus,
        PromptStrategy,
        ProjectService,
        SessionService,
        Task,
        TaskArtifact,
        TaskRepository,
        TaskStatus,
        TurnManager,
        TurnOutcome,
        TurnRunner,
        TurnStatus,
        WorkerState;

export 'src/channel_test_helpers.dart' show TaskOps, channelOriginJson, createTask, putTaskInReview, shortTaskId;
export 'src/codex_harness_test_helpers.dart'
    show
        defaultCommandProbe,
        latestRequestId,
        noOpDelay,
        pumpEventLoop,
        respondToLatestThreadStart,
        respondToLatestThreadStartV118,
        result,
        startHarness,
        startHarnessV118,
        waitForSentMessage;
export 'src/fake_agent_harness.dart' show FakeAgentHarness;
export 'src/canonical_memory_fixture.dart' show seedCanonicalMemory;
export 'src/fake_channel.dart' show FakeChannel;
export 'src/fake_channel_manager.dart' show FakeChannelManager;
export 'src/fake_codex_process.dart' show FakeCodexProcess;
export 'src/fake_content_classifier.dart' show FakeContentClassifier;
export 'src/fake_guard.dart' show FakeGuard;
export 'src/fake_google_jwt_verifier.dart' show FakeGoogleJwtVerifier, GoogleJwtVerifyCallback;
export 'src/fake_project_service.dart' show FakeProjectService;
export 'src/fake_process.dart'
    show CapturingFakeProcess, FakeProcess, GitInvocation, RecordingGitRunner, makeVersionProbeProcess;
export 'src/fake_turn_manager.dart' show FakeTurnManager;
export 'src/flush_async.dart' show flushAsync;
export 'src/in_memory_session_service.dart' show InMemorySessionService;
export 'src/in_memory_task_repository.dart' show InMemoryTaskRepository;
export 'src/in_memory_workflow_step_execution_repository.dart' show InMemoryWorkflowStepExecutionRepository;
export 'src/null_io_sink.dart' show NullIoSink;
export 'src/recording_message_queue.dart' show RecordingMessageQueue;
export 'src/test_event_bus.dart' show TestEventBus;
