/// Core abstractions for the DartClaw agent runtime.
///
/// Provides the platform-independent building blocks:
/// - [AgentHarness] / [ClaudeCodeHarness] -- subprocess lifecycle management
/// - [Guard] / [GuardChain] -- security policy evaluation pipeline
/// - [Channel] -- multi-channel messaging interface foundations
/// - [BridgeEvent] -- sealed event hierarchy from the JSONL control protocol
/// - [HarnessLaunchOptions] / [McpTool] -- SDK configuration and MCP tool interface
///
/// ## Directory conventions
///
/// - `dataDir`: the DartClaw instance root, typically `~/.dartclaw/`.
/// - `workspaceDir` / `workspaceRoot`: the user's active project working tree;
///   `workspaceRoot` is canonical for new code while some legacy parameters
///   keep the historical `workspaceDir` spelling.
/// - `projectDir`: the per-project clone under `$dataDir/projects/<id>/`.
library;

// Storage services
export 'src/storage/memory_service.dart' show MemoryIndexRow, MemoryService;
export 'src/storage/index_reconciler.dart'
    show CanonicalIndexReconciler, IndexHealthEvidence, IndexHealthState, IndexHealthStore, IndexReconcileResult;
export 'src/storage/search_db.dart' show SearchDbFactory, openSearchDb, openSearchDbInMemory;
export 'src/storage/sqlite_agent_execution_repository.dart' show SqliteAgentExecutionRepository;
export 'src/storage/sqlite_execution_repository_transactor.dart' show SqliteExecutionRepositoryTransactor;
export 'src/storage/sqlite_goal_repository.dart' show SqliteGoalRepository;
export 'src/storage/sqlite_task_repository.dart' show SqliteTaskRepository;
export 'src/storage/sqlite_workflow_step_execution_repository.dart' show SqliteWorkflowStepExecutionRepository;
export 'src/storage/task_db.dart' show TaskDbFactory, openTaskDb, openTaskDbInMemory;
export 'src/storage/turn_state_store.dart' show TurnStateStore;
export 'src/storage/webhook_delivery_store.dart'
    show WebhookDeliveryReservation, WebhookDeliveryStore, openWebhookDeliveryStore, openWebhookDeliveryStoreInMemory;
export 'src/storage/task_event_service.dart' show TaskEventService;
export 'src/storage/turn_trace_service.dart' show TurnTraceService, TraceQueryResult;
export 'src/storage/session_service.dart' show SessionService;
export 'src/storage/message_service.dart' show MessageService;
export 'src/storage/kv_service.dart' show KvService;
export 'src/storage/atomic_write.dart'
    show
        atomicWriteJson,
        secureWriteFile,
        secureWriteFileSync,
        chmodOwnerOnly,
        chmodOwnerOnlySync,
        chmodOwnerOnlyDirSync;
export 'src/storage/login_store_guard.dart' show LoginStoreCollisionError;
export 'src/storage/named_credential_store.dart' show NamedCredentialStore;
export 'src/storage/subscription_credential_store.dart' show SubscriptionCredentialStore;

// Search backends
export 'src/search/fts5_search_backend.dart' show Fts5SearchBackend;
export 'src/search/search_backend_factory.dart' show createSearchBackend;
export 'src/search/qmd_search_backend.dart' show QmdSearchBackend, SearchDepth;
export 'src/search/qmd_manager.dart' show QmdManager;
export 'src/search/wiki_search_source.dart' show WikiSearchSource, WikiSearchScan, knownWikiProvenance;
export 'src/search/composed_search_backend.dart' show ComposedSearchBackend, SearchIndexHealthProbe;

// Knowledge persistence
export 'src/knowledge/known_systems.dart' show normalizeKnowledgeEntity;
export 'src/knowledge/temporal_knowledge_graph_service.dart'
    show TemporalKnowledgeGraphService, KnowledgeFact, KnowledgeContradiction;

