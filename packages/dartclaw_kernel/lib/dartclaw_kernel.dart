/// Shared data, configuration, guard, and utility contracts for DartClaw.
library;

export 'src/models.dart'
    show Session, SessionType, Message, MemorySearchResult, MemorySearchDegradation, MemorySearchOutcome;
export 'src/agent_definition.dart' show AgentDefinition;
export 'src/output_schema.dart'
    show OutputSchemaViolation, parseOutputSchema, renderOutputSchemaContract, validateOutputSchema;
export 'src/channel_config.dart' show ChannelConfig, GroupAccessMode, RetryPolicy;
export 'src/channel_type.dart' show ChannelType;
export 'src/container_config.dart' show ContainerConfig;
export 'src/execution_policy.dart' show ExecutionMode, ExecutionPolicy;
export 'src/session_key.dart' show SessionKey;
export 'src/session_scope_config.dart' show SessionScopeConfig, ChannelScopeConfig, DmScope, GroupScope;
export 'src/task_legacy_compatibility.dart'
    show
        MissingWorktreeDeclarationException,
        RetiredTaskTypeException,
        containerSecurityProfiles,
        retiredCodingTaskType,
        retiredCodingWorktreeMessage,
        retiredTaskCategoryRefusal,
        retiredResearchTaskType,
        retiredResearchTaskTypeMessage,
        taskTypeStoragePlaceholder;
export 'src/workflow_step_execution.dart' show WorkflowStepExecution;
export 'src/workflow_step_execution_repository.dart' show WorkflowStepExecutionRepository;

export 'src/guard.dart' show Guard, GuardChain, GuardContext, GuardVerdictCallback;
export 'src/guard_build_result.dart' show GuardBuildResult, GuardBuildSuccess, GuardBuildFailure;
export 'src/guard_verdict.dart' show GuardVerdict, GuardPass, GuardWarn, GuardBlock;
export 'src/git_ref.dart' show normalizeGitRefOperand, validateGitRefOperand;
export 'src/guard_config.dart' show GuardConfig;
export 'src/guard_audit.dart' show GuardAuditLogger, AuditEntry;
export 'src/command_guard.dart' show CommandGuard, CommandGuardConfig;
export 'src/glob_pattern.dart' show globToRegex;
export 'src/file_guard.dart' show FileAccessLevel, FileGuard, FileGuardConfig, FileGuardRule;
export 'src/network_guard.dart' show NetworkGuard, NetworkGuardConfig, isLoopbackHost;
export 'src/message_redactor.dart' show MessageRedactor;
export 'src/content_classifier.dart' show ContentClassifier;
export 'src/content_guard.dart' show ContentGuard, truncateUtf8Bytes;
export 'src/content_scan.dart' show ContentScan, ContentScanVerdict;
export 'src/anthropic_api_classifier.dart' show AnthropicApiClassifier;
export 'src/claude_binary_classifier.dart' show ClaudeBinaryClassifier;
export 'src/env_substitute.dart' show envReferences, envSubstitute;
export 'src/egress_guard.dart' show EgressGuard;
export 'src/process/git_runner.dart' show GitRunner, runGit;
export 'src/process/inline_process_environment_plan.dart'
    show EmptyProcessEnvironmentPlan, InlineProcessEnvironmentPlan;
export 'src/safe_process.dart'
    show
        EnvPolicy,
        ProcessEnvironmentPlan,
        SafeProcess,
        defaultBashStepEnvAllowlist,
        defaultGitEnvAllowlist,
        defaultSensitivePatterns;
export 'src/task_tool_filter_guard.dart' show TaskToolFilterGuard;

export 'src/agent_config.dart' show AgentConfig;
export 'src/alerts_config.dart' show AlertsConfig, AlertTarget;
export 'src/auth_config.dart' show AuthConfig;
export 'src/claude_provider_options.dart' show ClaudeProviderOptions;
export 'src/config_constraints.dart'
    show
        BlankString,
        ElementTypeMismatch,
        FieldConstraintViolation,
        FieldConstraints,
        NullNotAllowed,
        OutOfRange,
        TypeMismatch,
        ValueNotAllowed;
export 'src/config_delta.dart' show ConfigDelta;
export 'src/config_notifier.dart' show ConfigNotifier, ConfigReloadTier;
export 'src/config_meta.dart'
    show
        ConfigEntryShape,
        ConfigFieldType,
        ConfigMeta,
        ConfigMutability,
        EntryFieldMeta,
        FieldMeta,
        LegacyKeyMatch,
        ObjectEntry,
        OpaqueEntry,
        ToleratedLegacyKey,
        ValueEntry;
export 'src/config_validator.dart' show ConfigValidator, ValidationError, unknownConfigFieldMessage;
export 'src/config_writer.dart' show ConfigWriter;
export 'src/context_config.dart' show ContextConfig;
export 'src/credential_registry.dart'
    show
        CredentialMode,
        CredentialRegistry,
        CredentialResolution,
        CredentialUnavailableReason,
        credentialRemediationFor,
        credentialRenewalFor;
