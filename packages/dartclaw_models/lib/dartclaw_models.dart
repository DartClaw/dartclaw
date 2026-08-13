/// Data models for DartClaw sessions, messages, and memory.
///
/// Zero-dependency package containing the core data types shared across
/// all DartClaw packages:
/// - [Session] / [SessionType] -- agent conversation sessions
/// - [Message] -- chat messages with role and content
/// - [SessionKey] -- typed session identifier
/// - [MemorySearchResult] -- memory search results
/// - [ChannelType] / [ChannelConfig] / [SessionScopeConfig] -- shared channel and scoping types
/// - [AgentDefinition] / [ContainerConfig] / [TaskType] -- shared runtime-adjacent value types
/// - [ExecutionPolicy] / [ExecutionMode] -- host/container execution placement
library;

export 'src/models.dart'
    show Session, SessionType, Message, MemorySearchResult, MemorySearchDegradation, MemorySearchOutcome;
export 'src/agent_definition.dart' show AgentDefinition;
export 'src/channel_config.dart' show ChannelConfig, GroupAccessMode, RetryPolicy;
export 'src/channel_config_provider.dart' show ChannelConfigProvider;
export 'src/channel_type.dart' show ChannelType;
export 'src/container_config.dart' show ContainerConfig;
export 'src/execution_policy.dart' show ExecutionMode, ExecutionPolicy;
export 'src/session_key.dart' show SessionKey;
export 'src/session_scope_config.dart' show SessionScopeConfig, ChannelScopeConfig, DmScope, GroupScope;
export 'src/task_type.dart' show TaskType;
