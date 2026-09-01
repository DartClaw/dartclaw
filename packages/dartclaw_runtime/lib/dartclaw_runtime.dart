/// HTTP server, API routes, and web UI for DartClaw.
///
/// Provides the shelf-based HTTP server ([DartclawServer]), turn management
/// ([TurnManager]), MCP protocol handler ([McpProtocolHandler]), and all
/// API/web routes. This is the composition layer -- it depends on
/// `dartclaw_core` for runtime abstractions and persistence.
///
/// Not intended for direct SDK use. Consumers should use the `dartclaw`
/// umbrella package or `dartclaw_core` for the harness interface.
library;

export 'package:dartclaw_core/dartclaw_core.dart' show BusyTurnException, TurnOutcome, TurnStatus, WorkerState;

export 'src/execution_coordinator.dart'
    show
        AdmitExecution,
        CreateExecutionWorker,
        DestroyContainerAuthority,
        ExecutionAdmission,
        ExecutionCoordinator,
        ExecutionEvent,
        ExecutionEventKind,
        ExecutionLane,
        ExecutionLease,
        ExecutionNow,
        ExecutionReleaseContext,
        ExecutionReleaseHook,
        ExecutionRequest,
        ExecutionSnapshot,
        ExecutionSurface,
        ProviderCapacitySnapshot,
        ReleaseExecutionAdmission,
        WorkerCreationException;
export 'src/execution_policy_resolver.dart' show ExecutionPolicyException, ExecutionPolicyResolver;
export 'src/security/security_exports.dart' show buildGuardsFromConfig;
export 'src/turn_manager.dart' show TurnManager;
export 'src/turn_runner.dart' show TurnRunner, TurnRunnerCancellation;

export 'src/api/api_exports.dart';
export 'src/alerts/alerts_exports.dart';
export 'src/audit/audit_exports.dart';
export 'src/auth/auth_exports.dart';
export 'src/behavior/behavior_exports.dart';
export 'src/config/config_exports.dart';
export 'src/context/context_exports.dart';
export 'src/container/container_exports.dart';
export 'src/governance/governance_exports.dart';
export 'src/health/health_exports.dart';
export 'src/host_exports.dart';
export 'src/knowledge/knowledge_exports.dart';
export 'src/logging/logging_exports.dart';
export 'src/mcp/mcp_exports.dart';
export 'src/memory/memory_exports.dart';
export 'src/project/project_exports.dart';
export 'src/scheduling/scheduling_exports.dart';
export 'src/session/session_exports.dart';
export 'src/task/task_exports.dart';
export 'src/ui_exports.dart';
