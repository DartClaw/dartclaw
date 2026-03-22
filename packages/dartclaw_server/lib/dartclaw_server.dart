/// HTTP server, API routes, and web UI for DartClaw.
///
/// Provides the shelf-based HTTP server ([DartclawServer]), turn management
/// ([TurnManager]), MCP protocol handler ([McpProtocolHandler]), and all
/// API/web routes. This is the composition layer -- it depends on
/// `dartclaw_core` for abstractions and `dartclaw_storage` for persistence.
///
/// Not intended for direct SDK use. Consumers should use the `dartclaw`
/// umbrella package or `dartclaw_core` for the harness interface.
library;

// API routes
export 'src/api/agent_routes.dart' show agentRoutes;
export 'src/api/config_api_routes.dart' show configApiRoutes, writeRestartPending, readRestartPending;
export 'src/api/config_routes.dart' show configRoutes;
export 'src/api/google_chat_space_events_wiring.dart' show GoogleChatSpaceEventsWiring;
export 'src/api/google_chat_subscription_routes.dart' show googleChatSubscriptionRoutes;
export 'src/api/google_chat_webhook.dart' show GoogleChatWebhookHandler, GoogleChatMessageDispatcher;
export 'src/api/goal_routes.dart' show goalRoutes;
export 'src/api/slash_command_handler.dart' show SlashCommandHandler;
export 'src/api/sse_broadcast.dart' show SseBroadcast;
export 'src/api/task_routes.dart' show taskRoutes;
export 'src/api/task_sse_routes.dart' show taskSseRoutes;

// Config
export 'package:dartclaw_config/dartclaw_config.dart';
export 'src/config/config_serializer.dart' show ConfigSerializer;
export 'src/config/config_change_subscriber.dart' show ConfigChangeSubscriber;
export 'src/api/session_routes.dart' show sessionRoutes;
export 'src/api/stream_handler.dart' show sseStreamResponse;
export 'src/api/webhook_routes.dart' show webhookRoutes;

// Auth
export 'src/auth/auth_middleware.dart' show authMiddleware;
export 'src/auth/auth_rate_limiter.dart' show AuthRateLimiter;
export 'src/auth/security_headers.dart' show securityHeadersMiddleware;
export 'src/auth/session_token.dart'
    show createSessionToken, validateSessionToken, sessionCookieHeader, sessionCookieName;
export 'src/auth/token_service.dart' show TokenService;
export 'src/security/google_jwt_verifier.dart' show GoogleJwtVerifier;

// Concurrency
export 'src/concurrency/session_lock_manager.dart' show SessionLockManager;

// Context
export 'src/context/context_monitor.dart' show ContextMonitor;
export 'src/context/exploration_summarizer.dart' show ExplorationSummarizer;
export 'src/context/result_trimmer.dart' show ResultTrimmer;

// Health
export 'src/health/health_route.dart' show healthHandler;
export 'src/health/health_service.dart' show HealthService;

// Logging
export 'src/logging/log_context.dart' show LogContext;
export 'src/logging/log_formatter.dart' show LogFormatter, HumanFormatter, JsonFormatter;
export 'src/logging/log_redactor.dart' show LogRedactor;
export 'src/logging/log_service.dart' show LogService;

// Memory
export 'src/api/memory_routes.dart' show memoryRoutes;
export 'src/memory/memory_status_service.dart' show MemoryStatusService, SearchIndexCounter;

// Memory handlers
export 'src/memory_handlers.dart' show createMemoryHandlers;

// Runtime config
export 'src/runtime_config.dart' show RuntimeConfig;

// Scheduling
export 'src/scheduling/cron_parser.dart' show CronExpression;
export 'src/scheduling/delivery.dart' show DeliveryMode, DeliveryService;
export 'src/scheduling/schedule_service.dart' show ScheduleService;
export 'src/scheduling/scheduled_job.dart' show ScheduleType, ScheduledJob, ScheduledJobType;
export 'src/scheduling/scheduled_task_runner.dart' show ScheduledTaskRunner;

// MCP
export 'src/mcp/mcp_router.dart' show mcpRoute;
export 'src/mcp/mcp_server.dart' show McpProtocolHandler;
export 'src/mcp/memory_tools.dart' show MemoryHandler, MemorySaveTool, MemorySearchTool, MemoryReadTool;
export 'src/mcp/sessions_send_tool.dart' show SessionsSendTool;
export 'src/mcp/sessions_spawn_tool.dart' show SessionsSpawnTool;
export 'src/mcp/web_fetch_tool.dart' show WebFetchTool;
export 'src/mcp/search_provider.dart' show SearchProvider, SearchResult;
export 'src/mcp/brave_search_tool.dart' show BraveSearchProvider, BraveSearchTool;
export 'src/mcp/tavily_search_tool.dart' show TavilySearchProvider, TavilySearchTool;

