/// Unified workflow parsing, registry, validation, and execution utilities.
library;

export 'package:dartclaw_core/dartclaw_core.dart'
    show
        ArtifactKind,
        EventBus,
        KvService,
        LoopIterationCompletedEvent,
        MapIterationCompletedEvent,
        MapStepCompletedEvent,
        WorkflowSerializationEnactedEvent,
        MessageService,
        SessionService,
        ParallelGroupCompletedEvent,
        Task,
        TaskArtifact,
        TaskReviewReadyEvent,
        TaskStatus,
        TaskStatusChangedEvent,
        TaskType,
        WorkflowApprovalRequestedEvent,
        WorkflowApprovalResolvedEvent,
        WorkflowBudgetWarningEvent,
        WorkflowLifecycleEvent,
        WorkflowRunStatusChangedEvent,
        WorkflowStepCompletedEvent,
        WorkflowTaskService,
        atomicWriteJson;
export 'package:dartclaw_config/dartclaw_config.dart' show WorkflowRunStatus;
export 'package:dartclaw_models/dartclaw_models.dart';
export 'src/workflow/workflow_definition.dart'
    show
        ActionNode,
        ExtractionConfig,
        ExtractionType,
        ForeachNode,
        LoopNode,
        MapNode,
        MergeResolveConfig,
        MergeResolveEscalation,
        OnFailurePolicy,
        OutputConfig,
        OutputFormat,
        OutputMode,
        ParallelGroupNode,
        StepConfigDefault,
        WorkflowDefinition,
        WorkflowExternalArtifactMountMode,
        WorkflowGitArtifactsStrategy,
        WorkflowGitCleanupStrategy,
        WorkflowGitExternalArtifactMount,
        WorkflowGitPublishStrategy,
        WorkflowGitStrategy,
        WorkflowGitWorktreeStrategy,
        WorkflowLoop,
        WorkflowNode,
        WorkflowStep,
        WorkflowTaskType,
        WorkflowGitWorktreeMode,
        WorkflowVariable;
export 'src/workflow/workflow_run.dart'
    show WorkflowExecutionCursor, WorkflowExecutionCursorNodeType, WorkflowRun, WorkflowWorktreeBinding;
export 'src/workflow/workflow_run_repository.dart' show WorkflowRunRepository;
export 'src/workflow/workflow_task_binding_coordinator.dart' show WorkflowTaskBindingCoordinator;

export 'src/workflow/context_extractor.dart' show ContextExtractor, StructuredOutputFallbackRecorder;
export 'src/workflow/gate_evaluator.dart' show GateEvaluator;
export 'src/workflow/map_context.dart' show MapContext;
export 'src/workflow/missing_artifact_failure.dart' show MissingArtifactFailure;
export 'src/workflow/output_resolver.dart' show FileSystemOutput, InlineOutput, NarrativeOutput, OutputResolver;
export 'src/workflow/produced_artifact_resolver.dart'
    show
        ProducedArtifactResolver,
        ProducedArtifacts,
        StorySpecPathResolution,
        resolveStorySpecPathAgainstPlanDir,
        resolveStorySpecPaths;
export 'src/workflow/prompt_augmenter.dart' show PromptAugmenter;
export 'src/workflow/schema_presets.dart'
    show
        SchemaPreset,
        checklistPreset,
        defaultOutputResolverFor,
        detectedFisPathPreset,
        diffSummaryPreset,
        findingsCountPreset,
        fisPathPreset,
        fileListPreset,
        gatingFindingsCountPreset,
        nonNegativeIntegerPreset,
        outputResolverFor,
        planPathPreset,
        prdPathPreset,
        remediationResultPreset,
        remediationSummaryPreset,
        reviewReportPathPreset,
        schemaPresets,
        specConfidencePreset,
        specSourcePreset,
        stateUpdateSummaryPreset,
        storyPlanPreset,
        storyResultPreset,
        storySpecsPreset,
        validationSummaryPreset,
        verdictPreset;
export 'src/workflow/schema_validator.dart' show SchemaValidator;
export 'src/workflow/skill_prompt_builder.dart' show SkillPromptBuilder;
export 'src/workflow/skill_registry.dart' show ResolvedSkillRef, SkillRegistry;
export 'src/workflow/skill_registry_impl.dart'
    show SkillRegistryImpl; // retained: used by CLI/service wiring and server tests
