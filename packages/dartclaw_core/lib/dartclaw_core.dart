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

// Bridge events (sealed — subtypes accessible via pattern matching)
export 'src/bridge/bridge_events.dart' show BridgeEvent, DeltaEvent, ToolUseEvent, ToolResultEvent, SystemInitEvent;

// Channel interfaces
export 'src/channel/channel.dart'
    show Channel, ChannelType, ChannelMessage, ChannelResponse, sourceMessageIdMetadataKey;
export 'src/channel/channel_config.dart' show ChannelConfig, GroupAccessMode, RetryPolicy;
export 'src/channel/channel_config_provider.dart' show ChannelConfigProvider;
export 'src/channel/channel_manager.dart' show ChannelManager;
export 'src/channel/message_queue.dart' show MessageQueue, TurnDispatcher;
export 'src/channel/review_command_parser.dart'
    show
        ReviewCommand,
        ReviewCommandParser,
        ChannelReviewResult,
        ChannelReviewSuccess,
        ChannelReviewMergeConflict,
        ChannelReviewError,
        ChannelReviewHandler;
export 'src/channel/task_origin.dart' show TaskOrigin;
export 'src/channel/task_trigger_config.dart' show TaskTriggerConfig;
export 'src/channel/task_trigger_parser.dart' show TaskTriggerParser, TaskTriggerResult;
export 'src/channel/text_chunking.dart' show chunkText;

// Shared channel DM access
export 'src/channel/dm_access.dart' show DmAccessMode, DmAccessController, PairingCode;

export 'src/channel/mention_gating.dart' show MentionGating;

// Container
export 'src/container/container_config.dart' show ContainerConfig;
export 'src/container/container_dispatcher.dart' show resolveProfile;
export 'src/container/container_manager.dart' show ContainerManager;
export 'src/container/credential_proxy.dart' show CredentialProxy;
export 'src/container/docker_validator.dart' show DockerValidator;
export 'src/container/security_profile.dart' show SecurityProfile;

// Harness interfaces
export 'src/harness/agent_harness.dart' show AgentHarness, PromptStrategy;
export 'src/harness/claude_code_harness.dart' show ClaudeCodeHarness;
export 'src/harness/harness_config.dart' show HarnessConfig;
export 'src/harness/mcp_tool.dart' show McpTool;
export 'src/harness/process_types.dart' show DelayFactory, HealthProbe, ProcessFactory;
export 'src/harness/tool_result.dart' show ToolResult, ToolResultError, ToolResultText;

// Worker state
export 'src/worker/worker_state.dart' show WorkerState;

// Security — interfaces and user-constructable guards
export 'package:dartclaw_security/dartclaw_security.dart';

// Memory
// Show clause review: parseMemoryEntries and memoryTimestampRe are used by
// dartclaw_server (MemoryStatusService). Retained for cross-package access
// within the workspace. Candidates for removal when server uses src/ imports.
export 'src/memory/memory_file_service.dart' show MemoryFileService;
export 'src/memory/memory_entry.dart' show MemoryEntry;
export 'src/memory/memory_entry_parser.dart' show parseMemoryEntries, memoryTimestampRe;

// Config
export 'src/config/dartclaw_config.dart' show DartclawConfig, SearchProviderEntry;
export 'src/config/scheduled_task_definition.dart' show ScheduledTaskDefinition;
export 'src/config/live_scope_config.dart' show LiveScopeConfig;
export 'src/config/session_scope_config.dart' show SessionScopeConfig, ChannelScopeConfig, DmScope, GroupScope;
export 'src/config/session_maintenance_config.dart' show SessionMaintenanceConfig, MaintenanceMode;

// Agents
export 'src/agents/agent_definition.dart' show AgentDefinition;
export 'src/agents/session_delegate.dart' show SessionDelegate;
export 'src/agents/tool_policy_cascade.dart' show ToolPolicyCascade, ToolPolicyGuard;
export 'src/agents/subagent_limits.dart' show SubagentLimits;

// Tasks
export 'src/task/goal.dart' show Goal;
export 'src/task/goal_repository.dart' show GoalRepository;
export 'src/task/goal_service.dart' show GoalService;
export 'src/task/task.dart' show Task;
export 'src/task/task_artifact.dart' show ArtifactKind, TaskArtifact;
export 'src/task/task_repository.dart' show TaskRepository;
export 'src/task/task_service.dart' show TaskService;
export 'src/task/task_status.dart' show TaskStatus;
export 'src/task/task_type.dart' show TaskType;

// Search (abstract interface — sqlite3-free)
export 'src/search/search_backend.dart' show SearchBackend;

// Events
export 'src/events/event_bus.dart' show EventBus;
export 'src/events/dartclaw_event.dart'
    show
        DartclawEvent,
        GuardBlockEvent,
        ConfigChangedEvent,
        FailedAuthEvent,
        SessionLifecycleEvent,
        SessionCreatedEvent,
        SessionEndedEvent,
        SessionErrorEvent,
        TaskLifecycleEvent,
        TaskStatusChangedEvent,
        TaskReviewReadyEvent,
        ContainerLifecycleEvent,
        ContainerStartedEvent,
        ContainerStoppedEvent,
        ContainerCrashedEvent,
        AgentLifecycleEvent,
        AgentStateChangedEvent;
export 'src/events/session_lifecycle_subscriber.dart' show SessionLifecycleSubscriber;

// Utilities
export 'src/utils/path_utils.dart' show expandHome;
