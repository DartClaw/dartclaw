/// Data models for DartClaw sessions, messages, and memory.
///
/// Zero-dependency package containing the core data types shared across
/// all DartClaw packages:
/// - [Session] / [SessionType] -- agent conversation sessions
/// - [Message] -- chat messages with role and content
/// - [SessionKey] -- typed session identifier
/// - [MemoryChunk] / [MemorySearchResult] -- memory system types
/// - [ChannelType] / [ChannelConfig] / [SessionScopeConfig] -- shared channel and scoping types
/// - [AgentDefinition] / [ContainerConfig] / [TaskType] -- shared runtime-adjacent value types
/// - [Project] / [ProjectStatus] / [CloneStrategy] / [PrStrategy] -- project management
/// - [WorkflowDefinition] / [WorkflowStep] / [WorkflowVariable] / [WorkflowLoop] -- workflow domain models
/// - [WorkflowRun] / [WorkflowRunStatus] -- workflow execution state
library;

export 'src/models.dart' show Session, SessionType, Message, MemoryChunk, MemorySearchResult;
export 'src/agent_definition.dart' show AgentDefinition;
export 'src/channel_config.dart' show ChannelConfig, GroupAccessMode, RetryPolicy;
export 'src/channel_config_provider.dart' show ChannelConfigProvider;
export 'src/channel_type.dart' show ChannelType;
export 'src/container_config.dart' show ContainerConfig;
export 'src/session_key.dart' show SessionKey;
export 'src/session_scope_config.dart' show SessionScopeConfig, ChannelScopeConfig, DmScope, GroupScope;
export 'src/task_type.dart' show TaskType;
export 'src/project.dart' show Project, ProjectAuthStatus, ProjectStatus, CloneStrategy, PrStrategy, PrConfig;
export 'src/tool_call_record.dart' show ToolCallRecord;
export 'src/turn_trace.dart' show TurnTrace;
export 'src/turn_trace_summary.dart' show TurnTraceSummary;
export 'src/task_event.dart'
    show
        TaskEvent,
        TaskEventKind,
        StatusChanged,
        ToolCalled,
        ArtifactCreated,
        StructuredOutputInlineUsed,
        StructuredOutputFallbackUsed,
        PushBack,
        TokenUpdate,
        TaskErrorEvent,
        Compaction;
export 'src/workflow_definition.dart'
    show
        ActionNode,
        ForeachNode,
        LoopNode,
        MapNode,
        ParallelGroupNode,
        WorkflowDefinition,
        WorkflowNode,
        WorkflowStep,
        WorkflowVariable,
        WorkflowLoop,
        WorkflowGitPublishStrategy,
        WorkflowGitArtifactsStrategy,
        WorkflowGitExternalArtifactMount,
        WorkflowGitWorktreeStrategy,
        WorkflowGitStrategy,
        StepConfigDefault,
        OnFailurePolicy,
        StepReviewMode,
        ExtractionType,
        ExtractionConfig,
        OutputFormat,
        OutputMode,
        OutputConfig;
export 'src/workflow_run.dart'
    show
        WorkflowExecutionCursor,
        WorkflowExecutionCursorNodeType,
        WorkflowRun,
        WorkflowRunStatus,
        WorkflowWorktreeBinding;
export 'src/skill_info.dart' show SkillInfo, SkillSource;
