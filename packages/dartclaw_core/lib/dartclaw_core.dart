library;

// Models & data types
export 'src/models/models.dart'
    show Session, SessionType, Message, MemoryChunk, MemorySearchResult;
export 'src/models/session_key.dart' show SessionKey;

// Storage services (file-based — sqlite3-free)
export 'src/storage/session_service.dart' show SessionService;
export 'src/storage/message_service.dart' show MessageService;
export 'src/storage/kv_service.dart' show KvService;

// Bridge events (sealed — subtypes accessible via pattern matching)
export 'src/bridge/bridge_events.dart'
    show BridgeEvent, DeltaEvent, ToolUseEvent, ToolResultEvent, SystemInitEvent;

// Channel interfaces
export 'src/channel/channel.dart'
    show Channel, ChannelType, ChannelMessage, ChannelResponse;
export 'src/channel/channel_manager.dart' show ChannelManager;
export 'src/channel/message_queue.dart' show MessageQueue, TurnDispatcher;

// Signal channel
export 'src/channel/signal/signal_channel.dart' show SignalChannel;
export 'src/channel/signal/signal_cli_manager.dart' show SignalCliManager;
export 'src/channel/signal/signal_config.dart' show SignalConfig;
export 'src/channel/signal/signal_dm_access.dart'
    show SignalDmAccessMode, SignalGroupAccessMode, SignalDmAccessController,
        SignalMentionGating;

// WhatsApp channel
export 'src/channel/whatsapp/whatsapp_channel.dart' show WhatsAppChannel;
export 'src/channel/whatsapp/whatsapp_config.dart'
    show WhatsAppConfig, DmAccessMode, GroupAccessMode;
export 'src/channel/whatsapp/gowa_manager.dart' show GowaManager, GowaStatus;
export 'src/channel/whatsapp/dm_access.dart' show DmAccessController, PairingCode;
export 'src/channel/whatsapp/mention_gating.dart' show MentionGating;

// Container
export 'src/container/docker_validator.dart' show DockerValidator;

// Harness interfaces
export 'src/harness/agent_harness.dart' show AgentHarness, PromptStrategy;
export 'src/harness/claude_code_harness.dart' show ClaudeCodeHarness;
export 'src/harness/harness_config.dart' show HarnessConfig;
export 'src/harness/mcp_tool.dart' show McpTool;

// Worker state
export 'src/worker/worker_state.dart' show WorkerState;

// Behavior services
export 'src/behavior/behavior_file_service.dart' show BehaviorFileService;
export 'src/behavior/heartbeat_scheduler.dart' show HeartbeatScheduler;
export 'src/behavior/self_improvement_service.dart'
    show SelfImprovementService;

// Security — interfaces and user-constructable guards
export 'src/security/guard.dart' show Guard, GuardChain, GuardContext;
export 'src/security/guard_verdict.dart' show GuardVerdict;
export 'src/security/guard_config.dart' show GuardConfig;
export 'src/security/content_classifier.dart' show ContentClassifier;
export 'src/security/command_guard.dart' show CommandGuard, CommandGuardConfig;
export 'src/security/file_guard.dart' show FileGuard, FileGuardConfig;
export 'src/security/network_guard.dart' show NetworkGuard, NetworkGuardConfig;
export 'src/security/input_sanitizer.dart' show InputSanitizer, InputSanitizerConfig;
export 'src/security/message_redactor.dart' show MessageRedactor;
export 'src/security/content_guard.dart' show ContentGuard;
export 'src/security/guard_audit.dart' show GuardAuditLogger;
export 'src/security/anthropic_api_classifier.dart' show AnthropicApiClassifier;
export 'src/security/claude_binary_classifier.dart' show ClaudeBinaryClassifier;

// Workspace
export 'src/workspace/workspace_service.dart'
    show WorkspaceService, WorkspaceMigrationException;
export 'src/workspace/workspace_git_sync.dart' show WorkspaceGitSync;

// Memory
export 'src/memory/memory_file_service.dart' show MemoryFileService;
export 'src/memory/memory_entry.dart' show MemoryEntry;

// Config
export 'src/config/dartclaw_config.dart' show DartclawConfig;

// Agents
export 'src/agents/agent_definition.dart' show AgentDefinition;
export 'src/agents/session_delegate.dart' show SessionDelegate;
export 'src/agents/tool_policy_cascade.dart' show ToolPolicyCascade, ToolPolicyGuard;
export 'src/agents/subagent_limits.dart' show SubagentLimits;

// Search (abstract interface — sqlite3-free)
export 'src/search/search_backend.dart' show SearchBackend;

// Observability
export 'src/observability/usage_tracker.dart' show UsageTracker, UsageEvent;