// Memory persistence
export 'src/memory/memory_pruner.dart' show MemoryPruner, PruneResult;
export 'src/memory/memory_preflight.dart'
    show MemoryPreflightStatus, MemoryPreflightResult, MemoryPreflightException, MemoryPreflight;

// Bridge events (sealed — subtypes accessible via pattern matching)
export 'src/bridge/bridge_events.dart'
    show
        BridgeEvent,
        DeltaEvent,
        ToolUseEvent,
        ToolResultEvent,
        ToolApprovalWaitEvent,
        ToolApprovalResolvedEvent,
        ProviderProgressBridgeEvent,
        SystemInitEvent,
        CompactionStartingBridgeEvent,
        CompactionCompletedBridgeEvent;

// Channel interfaces
export 'src/channel/channel.dart' show Channel, ChannelMessage, ChannelResponse, sourceMessageIdMetadataKey;
export 'src/channel/channel_feedback.dart'
    show ChannelFeedbackStrategy, FeedbackContext, NoFeedbackStrategy, TurnProgressSnapshot;
export 'src/channel/channel_manager.dart' show ChannelManager;
export 'src/channel/channel_task_bridge.dart' show ChannelTaskBridge, ReservedCommandDispatch;
export 'src/channel/recipient_resolver.dart' show resolveRecipientId;
export 'src/channel/inbound_gate.dart' show ChannelInboundDecision, ChannelInboundGate, MentionGating;
export 'src/channel/message_queue.dart' show BudgetExhaustedError, MessageQueue, TurnDispatcher, TurnObserver;
export 'src/channel/channel_review.dart'
    show
        ChannelReviewResult,
        ChannelReviewSuccess,
        ChannelReviewMergeConflict,
        ChannelReviewError,
        ChannelReviewHandler;
export 'src/channel/task_origin.dart' show TaskOrigin;
export 'src/channel/text_chunking.dart' show TextChunkSlice, chunkNativeChatMarkup, chunkText, chunkTextSlices;
export 'src/channel/standard_markdown_converter.dart' show convertStandardMarkdownToNativeChatMarkup;
export 'src/channel/typing_lease_tracker.dart' show TypingLeaseTracker, TypingTransport;
export 'src/channel/turn_progress_event.dart'
    show
        TurnProgressEvent,
        ToolStartedProgressEvent,
        ToolCompletedProgressEvent,
        TextDeltaProgressEvent,
        ProviderProgressEvent,
        StatusTickProgressEvent,
        TurnStallProgressEvent;
export 'src/channel/message_deduplicator.dart' show MessageDeduplicator;
export 'src/channel/thread_binding.dart' show ThreadBinding, ThreadBindingStore, extractThreadId, supportsThreadBinding;
export 'src/channel/thread_binding_lifecycle_manager.dart' show ThreadBindingLifecycleManager;
export 'src/channel/sidecar_process_manager.dart' show SidecarProcessManager;

// Shared channel DM access
export 'src/channel/dm_access.dart' show DmAccessMode, DmAccessController, PairingCode;

// Harness interfaces
export 'src/harness/agent_harness.dart'
    show
        AgentHarness,
        ContextualMemoryToolHandler,
        HarnessTurnContext,
        HarnessTurnContextSink,
        PromptStrategy,
        TurnResult,
        UnsupportedHarnessCapabilityException;
export 'src/harness/provider_execution_compatibility.dart'
    show
        ProviderCredentialGate,
        ProviderExecutionInventory,
        ProviderExecutionSupport,
        ProviderExecutionVerdict,
        ProviderUnavailability;