export 'src/credentials_config.dart' show CredentialEntry, CredentialExpiry, CredentialType, CredentialsConfig;
export 'src/dartclaw_config.dart' show ConfigPathSweep, DartclawConfig, validateExecutionPolicySelections;
export 'src/duration_parser.dart' show tryParseDuration;
export 'src/features_config.dart' show FeaturesConfig, ThreadBindingFeatureConfig;
export 'src/gateway_config.dart' show GatewayConfig, McpClientConfig, ReloadConfig;
export 'src/harness_config.dart' show HarnessConfig;
export 'src/github_config.dart'
    show GitHubWebhookConfig, GitHubWorkflowTrigger, ensureGitHubWebhookConfigRegistered, parseGitHubWebhookConfig;
export 'src/governance_config.dart'
    show
        CrowdCodingConfig,
        GovernanceConfig,
        RateLimitsConfig,
        PerSenderRateLimitConfig,
        GlobalRateLimitConfig,
        BudgetConfig,
        BudgetAction,
        QueueStrategy,
        TurnLimitsConfig,
        TurnProgressAction,
        LoopDetectionConfig,
        LoopAction;
export 'src/history_config.dart' show HistoryConfig;
export 'src/identifier_preservation_mode.dart' show IdentifierPreservationMode;
export 'src/knowledge_config.dart' show KnowledgeConfig, KnowledgeInboxConfig, KnowledgeWikiLintConfig;
export 'src/logging_config.dart' show LoggingConfig;
export 'src/memory_config.dart' show MemoryConfig;
export 'src/mcp_servers_config.dart'
    show McpNetworkClass, McpServerEntry, McpServerRateLimit, McpServerTokenBudget, McpServersConfig;
export 'src/onboarding_config.dart' show OnboardingConfig;
export 'src/platform_capabilities.dart'
    show BashShellPolicy, PlatformCapabilities, ProcessTerminationSemantics, UnsupportedCapabilityError;
export 'src/project_config.dart'
    show LocalProjectPathValidation, ProjectConfig, ProjectDefinition, parseProjectConfig, validateProjectLocalPath;
export 'src/provider_identity.dart' show ProviderIdentity;
export 'src/provider_validator.dart' show ProviderValidator, processOutputToText, extractVersionLine;
export 'src/providers_config.dart' show ProviderAuth, ProviderEntry, ProvidersConfig;
export 'src/reconfigurable.dart' show Reconfigurable;
export 'src/scheduled_task_definition.dart' show ScheduledTaskDefinition;
export 'src/scheduling_config.dart' show SchedulingConfig;
export 'src/search_config.dart' show SearchConfig, SearchProviderEntry;
export 'src/security_config.dart' show SecurityBashStepConfig, SecurityConfig;
export 'src/server_config.dart' show ServerConfig;
export 'src/session_config.dart' show SessionConfig;
export 'src/session_maintenance_config.dart' show SessionMaintenanceConfig, MaintenanceMode;
export 'src/task_config.dart' show TaskBudgetConfig, TaskConfig;
export 'src/usage_config.dart' show UsageConfig;
export 'src/workflow_config.dart'
    show
        WorkflowApprovalPolicy,
        WorkflowCleanupConfig,
        WorkflowConfig,
        WorkflowRoleDefaultsConfig,
        WorkflowRoleModelConfig,
        WorkflowRuntimeArtifactsRetentionConfig,
        parseWorkflowConfig;
export 'src/workspace_config.dart' show WorkspaceConfig;
export 'src/path_utils.dart' show expandHome;
export 'src/workflow_run_status.dart' show WorkflowRunStatus;
export 'src/yaml_type_safe_reader.dart' show readString, readInt, readBool, readStringList, readMap, readField;
export 'src/project_runtime.dart' show CloneStrategy, PrConfig, PrStrategy, Project, ProjectAuthStatus, ProjectStatus;
export 'src/agent_execution.dart' show AgentExecution;
export 'src/agent_execution_repository.dart' show AgentExecutionRepository;
export 'src/execution_repository_transactor.dart' show ExecutionRepositoryTransactor;
export 'src/loop_detection.dart' show LoopDetection, LoopDetectedException, LoopMechanism;
export 'src/loop_detector.dart' show LoopDetector;
export 'src/sliding_window_rate_limiter.dart' show SlidingWindowRateLimiter;
export 'src/prompt_scope.dart' show PromptScope;
export 'src/turn_origin.dart' show TurnOrigin;
export 'src/path_canonicalization.dart' show canonicalizePathWithExistingAncestors;
export 'src/string_util.dart' show truncate;
export 'src/http_request.dart' show HttpClientFactory, httpRequest;
export 'src/dynamic_reader.dart' show normalizeDynamicMap;
export 'src/search_backend.dart' show SearchBackend, SearchResultLayer;
export 'src/config_load_warnings.dart' show addConfigAdvisory;
