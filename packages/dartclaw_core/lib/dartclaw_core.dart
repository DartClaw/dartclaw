/// Core abstractions for the DartClaw agent runtime.
///
/// Provides the platform-independent building blocks:
/// - [AgentHarness] / [ClaudeCodeHarness] -- subprocess lifecycle management
/// - [Guard] / [GuardChain] -- security policy evaluation pipeline
/// - [Channel] -- multi-channel messaging interface foundations
/// - [BridgeEvent] -- sealed event hierarchy from the JSONL control protocol
/// - [HarnessConfig] / [McpTool] -- SDK configuration and MCP tool interface
///
/// This package has no sqlite3 dependency. For FTS5 search and memory
/// pruning, see `dartclaw_storage`.
library;

// Models & data types (re-exported from dartclaw_models)
export 'package:dartclaw_models/dartclaw_models.dart';

// Storage services (file-based — sqlite3-free)
export 'src/storage/session_service.dart' show SessionService;
export 'src/storage/message_service.dart' show MessageService;
export 'src/storage/kv_service.dart' show KvService;
export 'src/storage/atomic_write.dart' show atomicWriteJson;

// Bridge events (sealed — subtypes accessible via pattern matching)
export 'src/bridge/bridge_events.dart'
    show
        BridgeEvent,
        DeltaEvent,
        ToolUseEvent,
        ToolResultEvent,
        SystemInitEvent,
        CompactionStartingBridgeEvent,
        CompactionCompletedBridgeEvent;

// Channel interfaces
export 'src/channel/channel.dart' show Channel, ChannelMessage, ChannelResponse, sourceMessageIdMetadataKey;
export 'src/channel/channel_feedback.dart'
    show ChannelFeedbackStrategy, FeedbackContext, NoFeedbackStrategy, TurnProgressSnapshot;
export 'src/channel/channel_manager.dart' show ChannelManager;
export 'src/channel/channel_task_bridge.dart' show ChannelTaskBridge, ReservedCommandHandler;
export 'src/channel/recipient_resolver.dart' show resolveRecipientId;
export 'src/channel/mention_gating.dart' show MentionGating;
export 'src/channel/message_queue.dart' show BudgetExhaustedError, MessageQueue, TurnDispatcher, TurnObserver;
export 'src/channel/review_command_parser.dart'
    show
        ReviewCommand,
        ChannelReviewResult,
        ChannelReviewSuccess,
        ChannelReviewMergeConflict,
        ChannelReviewError,
        ChannelReviewHandler,
        ReviewCommandParser;
export 'src/channel/task_origin.dart' show TaskOrigin;
export 'src/channel/task_creator.dart' show TaskCreator, TaskLister;
export 'src/channel/task_trigger_config.dart' show TaskTriggerConfig;
export 'src/channel/task_trigger_parser.dart' show TaskTriggerParser, TaskTriggerResult;
export 'src/channel/text_chunking.dart' show chunkText;
export 'src/channel/turn_progress_event.dart'
    show
        TurnProgressEvent,
        ToolStartedProgressEvent,
        ToolCompletedProgressEvent,
        TextDeltaProgressEvent,
        StatusTickProgressEvent,
        TurnStallProgressEvent;
export 'src/channel/message_deduplicator.dart' show MessageDeduplicator;
export 'src/channel/thread_binding.dart' show ThreadBinding, ThreadBindingStore, extractThreadId;
export 'src/channel/thread_binding_lifecycle_manager.dart' show ThreadBindingLifecycleManager;

// Shared channel DM access
export 'src/channel/dm_access.dart' show DmAccessMode, DmAccessController, PairingCode;

// Harness interfaces
export 'src/harness/agent_harness.dart' show AgentHarness, PromptStrategy;
export 'src/harness/conversation_history.dart' show buildReplaySafeHistory;
export 'src/harness/canonical_tool.dart' show CanonicalTool;
export 'src/harness/claude_code_harness.dart' show ClaudeCodeHarness;
export 'src/harness/claude_protocol_adapter.dart' show ClaudeProtocolAdapter;
export 'src/harness/codex_config_generator.dart' show CodexConfigGenerator;
export 'src/harness/codex_environment.dart' show CodexEnvironment;
export 'src/harness/codex_harness.dart' show CodexHarness;
export 'src/harness/codex_protocol_adapter.dart' show CodexProtocolAdapter;
export 'src/harness/codex_settings.dart' show CodexSettings;
export 'src/harness/harness_config.dart' show HarnessConfig;
export 'src/harness/harness_factory.dart' show HarnessFactory, HarnessFactoryConfig;
export 'src/harness/merge_resolve_env_vars.dart'
    show
        mergeResolveIntegrationBranchEnvVar,
        mergeResolveStoryBranchEnvVar,
        mergeResolveTokenCeilingEnvVar,
        mergeResolveEnvVarNames;
export 'src/harness/mcp_tool.dart' show McpTool;
export 'src/harness/claude_protocol.dart' show claudeHardeningEnvVars;
export 'src/harness/process_types.dart' show ProcessFactory, CommandProbe, DelayFactory, HealthProbe;
export 'src/harness/protocol_adapter.dart' show ProtocolAdapter;
// Protocol message boundary. `ToolResult` remains owned by `tool_result.dart`
// in this barrel because it is already part of the MCP public API.
export 'src/harness/protocol_message.dart'
    show ProtocolMessage, TextDelta, ToolUse, ControlRequest, TurnComplete, SystemInit, CompactBoundary;
