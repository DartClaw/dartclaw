/// Data models for DartClaw sessions, messages, and memory.
///
/// Zero-dependency package containing the core data types shared across
/// all DartClaw packages:
/// - [Session] / [SessionType] -- agent conversation sessions
/// - [Message] -- chat messages with role and content
/// - [SessionKey] -- typed session identifier
/// - [MemoryChunk] / [MemorySearchResult] -- memory system types
/// - [Project] / [ProjectStatus] / [CloneStrategy] / [PrStrategy] -- project management
/// - [WorkflowDefinition] / [WorkflowStep] / [WorkflowVariable] / [WorkflowLoop] -- workflow domain models
/// - [WorkflowRun] / [WorkflowRunStatus] -- workflow execution state
library;

export 'src/models.dart'
    show Session, SessionType, Message, MemoryChunk, MemorySearchResult;
export 'src/session_key.dart' show SessionKey;
export 'src/project.dart'
    show Project, ProjectStatus, CloneStrategy, PrStrategy, PrConfig;
export 'src/tool_call_record.dart' show ToolCallRecord;
export 'src/turn_trace.dart' show TurnTrace;
export 'src/turn_trace_summary.dart' show TurnTraceSummary;
export 'src/task_event.dart'
    show TaskEvent, TaskEventKind, StatusChanged, ToolCalled, ArtifactCreated, PushBack, TokenUpdate, TaskErrorEvent;
export 'src/workflow_definition.dart'
    show
        WorkflowDefinition,
        WorkflowStep,
        WorkflowVariable,
        WorkflowLoop,
        StepReviewMode,
        ExtractionType,
        ExtractionConfig;
export 'src/workflow_run.dart' show WorkflowRun, WorkflowRunStatus;