export 'src/harness/base_protocol_adapter.dart' show intValue, stringValue;
export 'src/harness/claude_settings_builder.dart' show ClaudeSettingsBuilder;
export 'src/harness/conversation_history.dart' show buildReplaySafeHistory;
export 'src/harness/canonical_tool.dart' show CanonicalTool, dartclawMcpServerName;
export 'src/harness/claude_code_harness.dart' show ClaudeCodeHarness;
export 'src/harness/claude_protocol_adapter.dart' show ClaudeProtocolAdapter;
export 'src/harness/codex_config_generator.dart' show CodexConfigGenerator;
export 'src/harness/codex_environment.dart' show CodexEnvironment, completeDedicatedCodexHome;
export 'src/harness/codex_harness.dart' show CodexHarness;
export 'src/harness/codex_protocol_adapter.dart' show CodexProtocolAdapter;
export 'src/harness/codex_settings.dart' show CodexSettings;
export 'src/harness/harness_launch_options.dart' show HarnessLaunchOptions;
export 'src/harness/harness_factory.dart' show HarnessFactory, HarnessFactoryConfig;
export 'src/harness/harness_registrar.dart' show HarnessRegistrar, HarnessRegistration;
export 'src/harness/merge_resolve_env_vars.dart'
    show
        mergeResolveIntegrationBranchEnvVar,
        mergeResolveStoryBranchEnvVar,
        mergeResolveTokenCeilingEnvVar,
        mergeResolveEnvVarNames;
export 'src/harness/mcp_tool.dart' show McpTool, McpToolAccess;
export 'src/harness/claude_protocol.dart'
    show
        claudeContainerHardeningEnvVars,
        claudeHardeningEnvVars,
        claudeOauthTokenEnvVar,
        containerClaudePlaceholderApiKey;
export 'src/harness/process_lifecycle.dart'
    show
        ProcessOutputLimitException,
        ProcessLifecycleOwner,
        ProcessStreamException,
        ProcessTerminationResult,
        SequentialLock,
        defaultProcessOutputLimitBytes,
        killWithEscalation;
export 'src/harness/process_types.dart' show ProcessFactory, CommandProbe, DelayFactory, HealthProbe;
export 'src/harness/protocol_adapter.dart' show ProtocolAdapter;
// Protocol message boundary. The MCP tool-return `ToolResult` is a different
// type, owned by `tool_result.dart`; the protocol-stream one is
// `ToolResultMessage`.
export 'src/harness/protocol_message.dart'
    show
        ProtocolMessage,
        TextDelta,
        ToolUse,
        ToolResultMessage,
        ControlRequest,
        TurnComplete,
        ProgressMessage,
        SessionMetadataUpdate,
        ProtocolDiagnostic,
        SystemInit,
        CompactBoundary,
        CompactionStarted,
        CompactionCompleted;
export 'src/harness/tool_policy.dart' show ToolApprovalPolicy;
export 'src/harness/tool_result.dart' show ToolResult, ToolResultError, ToolResultText;

export 'src/memory/memory_file_service.dart' show MemoryFileService;
export 'src/memory/memory_resource_limits.dart' show MemoryResourceLimits, MemoryResourceLimitException;
export 'src/memory/memory_entry.dart' show MemoryEntry;
export 'src/memory/memory_entry_parser.dart' show parseMemoryEntries;
export 'src/memory/canonical_memory.dart'
    show
        canonicalMemoryFormatVersion,
        validateMemoryTopic,
        MemoryRole,
        MemoryOriginKind,
        MemorySourceRef,
        MemoryCollectionMetadata,
        CanonicalMemoryEntry,
        CanonicalMemoryLearning,
        CanonicalMemoryError,
        MemoryIndexEntry,
        MemoryObservation,
        MemoryDeletionAudit;
export 'src/memory/memory_documents.dart'
    show
        CanonicalMemoryDocument,
        MemoryIndexDocument,
        MemoryTopicDocument,
        MemoryArchiveDocument,
        MemoryObservationDocument,
        MemoryLearningDocument,
        MemoryErrorDocument,
        MemoryAuditDocument;
export 'src/memory/memory_markdown_codec.dart' show MemoryMarkdownCodec, canonicalMemoryHeader;
export 'src/memory/memory_corpus.dart'
    show VerbatimMemoryMember, CanonicalMemoryCorpus, MemoryCorpusValidationException, MemoryCorpusValidator;
