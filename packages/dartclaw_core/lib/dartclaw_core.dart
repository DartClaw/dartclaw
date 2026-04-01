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
export 'src/bridge/bridge_events.dart' show BridgeEvent, DeltaEvent, ToolUseEvent, ToolResultEvent, SystemInitEvent;

// Channel interfaces
export 'src/runtime/channel_type.dart' show ChannelType;
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
export 'src/harness/codex_exec_harness.dart' show CodexExecHarness;
export 'src/harness/codex_harness.dart' show CodexHarness;
export 'src/harness/codex_exec_protocol_adapter.dart' show CodexExecProtocolAdapter;
export 'src/harness/codex_protocol_adapter.dart' show CodexProtocolAdapter;
export 'src/harness/codex_settings.dart' show CodexSettings;
export 'src/harness/harness_config.dart' show HarnessConfig;
export 'src/harness/harness_factory.dart' show HarnessFactory, HarnessFactoryConfig;
export 'src/harness/mcp_tool.dart' show McpTool;
export 'src/harness/claude_protocol.dart' show claudeHardeningEnvVars;
export 'src/harness/process_types.dart' show ProcessFactory, CommandProbe, DelayFactory, HealthProbe;
export 'src/harness/protocol_adapter.dart' show ProtocolAdapter;
// Protocol message boundary. `ToolResult` remains owned by `tool_result.dart`
// in this barrel because it is already part of the MCP public API.
export 'src/harness/protocol_message.dart'
    show ProtocolMessage, TextDelta, ToolUse, ControlRequest, TurnComplete, SystemInit;
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
export 'src/config/history_config.dart' show HistoryConfig;
export 'src/config/advisor_config.dart' show AdvisorConfig;
export 'src/config/credential_registry.dart' show CredentialRegistry;
export 'src/config/credentials_config.dart' show CredentialsConfig, CredentialEntry;
export 'src/config/provider_identity.dart' show ProviderIdentity;
export 'src/config/auth_config.dart' show AuthConfig;
export 'src/config/canvas_config.dart' show CanvasConfig, CanvasShareConfig, CanvasWorkshopConfig;
export 'src/config/context_config.dart' show ContextConfig;
export 'src/config/gateway_config.dart' show GatewayConfig;
export 'src/config/logging_config.dart' show LoggingConfig;
export 'src/config/provider_validator.dart' show ProviderValidator, processOutputToText, extractVersionLine;
export 'src/config/providers_config.dart' show ProviderEntry, ProvidersConfig;
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
export 'src/container/container_dispatcher.dart' show resolveProfile;
export 'src/container/container_manager.dart' show ContainerManager, RunCommand, StartCommand;
export 'src/container/credential_proxy.dart' show CredentialProxy;
export 'src/container/docker_validator.dart' show DockerValidator;
export 'src/container/security_profile.dart' show SecurityProfile;
export 'src/scoping/channel_config.dart' show ChannelConfig, GroupAccessMode, RetryPolicy;
export 'src/scoping/channel_config_provider.dart' show ChannelConfigProvider;
export 'src/scoping/group_config_resolver.dart' show GroupConfigResolver;
export 'src/scoping/group_entry.dart' show GroupEntry;
export 'src/scoping/live_scope_config.dart' show LiveScopeConfig;
export 'src/scoping/session_scope_config.dart' show SessionScopeConfig, ChannelScopeConfig, DmScope, GroupScope;
export 'src/config/session_maintenance_config.dart' show SessionMaintenanceConfig, MaintenanceMode;
export 'src/config/governance_config.dart'
    show
        CrowdCodingConfig,
        GovernanceConfig,
        RateLimitsConfig,
        PerSenderRateLimitConfig,
        GlobalRateLimitConfig,
        BudgetConfig,
        BudgetAction,
        QueueStrategy,
        TurnProgressConfig,
        TurnProgressAction,
        LoopDetectionConfig,
        LoopAction;
export 'src/config/features_config.dart' show FeaturesConfig, ThreadBindingFeatureConfig;
export 'src/config/project_config.dart' show ProjectConfig, ProjectDefinition;
export 'src/utils/sliding_window_rate_limiter.dart' show SlidingWindowRateLimiter;

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

// Project service interface
export 'src/project/project_service.dart' show ProjectService;

// Events
export 'src/events/event_bus.dart' show EventBus;
export 'src/events/session_lifecycle_subscriber.dart' show SessionLifecycleSubscriber;
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
        AgentStateChangedEvent,
        AdvisorInsightEvent,
        AdvisorMentionEvent,
        LoopDetectedEvent,
        EmergencyStopEvent,
        ProjectLifecycleEvent,
        ProjectStatusChangedEvent,
        TaskEventCreatedEvent;

// Governance
export 'src/governance/loop_detection.dart' show LoopDetection, LoopMechanism, LoopDetectedException;
export 'src/governance/loop_detector.dart' show LoopDetector;

// Utilities
export 'src/utils/duration_parser.dart' show tryParseDuration;
export 'src/utils/path_utils.dart' show expandHome;
export 'src/worker/worker_state.dart' show WorkerState;
