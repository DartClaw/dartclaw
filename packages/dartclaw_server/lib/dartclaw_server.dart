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
export 'src/api/config_api_routes.dart'
    show configApiRoutes, writeRestartPending, readRestartPending;
export 'src/api/config_routes.dart' show configRoutes;
export 'src/api/sse_broadcast.dart' show SseBroadcast;

// Config
export 'src/config/config_meta.dart'
    show ConfigMeta, ConfigMutability, ConfigFieldType, FieldMeta;
export 'src/config/config_serializer.dart' show ConfigSerializer;
export 'src/config/config_validator.dart' show ConfigValidator, ValidationError;
export 'src/config/config_writer.dart' show ConfigWriter;
export 'src/api/session_routes.dart' show sessionRoutes;
export 'src/api/stream_handler.dart' show sseStreamResponse;
export 'src/api/webhook_routes.dart' show webhookRoutes;

// Auth
export 'src/auth/auth_middleware.dart' show authMiddleware;
export 'src/auth/security_headers.dart' show securityHeadersMiddleware;
export 'src/auth/session_token.dart'
    show createSessionToken, validateSessionToken, sessionCookieHeader, sessionCookieName;
export 'src/auth/token_service.dart' show TokenService;

// Concurrency
export 'src/concurrency/session_lock_manager.dart' show SessionLockManager;

// Context
export 'src/context/context_monitor.dart' show ContextMonitor;
export 'src/context/result_trimmer.dart' show ResultTrimmer;

// Health
export 'src/health/health_route.dart' show healthHandler;
export 'src/health/health_service.dart' show HealthService;

// Logging
export 'src/logging/log_context.dart' show LogContext;
export 'src/logging/log_formatter.dart'
    show LogFormatter, HumanFormatter, JsonFormatter;
export 'src/logging/log_redactor.dart' show LogRedactor;
export 'src/logging/log_service.dart' show LogService;

// Memory
export 'src/api/memory_routes.dart' show memoryRoutes;
export 'src/memory/memory_status_service.dart'
    show MemoryStatusService, SearchIndexCounter;

// Memory handlers
export 'src/memory_handlers.dart' show createMemoryHandlers;

// Runtime config
export 'src/runtime_config.dart' show RuntimeConfig;

// Scheduling
export 'src/scheduling/cron_parser.dart' show CronExpression;
export 'src/scheduling/delivery.dart' show DeliveryMode;
export 'src/scheduling/schedule_service.dart' show ScheduleService;
export 'src/scheduling/scheduled_job.dart' show ScheduleType, ScheduledJob;

// MCP
export 'src/mcp/mcp_router.dart' show mcpRoute;
export 'src/mcp/mcp_server.dart' show McpProtocolHandler;
export 'src/mcp/memory_tools.dart'
    show MemoryHandler, MemorySaveTool, MemorySearchTool, MemoryReadTool;
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

// Restart
export 'src/restart_service.dart' show RestartService;

// Server
export 'src/server.dart' show DartclawServer;

// Session
export 'src/session/session_reset_service.dart' show SessionResetService;

// Templates
// Show clause review: formatUptime, formatBytes are template helpers used only
// within this package. initTemplates/resetTemplates are startup/test utilities.
// Retained because dartclaw_server is publish_to:none (not part of public SDK).
export 'src/templates/helpers.dart' show formatUptime, formatBytes;
export 'src/templates/loader.dart' show initTemplates, resetTemplates;

// Turn manager
export 'src/turn_manager.dart'
    show TurnStatus, TurnContext, TurnOutcome, BusyTurnException, TurnManager;

// Version & startup
export 'src/version.dart' show dartclawVersion;
export 'src/startup_banner.dart' show startupBanner;

// Web routes
export 'src/web/signal_pairing_routes.dart' show signalPairingRoutes;
export 'src/web/web_routes.dart' show webRoutes;
