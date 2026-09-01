/// Unified workflow parsing, registry, validation, and execution utilities.
library;

export 'src/generated/embedded_assets.g.dart' show embeddedWorkflowAssets;

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
        WorkflowApprovalRequestedEvent,
        WorkflowApprovalResolvedEvent,
        WorkflowBudgetWarningEvent,
        WorkflowLifecycleEvent,
        WorkflowRunStatusChangedEvent,
        WorkflowStepCompletedEvent,
        WorkflowTaskService,
        atomicWriteJson;

export 'src/workflow/workflow_definition.dart'
    show
        ActionNode,
        ForeachNode,
        LoopNode,
        MergeResolveConfig,
        MergeResolveEscalation,
        OnErrorPolicy,
        OnFailurePolicy,
        OutputConfig,
        OutputFormat,
        OutputMode,
        ParallelGroupNode,
        StepConfigDefault,
        WorkflowDefinition,
        WorkflowGitArtifactsStrategy,
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
export 'src/workflow/workflow_asset_source_resolver.dart' show WorkflowAssetSourceResolver;
export 'src/workflow/workflow_materializer.dart' show WorkflowMaterializer;
export 'src/workflow/workflow_run_repository.dart' show WorkflowRunRepository;
export 'src/storage/sqlite_workflow_run_repository.dart' show SqliteWorkflowRunRepository;

export 'package:dartclaw_kernel/dartclaw_kernel.dart' show WorkflowStepExecutionRepository;

export 'src/workflow/workflow_runtime_artifacts_pruner.dart'
    show RuntimeArtifactsPruneAction, RuntimeArtifactsPruneReport, WorkflowRuntimeArtifactsPruner;
export 'src/workflow/workflow_task_binding_coordinator.dart' show WorkflowTaskBindingCoordinator;

export 'src/workflow/context_extractor.dart' show ContextExtractor, StructuredOutputFallbackRecorder;
export 'src/workflow/gate_evaluator.dart' show GateEvaluator, GateUnproducedOutputFailure;
export 'src/workflow/map_context.dart' show MapContext;
export 'src/workflow/missing_artifact_failure.dart' show MissingArtifactFailure;
export 'src/workflow/output_resolver.dart' show FileSystemOutput, InlineOutput, OutputResolver;
export 'src/workflow/produced_artifact_resolver.dart'
    show
        ProducedArtifactResolver,
        ProducedArtifacts,
        StorySpecPathResolution,
        resolveStorySpecPathAgainstPlanDir,
        resolveStorySpecPaths;
export 'src/workflow/execution_envelope_schema.dart' show buildFinalizerPrompt;
export 'src/workflow/prompt_augmenter.dart' show PromptAugmenter;
export 'src/workflow/schema_presets.dart'
    show
        SchemaPreset,
        defaultOutputResolverFor,
        diffSummaryPreset,
        findingsCountPreset,
        gatingFindingsCountPreset,
        narrativeTextPreset,
        nonNegativeIntegerPreset,
        outputResolverFor,
        reviewReportPathPreset,
        schemaPresets,
        storySpecsPreset,
        validationSummaryPreset,
        verdictPreset;
export 'src/workflow/schema_validator.dart' show SchemaValidator;
export 'src/skills/cli_skill_introspector.dart'
    show CliSkillIntrospector, SkillProbeEnvironmentBuilder, SkillProbeRunner;
export 'src/skills/provider_auth_preflight.dart'
    show
        AuthProbeEnvironmentBuilder,
        AuthProbeRunner,
        CliProviderAuthPreflight,
        ProviderAuthPreflight,
        ProviderAuthResult;
export 'src/workflow/skill_introspector.dart'
    show SkillIntrospector, WorkflowPreflightException, WorkflowSkillPreflightConfig, skillIntrospectionPrompt;
export 'src/workflow/workflow_skill_preflight.dart'
    show WorkflowSkillCheckResult, WorkflowSkillCheckWarning, checkWorkflowSkillRefs;
export 'src/workflow/skill_prompt_builder.dart' show SkillPromptBuilder;
export 'src/workflow/step_config_resolver.dart'
    show
        ResolvedStepConfig,
        WorkflowRoleDefault,
        WorkflowRoleDefaults,
        globMatchStepId,
        resolveStepConfig,
        syntheticWorkflowSkillSteps; // retained: consumed by CLI validation/wiring and workflow barrel tests
