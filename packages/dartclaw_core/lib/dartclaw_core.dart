/// Core abstractions for the DartClaw agent runtime.
///
/// Provides the platform-independent building blocks:
/// - [AgentHarness] / [ClaudeCodeHarness] -- subprocess lifecycle management
/// - [Guard] / [GuardChain] -- security policy evaluation pipeline
/// - [Channel] -- multi-channel messaging interface (WhatsApp, Signal)
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
export 'src/channel/channel_manager.dart' show ChannelManager;
export 'src/channel/message_queue.dart' show MessageQueue, TurnDispatcher;

// Shared channel DM access
export 'src/channel/dm_access.dart' show DmAccessMode, DmAccessController, PairingCode;

// Signal channel
export 'src/channel/signal/signal_channel.dart' show SignalChannel;
export 'src/channel/signal/signal_cli_manager.dart' show SignalCliManager;
export 'src/channel/signal/signal_config.dart' show SignalConfig;
export 'src/channel/signal/signal_dm_access.dart' show SignalGroupAccessMode, SignalMentionGating;
export 'src/channel/signal/signal_sender_map.dart' show SignalSenderMap;

// Google Chat channel
export 'src/channel/googlechat/google_chat_config.dart'
    show GoogleChatConfig, GoogleChatAudienceConfig, GoogleChatAudienceMode;
export 'src/channel/googlechat/gcp_auth_service.dart' show GcpAuthService;
export 'src/channel/googlechat/google_chat_channel.dart' show GoogleChatChannel;
export 'src/channel/googlechat/google_chat_rest_client.dart' show GoogleChatApiException, GoogleChatRestClient;

// WhatsApp channel
export 'src/channel/whatsapp/whatsapp_channel.dart' show WhatsAppChannel;
export 'src/channel/whatsapp/whatsapp_config.dart' show WhatsAppConfig, GroupAccessMode;
export 'src/channel/whatsapp/gowa_manager.dart' show GowaManager, GowaLoginQr, GowaStatus;
export 'src/channel/whatsapp/mention_gating.dart' show MentionGating;

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
export 'src/harness/tool_result.dart' show ToolResult, ToolResultError, ToolResultText;

// Worker state
export 'src/worker/worker_state.dart' show WorkerState;

// Behavior services
export 'src/behavior/behavior_file_service.dart' show BehaviorFileService;
export 'src/behavior/heartbeat_scheduler.dart' show HeartbeatScheduler;
export 'src/behavior/self_improvement_service.dart' show SelfImprovementService;

// Security — interfaces and user-constructable guards
export 'src/security/guard.dart' show Guard, GuardChain, GuardContext;
export 'src/security/guard_verdict.dart' show GuardVerdict, GuardPass, GuardWarn, GuardBlock;
export 'src/security/guard_config.dart' show GuardConfig;
export 'src/security/content_classifier.dart' show ContentClassifier;
export 'src/security/command_guard.dart' show CommandGuard, CommandGuardConfig;
export 'src/security/file_guard.dart' show FileAccessLevel, FileGuard, FileGuardConfig, FileGuardRule;
export 'src/security/network_guard.dart' show NetworkGuard, NetworkGuardConfig;
export 'src/security/input_sanitizer.dart' show InputSanitizer, InputSanitizerConfig;
export 'src/security/message_redactor.dart' show MessageRedactor;
export 'src/security/content_guard.dart' show ContentGuard;
export 'src/security/guard_audit.dart' show GuardAuditLogger, GuardAuditSubscriber, AuditEntry;
export 'src/security/anthropic_api_classifier.dart' show AnthropicApiClassifier;
export 'src/security/claude_binary_classifier.dart' show ClaudeBinaryClassifier;

// Workspace
export 'src/workspace/workspace_service.dart' show WorkspaceService, WorkspaceMigrationException;
export 'src/workspace/workspace_git_sync.dart' show WorkspaceGitSync;

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
export 'src/maintenance/session_maintenance_service.dart'
    show SessionMaintenanceService, MaintenanceReport, MaintenanceAction;

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

// Observability
export 'src/observability/usage_tracker.dart' show UsageTracker, UsageEvent;

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
