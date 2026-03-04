import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:shelf_static/shelf_static.dart';

import 'api/config_routes.dart';
import 'api/session_routes.dart';
import 'api/webhook_routes.dart';
import 'auth/auth_middleware.dart';
import 'auth/security_headers.dart';
import 'auth/token_service.dart';
import 'concurrency/session_lock_manager.dart';
import 'context/context_monitor.dart';
import 'context/result_trimmer.dart';
import 'health/health_service.dart';
import 'mcp/mcp_router.dart';
import 'mcp/mcp_server.dart';
import 'runtime_config.dart';
import 'scheduling/schedule_service.dart';
import 'session/session_reset_service.dart';
import 'templates/error_page.dart';
import 'turn_manager.dart';
import 'web/signal_pairing_routes.dart';
import 'web/web_routes.dart';
import 'web/web_utils.dart';
import 'web/whatsapp_pairing.dart';

const _htmlHeaders = {'content-type': 'text/html; charset=utf-8'};

class DartclawServer {
  final SessionService _sessions;
  final MessageService _messages;
  final AgentHarness _worker;
  final TurnManager _turns;
  TurnManager get turns => _turns;
  final MemoryFileService? _memoryFile;
  final HealthService? _healthService;
  final TokenService? _tokenService;
  final SessionResetService? _resetService;
  final bool _authEnabled;
  final String _staticDir;
  final ChannelManager? _channelManager;
  final WhatsAppChannel? _whatsAppChannel;
  final SignalChannel? _signalChannel;
  final GuardChain? _guardChain;
  final String? _webhookSecret;
  final MessageRedactor? _redactor;
  final McpProtocolHandler _mcpHandler;
  final String? _gatewayToken;

  // Runtime toggle state + service references (injected after construction).
  RuntimeConfig? _runtimeConfig;
  HeartbeatScheduler? _heartbeat;
  ScheduleService? _scheduleService;
  WorkspaceGitSync? _gitSync;

  /// Inject runtime services for toggle control. Must be called after
  /// service creation in serve_command.dart.
  void setRuntimeServices({
    HeartbeatScheduler? heartbeat,
    ScheduleService? scheduleService,
    WorkspaceGitSync? gitSync,
    RuntimeConfig? runtimeConfig,
  }) {
    _heartbeat = heartbeat;
    _scheduleService = scheduleService;
    _gitSync = gitSync;
    _runtimeConfig = runtimeConfig;
  }

  // Config values forwarded to webRoutes for accurate page rendering.
  final bool _heartbeatEnabled;
  final int _heartbeatIntervalMinutes;
  final List<Map<String, dynamic>> _scheduledJobs;
  final String? _workspacePath;
  final bool _gitSyncEnabled;

  DartclawServer._(
    this._sessions,
    this._messages,
    this._worker,
    this._turns,
    this._memoryFile,
    this._healthService,
    this._tokenService,
    this._resetService,
    this._authEnabled,
    this._staticDir,
    this._channelManager,
    this._whatsAppChannel,
    this._signalChannel,
    this._guardChain,
    this._webhookSecret,
    this._redactor,
    this._mcpHandler,
    this._gatewayToken,
    this._heartbeatEnabled,
    this._heartbeatIntervalMinutes,
    this._scheduledJobs,
    this._workspacePath,
    this._gitSyncEnabled,
  );

