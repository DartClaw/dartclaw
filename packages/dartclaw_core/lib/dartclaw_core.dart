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
export 'src/runtime/channel_type.dart' show ChannelType;
export 'src/channel/channel.dart' show Channel, ChannelMessage, ChannelResponse, sourceMessageIdMetadataKey;
export 'src/channel/channel_manager.dart' show ChannelManager;
export 'src/channel/mention_gating.dart' show MentionGating;
export 'src/channel/message_queue.dart' show MessageQueue, TurnDispatcher;
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
export 'src/channel/message_deduplicator.dart' show MessageDeduplicator;

// Shared channel DM access
export 'src/channel/dm_access.dart' show DmAccessMode, DmAccessController, PairingCode;

// Harness interfaces
export 'src/harness/agent_harness.dart' show AgentHarness, PromptStrategy;
export 'src/harness/claude_code_harness.dart' show ClaudeCodeHarness;
export 'src/harness/harness_config.dart' show HarnessConfig;
export 'src/harness/mcp_tool.dart' show McpTool;
export 'src/harness/process_types.dart' show ProcessFactory, CommandProbe, DelayFactory, HealthProbe;
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

// Config — section types
export 'src/config/agent_config.dart' show AgentConfig;
export 'src/config/auth_config.dart' show AuthConfig;
export 'src/config/context_config.dart' show ContextConfig;
export 'src/config/gateway_config.dart' show GatewayConfig;
export 'src/config/logging_config.dart' show LoggingConfig;
export 'src/config/memory_config.dart' show MemoryConfig;
export 'src/config/scheduling_config.dart' show SchedulingConfig;
export 'src/config/search_config.dart' show SearchConfig, SearchProviderEntry;
export 'src/config/security_config.dart' show SecurityConfig;
export 'src/config/server_config.dart' show ServerConfig;
export 'src/config/session_config.dart' show SessionConfig;
export 'src/config/task_config.dart' show TaskConfig;
export 'src/config/usage_config.dart' show UsageConfig;
export 'src/config/workspace_config.dart' show WorkspaceConfig;
// Config — top-level
export 'src/config/dartclaw_config.dart' show DartclawConfig;
export 'src/config/scheduled_task_definition.dart' show ScheduledTaskDefinition;
export 'src/container/container_config.dart' show ContainerConfig;
export 'src/container/container_manager.dart' show ContainerManager, RunCommand, StartCommand;
export 'src/scoping/channel_config.dart' show ChannelConfig, GroupAccessMode, RetryPolicy;
export 'src/scoping/channel_config_provider.dart' show ChannelConfigProvider;
export 'src/scoping/live_scope_config.dart' show LiveScopeConfig;
export 'src/scoping/session_scope_config.dart' show SessionScopeConfig, ChannelScopeConfig, DmScope, GroupScope;
export 'src/config/session_maintenance_config.dart' show SessionMaintenanceConfig, MaintenanceMode;

// Agents
export 'src/agents/agent_definition.dart' show AgentDefinition;
export 'src/agents/session_delegate.dart' show SessionDelegate;
export 'src/agents/tool_policy_cascade.dart' show ToolPolicyCascade, ToolPolicyGuard;
export 'src/agents/subagent_limits.dart' show SubagentLimits;

// Tasks
export 'src/task/goal.dart' show Goal;
export 'src/task/goal_repository.dart' show GoalRepository;
export 'src/task/task.dart' show Task;
export 'src/task/task_artifact.dart' show ArtifactKind, TaskArtifact;
export 'src/task/task_repository.dart' show TaskRepository;
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

// Utilities
export 'src/utils/path_utils.dart' show expandHome;
export 'src/worker/worker_state.dart' show WorkerState;
