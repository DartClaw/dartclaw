/// Shared test doubles and in-memory helpers for DartClaw packages.
///
/// The public surface stays intentionally narrow: only the canonical shared
/// doubles that are reused across package test suites are exported here.
library;

export 'package:dartclaw_core/dartclaw_core.dart'
    show
        AgentExecution,
        AgentExecutionRepository,
        AgentHarness,
        BridgeEvent,
        Channel,
        ChannelMessage,
        ChannelResponse,
        ChannelType,
        DartclawEvent,
        EventBus,
        ExecutionRepositoryTransactor,
        PromptStrategy,
        ProjectService,
        SessionKey,
        SessionService,
        Task,
        TaskArtifact,
        TaskRepository,
        TaskStatus,
        TaskType,
        WorkflowStepExecution,
        WorkflowStepExecutionRepository,
        WorkerState;
export 'package:dartclaw_google_chat/dartclaw_google_chat.dart'
    show GoogleChatAudienceConfig, GoogleChatAudienceMode, GoogleChatRestClient;
export 'package:dartclaw_models/dartclaw_models.dart' show CloneStrategy, PrConfig, Project, ProjectStatus;
export 'package:dartclaw_security/dartclaw_security.dart' show Guard, GuardContext, GuardVerdict;
export 'package:dartclaw_server/dartclaw_server.dart'
    show BusyTurnException, GoogleJwtVerifier, HarnessPool, TurnManager, TurnOutcome, TurnRunner, TurnStatus;
export 'src/channel_test_helpers.dart'
    show RecordingReviewHandler, TaskOps, channelOriginJson, createTask, putTaskInReview, shortTaskId;
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
export 'src/fake_channel.dart' show FakeChannel;
export 'src/fake_codex_process.dart' show FakeCodexProcess;
export 'src/fake_google_chat_rest_client.dart' show FakeGoogleChatRestClient;
export 'src/fake_google_jwt_verifier.dart' show FakeGoogleJwtVerifier;
export 'src/fake_guard.dart' show FakeGuard;
export 'src/fake_git_gateway.dart' show FakeGitGateway;
export 'src/fake_project_service.dart' show FakeProjectService;
export 'src/fake_process.dart' show CapturingFakeProcess, FakeProcess;
export 'src/fake_turn_manager.dart' show FakeTurnManager;
export 'src/flush_async.dart' show flushAsync;
export 'src/in_memory_agent_execution_repository.dart' show InMemoryAgentExecutionRepository;
export 'src/in_memory_execution_repository_transactor.dart' show InMemoryExecutionRepositoryTransactor;
export 'src/in_memory_session_service.dart' show InMemorySessionService;
export 'src/in_memory_task_repository.dart' show InMemoryTaskRepository;
export 'src/in_memory_workflow_step_execution_repository.dart' show InMemoryWorkflowStepExecutionRepository;
export 'src/null_io_sink.dart' show NullIoSink;
export 'src/recording_message_queue.dart' show RecordingMessageQueue;
export 'src/test_event_bus.dart' show TestEventBus;
export 'src/workflow_git_fixture.dart' show WorkflowGitFixture;