export 'src/memory/memory_apply_schema.dart' show memoryApplyOperationSchema;
export 'src/memory/memory_corpus_service.dart'
    show
        MemorySnapshotOmissionReason,
        MemoryCorpusSnapshot,
        MemoryCurationSnapshot,
        MemoryCorpusSelection,
        MemoryCorpusManifest,
        MemoryCorpusStatusSnapshot,
        MemoryCorpusChange,
        MemoryCorpusFileMutation,
        MemoryCorpusMutation,
        MemoryCorpusSimulatedCrash,
        MemoryCorpusService;

export 'src/container/container_executor.dart'
    show
        ContainerExecutor,
        containerClaudeExecutable,
        containerCodexExecutable,
        containerExecutableRuns,
        containerGeneratedStatePath,
        containerImageUidGid;
export 'src/scoping/common_channel_fields.dart' show CommonChannelFields;
export 'src/scoping/group_config_resolver.dart' show GroupConfigResolver;
export 'src/scoping/group_entry.dart' show GroupEntry;
export 'src/scoping/live_scope_config.dart' show LiveScopeConfig;

// Agents
export 'src/agents/logical_agent_session_service.dart' show LogicalAgentSessionService;
export 'src/agents/tool_policy_cascade.dart' show ToolPolicyCascade, ToolPolicyGuard;

// Tasks
export 'src/task/goal.dart' show Goal;
export 'src/task/goal_repository.dart' show GoalRepository;
export 'src/task/task.dart' show Task, TaskLegacyRefusal;
export 'src/task/task_artifact.dart' show ArtifactKind, TaskArtifact;
export 'src/task/task_event.dart' show TaskEvent, TaskEventKind;
export 'src/task/task_repository.dart' show TaskRepository;
// Turn
export 'src/turn/tool_call_record.dart' show ToolCallRecord;
export 'src/turn/turn_trace.dart' show TurnTrace, computeEffectiveTokens;
export 'src/turn/turn_trace_summary.dart' show TurnTraceSummary;
export 'src/task/task_status.dart' show TaskStatus;
export 'src/task/workflow_task_service.dart' show WorkflowTaskService;
// Concurrency
export 'src/concurrency/repo_lock.dart' show RepoLock;

// Project service interface
export 'src/project/project_service.dart' show ProjectService;

// Utilities (single sub-barrel — keeps the top-level export surface compact)
export 'src/util/util.dart'
    show
        formatLocalDateTime,
        tryParseIsoInstant,
        splitFrontmatter,
        humanizeDuration,
        humanizeDurationMs,
        humanizeSpan,
        HttpClientFactory,
        httpRequest;

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
        CredentialHealthChangedEvent,
        CredentialHealthState,
        RunnerLifecycleEvent,
        RunnerStateChangedEvent,
        LoopDetectedEvent,
        EmergencyStopEvent,
        OutboundMcpGovernanceEvent,
        ContextResearchMetricsEvent,
        ProjectLifecycleEvent,
        ProjectStatusChangedEvent,
        TurnWaitStateChangedEvent,
        TurnWaitState,
        TurnWaitReason,
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
        WorkflowCliStallEvent,
        WorkflowCliTurnProgressEvent,
        WorkflowRunStatusChangedEvent,
        WorkflowStepCompletedEvent,
        CompactionLifecycleEvent,
        CompactionStartingEvent,
        CompactionCompletedEvent,
        ScheduledJobFailedEvent;

export 'src/worker/worker_state.dart' show WorkerState;

// Turn abstractions (interfaces + value types)
export 'src/turn/busy_turn_exception.dart' show BusyTurnException;
export 'src/turn/turn_manager.dart' show TurnManager;
export 'src/turn/turn_outcome.dart' show TurnLimitBreach, TurnOutcome;
export 'src/turn/turn_runner.dart' show TurnRunner;
export 'src/turn/turn_status.dart' show TurnStatus;

// Auth abstractions
export 'src/auth/google_jwt_verifier.dart' show GoogleJwtVerifier;