  factory DartclawServer({
    required SessionService sessions,
    required MessageService messages,
    required AgentHarness worker,
    required String staticDir,
    required BehaviorFileService behavior,
    MemoryFileService? memoryFile,
    SessionService? sessionsForTurns,
    GuardChain? guardChain,
    KvService? kv,
    HealthService? healthService,
    TokenService? tokenService,
    SessionLockManager? lockManager,
    SessionResetService? resetService,
    ContextMonitor? contextMonitor,
    ResultTrimmer? resultTrimmer,
    ChannelManager? channelManager,
    WhatsAppChannel? whatsAppChannel,
    SignalChannel? signalChannel,
    String? webhookSecret,
    MessageRedactor? redactor,
    String? gatewayToken,
    SelfImprovementService? selfImprovement,
    UsageTracker? usageTracker,
    bool authEnabled = true,
    bool heartbeatEnabled = false,
    int heartbeatIntervalMinutes = 30,
    List<Map<String, dynamic>> scheduledJobs = const [],
    String? workspacePath,
    bool gitSyncEnabled = false,
  }) {
    return DartclawServer._(
      sessions,
      messages,
      worker,
      TurnManager(
        messages: messages,
        worker: worker,
        behavior: behavior,
        memoryFile: memoryFile,
        sessions: sessionsForTurns ?? sessions,
        kv: kv,
        guardChain: guardChain,
        lockManager: lockManager,
        resetService: resetService,
        contextMonitor: contextMonitor,
        resultTrimmer: resultTrimmer,
        redactor: redactor,
        selfImprovement: selfImprovement,
        usageTracker: usageTracker,
      ),
      memoryFile,
      healthService,
      tokenService,
      resetService,
      authEnabled,
      staticDir,
      channelManager,
      whatsAppChannel,
      signalChannel,
      guardChain,
      webhookSecret,
      redactor,
      McpProtocolHandler(),
      gatewayToken,
      heartbeatEnabled,
      heartbeatIntervalMinutes,
      scheduledJobs,
      workspacePath,
      gitSyncEnabled,
    );
  }

  /// Register an MCP tool. Must be called before the server starts handling requests.
  void registerTool(McpTool tool) => _mcpHandler.registerTool(tool);

  /// The MCP protocol handler, exposed for testing.
  McpProtocolHandler get mcpHandler => _mcpHandler;

  Future<void> shutdown() async {
    for (final sessionId in _turns.activeSessionIds.toList()) {
      await _turns.cancelTurn(sessionId);
    }
    await _channelManager?.dispose();
    await _worker.dispose();
    await _messages.dispose();
    await _memoryFile?.dispose();
  }