export 'src/workflow/step_config_resolver.dart'
    show
        ResolvedStepConfig,
        WorkflowRoleDefault,
        WorkflowRoleDefaults,
        globMatchStepId,
        resolveStepConfig; // retained: consumed by CLI validation/wiring and workflow barrel tests
export 'src/workflow/workflow_context.dart' show WorkflowContext;
export 'src/workflow/workflow_definition_parser.dart' show WorkflowDefinitionParser;
export 'src/workflow/workflow_definition_resolver.dart' show WorkflowDefinitionResolver;
export 'src/workflow/workflow_definition_source.dart'
    show
        InMemoryDefinitionSource,
        WorkflowDefinitionSource,
        WorkflowSummary; // retained: injected as host-facing definition lookup seam
export 'src/workflow/workflow_definition_validator.dart'
    show ValidationError, ValidationErrorType, ValidationReport, WorkflowDefinitionValidator;
export 'src/workflow/merge_resolve_attempt_artifact.dart' show MergeResolveAttemptArtifact;
export 'src/workflow/workflow_executor.dart' show WorkflowExecutor, dispatchStep;
export 'src/workflow/workflow_git_port.dart'
    show GitStatus, WorkflowGitCommit, WorkflowGitException, WorkflowGitMergeStrategy, WorkflowGitPort;
export 'src/workflow/workflow_output_contract.dart'
    show
        StepOutcomePayload,
        stepOutcomeClose,
        stepOutcomeOpen,
        stepOutcomeTag,
        workflowContextClose,
        workflowContextOpen,
        workflowContextTag,
        parseStepOutcomePayload,
        stepOutcomeRegExp,
        workflowContextRegExp;
export 'src/workflow/workflow_registry.dart' show WorkflowExclusion, WorkflowRegistry, WorkflowSource;
export 'src/workflow/workflow_runner_types.dart'
    show
        BashStepPolicy,
        MapStepResult,
        StepExecutionContext,
        StepHandoff,
        StepHandoffRetrying,
        StepHandoffSuccess,
        StepHandoffValidationFailed,
        StepOutcome,
        StepPromptConfiguration,
        StepRetryState,
        StepTokenBreakdown,
        StepValidationFailure,
        StorySpecOutputValidation,
        WorkflowStepOutputTransformer,
        isSupportedWorkflowRunnerNode;
export 'src/workflow/workflow_task_config.dart' show WorkflowTaskConfig;
export 'src/workflow/workflow_service.dart' show WorkflowService;
export 'src/workflow/workflow_turn_adapter.dart'
    show
        WorkflowExecuteTurn,
        WorkflowGitBootstrapResult,
        WorkflowGitIntegrationBranchResult,
        WorkflowGitPromotionConflict,
        WorkflowGitPromotionError,
        WorkflowGitPromotionResult,
        WorkflowGitPromotionSerializeRemaining,
        WorkflowGitPromotionSuccess,
        WorkflowGitPublishResult,
        WorkflowPublishStatus,
        WorkflowStartResolution,
        WorkflowTurnAdapter,
        WorkflowTurnOutcome; // retained: host-injected workflow turn/git bridge seam
export 'src/workflow/workflow_view_helpers.dart'
    show
        buildLoopInfo,
        formatContextForDisplay,
        stepStatusFromTask,
        workflowCanApprove,
        workflowCanReject,
        workflowCanResume,
        workflowCanRetry,
        workflowStatusBadgeClass,
        workflowStatusLabel;

export 'src/skills/skill_info.dart' show SkillInfo, SkillSource;
export 'src/skills/skill_provisioner.dart'
    show
        DirectoryCopier,
        ProcessRunner,
        SkillProvisionConfigException,
        SkillProvisionException,
        SkillProvisioner,
        dcNativeSkillNames,
        skillProvisionerMarkerFile;
export 'src/skills/workspace_skill_linker.dart'
    show
        WorkspaceDirectoryCopier,
        WorkspaceGitDirResolver,
        WorkspaceLinkFactory,
        WorkspaceSkillInventory,
        WorkspaceSkillLinker;