// Params
export 'src/params/display_params.dart'
    show
        AppDisplayParams,
        ContentGuardDisplayParams,
        HeartbeatDisplayParams,
        SchedulingDisplayParams,
        WorkspaceDisplayParams;

// Audit
export 'src/audit/audit_log_reader.dart' show AuditLogReader, AuditPage;
export 'src/audit/guard_audit_subscriber.dart' show GuardAuditSubscriber;

// Behavior
export 'src/behavior/behavior_file_service.dart' show BehaviorFileService;
export 'src/behavior/heartbeat_scheduler.dart' show HeartbeatScheduler;
export 'src/behavior/memory_consolidator.dart' show MemoryConsolidator;
export 'src/behavior/self_improvement_service.dart' show SelfImprovementService;

// Maintenance
export 'src/maintenance/session_maintenance_service.dart' show SessionMaintenanceService, MaintenanceReport, MaintenanceAction;

// Governance
export 'src/governance/budget_enforcer.dart'
    show BudgetEnforcer, BudgetCheckResult, BudgetDecision, BudgetStatus;
export 'src/governance/budget_exhausted_exception.dart' show BudgetExhaustedException;
export 'src/governance/pause_controller.dart' show PauseController, QueueResult;

// Observability
export 'src/observability/usage_tracker.dart' show UsageTracker;

// Restart
export 'src/restart_service.dart' show RestartService;

// Server
export 'src/server.dart' show DartclawServer, DartclawServerBuilder;

// Emergency stop
export 'src/emergency/emergency_stop_handler.dart' show EmergencyStopHandler, EmergencyStopResult;

// Task execution
export 'src/task/agent_observer.dart' show AgentObserver, AgentMetrics, AgentState;
export 'src/task/artifact_collector.dart' show ArtifactCollector;
export 'src/task/container_task_failure_subscriber.dart' show ContainerTaskFailureSubscriber;
export 'src/task/diff_generator.dart' show DiffGenerator, DiffResult, DiffFileEntry, DiffHunk, DiffFileStatus;
export 'src/task/goal_service.dart' show GoalService;
export 'src/task/merge_executor.dart' show MergeExecutor, MergeResult, MergeSuccess, MergeConflict, MergeStrategy;
export 'src/task/task_executor.dart' show TaskExecutor;
export 'src/task/task_file_guard.dart' show TaskFileGuard;
export 'src/task/task_notification_subscriber.dart' show TaskNotificationSubscriber;
export 'src/task/task_review_service.dart'
    show
        TaskReviewService,
        PushBackFeedbackDelivery,
        ReviewResult,
        ReviewSuccess,
        ReviewMergeConflict,
        ReviewNotFound,
        ReviewInvalidTransition,
        ReviewInvalidRequest,
        ReviewActionFailed;
export 'src/task/task_service.dart' show TaskService;
export 'src/task/worktree_manager.dart' show WorktreeManager, WorktreeInfo, WorktreeException, GitNotFoundException;

// Session
export 'src/session/group_session_initializer.dart' show GroupSessionInitializer, ChannelGroupConfig;
export 'src/session/session_reset_service.dart' show SessionResetService;

// Templates
// Show clause review: formatUptime, formatBytes are template helpers used only
// within this package. initTemplates/resetTemplates are startup/test utilities.
// Retained because dartclaw_server is publish_to:none (not part of public SDK).
export 'src/templates/helpers.dart' show formatUptime, formatBytes;
export 'src/templates/loader.dart' show initTemplates, resetTemplates;

// Container health
export 'src/container/container_health_monitor.dart' show ContainerHealthMonitor;

// Workspace
export 'src/workspace/workspace_git_sync.dart' show WorkspaceGitSync;
export 'src/workspace/workspace_service.dart' show WorkspaceService, WorkspaceMigrationException;

// Harness pool
export 'src/harness_pool.dart' show HarnessPool;

// Turn runner
export 'src/turn_runner.dart' show TurnRunner;

// Turn manager
export 'src/turn_manager.dart' show TurnStatus, TurnContext, TurnOutcome, BusyTurnException, TurnManager;

// Version & startup
export 'src/version.dart' show dartclawVersion;
export 'src/startup_banner.dart' show startupBanner;

// Web routes
export 'src/web/dashboard_page.dart' show DashboardPage, PageContext;
export 'src/web/page_registry.dart' show PageRegistry;
export 'src/web/signal_pairing_routes.dart' show signalPairingRoutes;
export 'src/web/web_routes.dart' show webRoutes;
