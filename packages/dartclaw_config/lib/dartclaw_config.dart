/// Shared configuration metadata, validation, and authoring utilities for DartClaw.
library;

export 'package:dartclaw_models/dartclaw_models.dart';

export 'src/advisor_config.dart' show AdvisorConfig;
export 'src/agent_config.dart' show AgentConfig;
export 'src/alerts_config.dart' show AlertsConfig, AlertTarget;
export 'src/auth_config.dart' show AuthConfig;
export 'src/canvas_config.dart' show CanvasConfig, CanvasShareConfig, CanvasWorkshopConfig;
export 'src/config_delta.dart' show ConfigDelta;
export 'src/config_notifier.dart' show ConfigNotifier;
export 'src/config_meta.dart' show ConfigMeta, ConfigMutability, ConfigFieldType, FieldMeta;
export 'src/config_validator.dart' show ConfigValidator, ValidationError;
export 'src/config_writer.dart' show ConfigWriter;
export 'src/context_config.dart' show ContextConfig;
export 'src/credential_registry.dart' show CredentialRegistry;
export 'src/credentials_config.dart' show CredentialsConfig, CredentialEntry, CredentialType;
export 'src/dartclaw_config.dart' show DartclawConfig;
export 'src/duration_parser.dart' show tryParseDuration;
export 'src/features_config.dart' show FeaturesConfig, ThreadBindingFeatureConfig;
export 'src/gateway_config.dart' show GatewayConfig, ReloadConfig;
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
        TurnProgressConfig,
        TurnProgressAction,
        LoopDetectionConfig,
        LoopAction;
export 'src/history_config.dart' show HistoryConfig;
export 'src/logging_config.dart' show LoggingConfig;
export 'src/memory_config.dart' show MemoryConfig;
export 'src/project_config.dart' show ProjectConfig, ProjectDefinition, parseProjectConfig;
export 'src/provider_identity.dart' show ProviderIdentity;
export 'src/provider_validator.dart' show ProviderValidator, processOutputToText, extractVersionLine;
export 'src/providers_config.dart' show ProviderEntry, ProvidersConfig;
export 'src/reconfigurable.dart' show Reconfigurable;
export 'src/scheduled_task_definition.dart' show ScheduledTaskDefinition;
export 'src/scheduling_config.dart' show SchedulingConfig;
export 'src/search_config.dart' show SearchConfig, SearchProviderEntry;
export 'src/security_config.dart' show SecurityConfig;
export 'src/server_config.dart' show ServerConfig;
export 'src/session_config.dart' show SessionConfig;
export 'src/session_maintenance_config.dart' show SessionMaintenanceConfig, MaintenanceMode;
export 'src/task_config.dart' show TaskBudgetConfig, TaskConfig;
export 'src/usage_config.dart' show UsageConfig;
export 'src/workflow_config.dart'
    show WorkflowConfig, WorkflowRoleDefaultsConfig, WorkflowRoleModelConfig, parseWorkflowConfig;
export 'src/workspace_config.dart' show WorkspaceConfig;
export 'src/path_utils.dart' show expandHome;