  Handler get handler {
    final router = Router();

    // Health endpoint (unauthenticated, before other routes).
    final hs = _healthService;
    if (hs != null) {
      router.get('/health', (Request request) async {
        final status = await hs.getStatus();
        return Response.ok(jsonEncode(status), headers: {'Content-Type': 'application/json'});
      });
    }

    // MCP endpoint (bearer token auth — before session auth middleware).
    final gt = _gatewayToken;
    if (gt != null) {
      router.post('/mcp', mcpRoute(_mcpHandler, gatewayToken: gt));
    }

    // Static files at /static/ prefix.
    final staticHandler = createStaticHandler(_staticDir, defaultDocument: null);
    router.mount('/static/', staticHandler);

    // Webhook routes (unauthenticated — before auth middleware).
    final webhookRouter = webhookRoutes(whatsApp: _whatsAppChannel, webhookSecret: _webhookSecret);
    router.mount('/', webhookRouter.call);

    // WhatsApp pairing page.
    final waChannel = _whatsAppChannel;
    final sigEnabled = _signalChannel != null;
    if (waChannel != null) {
      router.get('/whatsapp/pairing', (Request request) async {
        final sidebarData = await buildSidebarData(_sessions);
        final fragment = wantsFragment(request);
        try {
          final status = await waChannel.gowa.getStatus();
          if (status.isLoggedIn) {
            return Response.ok(
              whatsappPairingTemplate(
                isConnected: true,
                connectedPhone: status.deviceId,
                sidebarData: sidebarData,
                signalEnabled: sigEnabled,
                fragmentOnly: fragment,
              ),
              headers: _htmlHeaders,
            );
          }
          // GOWA reachable but not logged in — show QR
          final qrUrl = await waChannel.gowa.getLoginQr();
          return Response.ok(
            whatsappPairingTemplate(
              qrImageUrl: qrUrl,
              sidebarData: sidebarData,
              signalEnabled: sigEnabled,
              fragmentOnly: fragment,
            ),
            headers: _htmlHeaders,
          );
        } catch (e) {
          return Response.ok(
            whatsappPairingTemplate(
              error: 'Failed to check GOWA status: $e',
              sidebarData: sidebarData,
              signalEnabled: sigEnabled,
              fragmentOnly: fragment,
            ),
            headers: _htmlHeaders,
          );
        }
      });
    }

    // Signal pairing page + registration routes (extracted for testability).
    final sigChannel = _signalChannel;
    if (sigChannel != null) {
      final sigRouter = signalPairingRoutes(
        signalChannel: sigChannel,
        sessions: _sessions,
      );
      router.mount('/signal', sigRouter.call);
    }

    // Config toggle routes (must be before session routes to avoid path conflicts).
    final rc = _runtimeConfig;
    if (rc != null) {
      final cfgRouter = configRoutes(
        runtimeConfig: rc,
        heartbeat: _heartbeat,
        scheduleService: _scheduleService,
        gitSync: _gitSync,
        heartbeatIntervalMinutes: _heartbeatIntervalMinutes,
        scheduledJobs: _scheduledJobs,
      );
      router.mount('/', cfgRouter.call);
    }

    // API routes (prefixed /api/ — no collision with web routes).
    final sessionRouter = sessionRoutes(_sessions, _messages, _turns, _worker, resetService: _resetService, redactor: _redactor);
    router.mount('/', sessionRouter.call);

    // Web/HTML routes (/, /sessions/*, /login).
    final webRouter = webRoutes(
      _sessions,
      _messages,
      workerStateGetter: () => _worker.state,
      tokenService: _tokenService,
      gatewayToken: _gatewayToken,
      healthService: _healthService,
      whatsAppChannel: _whatsAppChannel,
      signalChannel: _signalChannel,
      guardChain: _guardChain,
      turns: _turns,
      runtimeConfig: _runtimeConfig,
      heartbeatEnabled: _heartbeatEnabled,
      heartbeatIntervalMinutes: _heartbeatIntervalMinutes,
      scheduledJobs: _scheduledJobs,
      workspacePath: _workspacePath,
      gitSyncEnabled: _gitSyncEnabled,
    );
    router.mount('/', webRouter.call);

    var pipeline = const Pipeline()
        .addMiddleware(logRequests(logger: _sanitizedLogger))
        .addMiddleware(securityHeadersMiddleware())
        .addMiddleware(_corsMiddleware());
    if (_tokenService != null && _gatewayToken != null) {
      pipeline = pipeline.addMiddleware(
        authMiddleware(tokenService: _tokenService, gatewayToken: _gatewayToken, enabled: _authEnabled),
      );
    }
    // Cascade: pass through to styled 404 when router finds no matching route.
    final cascade = Cascade()
        .add(router.call)
        .add(
          (_) => Response.notFound(
            errorPageTemplate(404, 'Page Not Found', 'The requested page does not exist.'),
            headers: _htmlHeaders,
          ),
        );
    return pipeline.addHandler(cascade.handler);
  }
}

/// Redacts sensitive query parameters (e.g. `secret`) from request log lines.
///
/// Shelf's default `logRequests()` logs the full URI including query strings,
/// which would expose webhook secrets in plaintext. This logger strips the
/// `secret` parameter value before logging.
void _sanitizedLogger(String msg, bool isError) {
  final sanitized = msg.replaceAll(RegExp(r'([?&])secret=[^&\s]*'), r'$1secret=REDACTED');
  if (isError) {
    stderr.writeln('[ERROR] $sanitized');
  } else {
    print(sanitized);
  }
}

final _localhostOrigin = RegExp(r'^http://(localhost|127\.0\.0\.1)(:\d+)?$');

Middleware _corsMiddleware() {
  return (Handler inner) => (Request request) async {
    final origin = request.headers['origin'] ?? '';
    final allowed = _localhostOrigin.hasMatch(origin);
    final corsOrigin = allowed ? origin : 'http://localhost';

    if (request.method == 'OPTIONS') {
      return Response.ok(
        '',
        headers: {
          'Access-Control-Allow-Origin': corsOrigin,
          'Access-Control-Allow-Methods': 'GET, POST, PATCH, DELETE, OPTIONS',
          'Access-Control-Allow-Headers': 'Content-Type, Authorization',
        },
      );
    }
    final response = await inner(request);
    return response.change(headers: {'Access-Control-Allow-Origin': corsOrigin});
  };
}