export 'src/workflow/workflow_context.dart' show WorkflowContext, unproducedKeysSystemPrefix;
export 'src/workflow/workflow_definition_parser.dart' show WorkflowDefinitionParser;
export 'src/workflow/workflow_definition_resolver.dart' show WorkflowDefinitionResolver;
export 'src/workflow/workflow_definition_source.dart'
    show WorkflowDefinitionSource, WorkflowSummary; // retained: injected as host-facing definition lookup seam
export 'src/workflow/workflow_definition_validator.dart'
    show WorkflowValidationError, WorkflowValidationErrorType, ValidationReport, WorkflowDefinitionValidator;
export 'src/workflow/merge_resolve_attempt_artifact.dart' show MergeResolveAttemptArtifact;
export 'src/workflow/workflow_executor.dart' show WorkflowExecutor;
export 'src/workflow/workflow_git_port.dart'
    show
        GitStatus,
        WorkflowGitCommit,
        WorkflowGitException,
        WorkflowGitMergeStrategy,
        WorkflowGitPort,
        resolveIntegrationBranchName;
export 'src/workflow/workflow_output_contract.dart'
    show
        StepOutcomePayload,
        executionEnvelopeMarkerKey,
        executionEnvelopeOutputsKey,
        executionEnvelopeStepOutcomeKey,
        executionEnvelopeVersion,
        executionEnvelopeDeclaredOutputKeys,
        isExecutionEnvelope,
        reservedEnvelopeOutputKeys,
        stepOutcomeClose,
        stepOutcomeOpen,
        stepOutcomeTag,
        parseStepOutcomePayload,
        stepOutcomeRegExp;
export 'src/workflow/workflow_registry.dart' show WorkflowExclusion, WorkflowRegistry, WorkflowSource;
export 'src/workflow/bash_process_owner.dart' show BashProcessOwner;
export 'src/workflow/workflow_failure.dart'
    show
        WorkflowEscalatedHardFailure,
        WorkflowFailure,
        WorkflowForeachControllerFailure,
        WorkflowIterationBlockedHold,
        WorkflowIterationCancelled,
        WorkflowIterationFailure,
        WorkflowLegacyIterationStateFailure,
        WorkflowModelDeclaredFailure,
        WorkflowOutputValidationFailure,
        WorkflowPromotionConflictFailure,
        WorkflowPromotionFailure,
        WorkflowSerializeRemainingSettleTimeout,
        WorkflowStepRetryFailure,
        WorkflowTaskTerminalStatusFailure,
        workflowFailureFromPersisted,
        workflowFailureKinds;
export 'src/workflow/workflow_runner_types.dart'
    show
        BashStepPolicy,
        ExecutableLookupExecutor,
        ExecutableLookupResult,
        MapStepResult,
        StepExecutionContext,
        StepOutcome,
        StepPromptConfiguration,
        StepValidationFailure,
        StorySpecOutputValidation,
        isSupportedWorkflowRunnerNode;
export 'src/workflow/workflow_task_config.dart' show WorkflowTaskConfig;
export 'src/workflow/workflow_service.dart'
    show WorkflowService, missingRequiredWorkflowVariables, missingRequiredWorkflowVariablesMessage;
export 'src/workflow/workflow_service_deps.dart'
    show WorkflowGitContext, WorkflowPersistencePorts, WorkflowServiceOptions;
export 'src/workflow/workflow_turn_adapter.dart'
    show
        WorkflowExecuteTurn,
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
        workflowBlockedOutcomeSummary,
        workflowCanApprove,
        workflowCanReject,
        workflowCanResume,
        workflowCanRetry,
        workflowStatusBadgeClass,
        workflowStatusLabel;

export 'src/skills/skill_provisioner.dart'
    show
        DirectoryCopier,
        ProcessRunner,
        SkillProvisionConfigException,
        SkillProvisionException,
        SkillProvisioner,
        skillProvisionerMarkerFile;
export 'src/skills/workspace_skill_linker.dart'
    show
        WorkspaceDirectoryCopier,
        WorkspaceGitDirResolver,
        WorkspaceLinkFactory,
        WorkspaceSkillInventory,
        WorkspaceSkillLinker;