export 'src/harness/tool_policy.dart' show ToolApprovalPolicy;
export 'src/harness/tool_result.dart' show ToolResult, ToolResultError, ToolResultText;

// Security — interfaces and user-constructable guards
export 'package:dartclaw_security/dartclaw_security.dart';

// Memory
// Show clause review: parseMemoryEntries and memoryTimestampRe are used by
// dartclaw_server (MemoryStatusService). Retained for cross-package access
// within the workspace. Candidates for removal when server uses src/ imports.
export 'src/memory/memory_file_service.dart' show MemoryFileService;
export 'src/memory/memory_entry.dart' show MemoryEntry;
export 'src/memory/memory_entry_parser.dart' show parseMemoryEntries, memoryTimestampRe;

export 'src/container/container_executor.dart' show ContainerExecutor, containerClaudeExecutable;
export 'src/scoping/common_channel_fields.dart' show CommonChannelFields;
export 'src/scoping/group_config_resolver.dart' show GroupConfigResolver;
export 'src/scoping/group_entry.dart' show GroupEntry;
export 'src/scoping/live_scope_config.dart' show LiveScopeConfig;
export 'src/governance/sliding_window_rate_limiter.dart' show SlidingWindowRateLimiter;

// Agents
export 'src/agents/session_delegate.dart' show SessionDelegate;
export 'src/agents/tool_policy_cascade.dart' show ToolPolicyCascade, ToolPolicyGuard;
export 'src/agents/subagent_limits.dart' show SubagentLimits;

// Execution
export 'src/execution/agent_execution.dart' show AgentExecution;
export 'src/execution/agent_execution_repository.dart' show AgentExecutionRepository;
export 'src/execution/execution_repository_transactor.dart' show ExecutionRepositoryTransactor;
export 'src/execution/workflow_step_execution.dart' show WorkflowStepExecution;
export 'src/execution/workflow_step_execution_repository.dart' show WorkflowStepExecutionRepository;

// Tasks
export 'src/task/goal.dart' show Goal;
export 'src/task/goal_repository.dart' show GoalRepository;
export 'src/task/task.dart' show Task;
export 'src/task/task_artifact.dart' show ArtifactKind, TaskArtifact;
export 'src/task/task_repository.dart' show TaskRepository;
export 'src/task/task_status.dart' show TaskStatus;
export 'src/task/workflow_task_service.dart' show WorkflowTaskService;

// Concurrency
export 'src/concurrency/repo_lock.dart' show RepoLock;

// Search (abstract interface — sqlite3-free)
export 'src/search/search_backend.dart' show SearchBackend;

// Project service interface
export 'src/project/project_service.dart' show ProjectService;

// Events
export 'src/events/event_bus.dart' show EventBus;
export 'src/events/session_lifecycle_subscriber.dart' show SessionLifecycleSubscriber;
export 'src/events/dartclaw_event.dart'
    show
        DartclawEvent,
        GuardBlockEvent,
        ToolPermissionDeniedEvent,
        ConfigChangedEvent,
        FailedAuthEvent,
        SessionLifecycleEvent,
        SessionCreatedEvent,
        SessionEndedEvent,
        SessionErrorEvent,
        AgentExecutionEvent,
        AgentExecutionStatusChangedEvent,
        TaskLifecycleEvent,
        TaskStatusChangedEvent,
        TaskReviewReadyEvent,
        ContainerLifecycleEvent,
        ContainerStartedEvent,
        ContainerStoppedEvent,
        ContainerCrashedEvent,
        AgentLifecycleEvent,
        AgentStateChangedEvent,
        AdvisorInsightEvent,
        AdvisorMentionEvent,
        LoopDetectedEvent,
        EmergencyStopEvent,
        ProjectLifecycleEvent,
        ProjectStatusChangedEvent,
        TaskEventCreatedEvent,
        BudgetWarningEvent,
        LoopIterationCompletedEvent,
        MapIterationCompletedEvent,
        MapStepCompletedEvent,
        WorkflowSerializationEnactedEvent,
        StepSkippedEvent,
        ParallelGroupCompletedEvent,
        WorkflowApprovalRequestedEvent,
        WorkflowApprovalResolvedEvent,
        WorkflowBudgetWarningEvent,
        WorkflowLifecycleEvent,
        WorkflowCliTurnProgressEvent,
        WorkflowRunStatusChangedEvent,
        WorkflowStepCompletedEvent,
        CompactionLifecycleEvent,
        CompactionStartingEvent,
        CompactionCompletedEvent,
        ScheduledJobFailedEvent;

// Governance
export 'src/governance/loop_detection.dart' show LoopDetection, LoopMechanism, LoopDetectedException;
export 'src/governance/loop_detector.dart' show LoopDetector;

export 'src/worker/worker_state.dart' show WorkerState;

// Behavior
export 'src/behavior/prompt_scope.dart' show PromptScope;
