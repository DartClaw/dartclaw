import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_storage/dartclaw_storage.dart' show MemoryPruner;
import 'package:logging/logging.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:shelf_static/shelf_static.dart';

import 'api/agent_routes.dart';
import 'api/config_api_routes.dart';
import 'api/config_routes.dart';
import 'api/google_chat_webhook.dart';
import 'api/goal_routes.dart';
import 'api/memory_routes.dart';
import 'api/session_routes.dart';
import 'api/sse_broadcast.dart';
import 'api/task_routes.dart';
import 'api/task_sse_routes.dart';
import 'task/agent_observer.dart';
import 'task/merge_executor.dart';
import 'task/task_file_guard.dart';
import 'task/worktree_manager.dart';
import 'api/webhook_routes.dart';
import 'restart_service.dart';
import 'config/config_validator.dart';
import 'config/config_writer.dart';
import 'auth/auth_middleware.dart';
import 'auth/auth_rate_limiter.dart';
import 'auth/security_headers.dart';
import 'auth/token_service.dart';
import 'concurrency/session_lock_manager.dart';
import 'context/context_monitor.dart';
import 'context/result_trimmer.dart';
import 'health/health_service.dart';
import 'memory/memory_status_service.dart';
import 'mcp/mcp_router.dart';
import 'mcp/mcp_server.dart';
import 'runtime_config.dart';
import 'scheduling/schedule_service.dart';
import 'session/session_reset_service.dart';
import 'templates/error_page.dart';
import 'harness_pool.dart';
import 'turn_manager.dart';
import 'web/signal_pairing_routes.dart';
import 'web/dashboard_page.dart';
import 'web/page_registry.dart';
import 'web/system_pages.dart';
import 'web/web_routes.dart';
import 'web/web_utils.dart';
import 'params/display_params.dart';
import 'web/whatsapp_pairing.dart';
import 'audit/audit_log_reader.dart';

/// Shelf-based HTTP server composing all DartClaw routes and middleware.
class DartclawServer {
  final SessionService _sessions;
  final MessageService _messages;
  final AgentHarness _worker;
  final HarnessPool? _pool;
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
  final GoogleChatWebhookHandler? _googleChatWebhookHandler;
  final SignalChannel? _signalChannel;
  final GuardChain? _guardChain;
  final String? _webhookSecret;
  final MessageRedactor? _redactor;
  final McpProtocolHandler _mcpHandler;
  final String? _gatewayToken;
  final PageRegistry _pageRegistry = PageRegistry();
  final AuthRateLimiter _authRateLimiter = AuthRateLimiter();
  Handler? _builtHandler;
  Handler? _requestHandler;
  bool _dashboardPagesLocked = false;

  // Runtime toggle state + service references (injected after construction).
  RuntimeConfig? _runtimeConfig;
  HeartbeatScheduler? _heartbeat;
  ScheduleService? _scheduleService;
  WorkspaceGitSync? _gitSync;
  MemoryStatusService? _memoryStatusService;
  MemoryPruner? _memoryPruner;
  KvService? _kvService;
  ConfigWriter? _configWriter;
  DartclawConfig? _config;
  RestartService? _restartService;
  SseBroadcast? _sseBroadcast;
  EventBus? _eventBus;
  GoalService? _goalService;
  TaskService? _taskService;
  WorktreeManager? _worktreeManager;
  TaskFileGuard? _taskFileGuard;
  AgentObserver? _agentObserver;
  MergeExecutor? _mergeExecutor;
  String? _mergeStrategy;
  String? _baseRef;

  /// Inject runtime services for toggle control. Must be called after
  /// service creation in serve_command.dart.
  void setRuntimeServices({
    HeartbeatScheduler? heartbeat,
    ScheduleService? scheduleService,
    WorkspaceGitSync? gitSync,
    RuntimeConfig? runtimeConfig,
    MemoryStatusService? memoryStatusService,
    MemoryPruner? memoryPruner,
    KvService? kvService,
    ConfigWriter? configWriter,
    DartclawConfig? config,
    RestartService? restartService,
    SseBroadcast? sseBroadcast,
    EventBus? eventBus,
    GoalService? goalService,
    TaskService? taskService,
    WorktreeManager? worktreeManager,
    TaskFileGuard? taskFileGuard,
    AgentObserver? agentObserver,
    MergeExecutor? mergeExecutor,
    String? mergeStrategy,
    String? baseRef,
  }) {
    _heartbeat = heartbeat;
    _scheduleService = scheduleService;
    _gitSync = gitSync;
    _runtimeConfig = runtimeConfig;
    _memoryStatusService = memoryStatusService;
    _memoryPruner = memoryPruner;
    _kvService = kvService;
    _configWriter = configWriter;
    _config = config;
    _restartService = restartService;
    _sseBroadcast = sseBroadcast;
    _eventBus = eventBus;
    _goalService = goalService;
    _taskService = taskService;
    _worktreeManager = worktreeManager;
    _taskFileGuard = taskFileGuard;
    _agentObserver = agentObserver;
    _mergeExecutor = mergeExecutor;
    _mergeStrategy = mergeStrategy;
    _baseRef = baseRef;
  }

  // Config values forwarded to webRoutes for accurate page rendering.
  final ContentGuardDisplayParams _contentGuardDisplay;
  final HeartbeatDisplayParams _heartbeatDisplay;
  final SchedulingDisplayParams _schedulingDisplay;
  final WorkspaceDisplayParams _workspaceDisplay;
  final AppDisplayParams _appDisplay;

  DartclawServer._(
    this._sessions,
    this._messages,
    this._worker,
    this._pool,
    this._turns,
    this._memoryFile,
    this._healthService,
    this._tokenService,
    this._resetService,
    this._authEnabled,
    this._staticDir,
    this._channelManager,
    this._whatsAppChannel,
    this._googleChatWebhookHandler,
    this._signalChannel,
    this._guardChain,
    this._webhookSecret,
    this._redactor,
    this._mcpHandler,
    this._gatewayToken,
    this._contentGuardDisplay,
    this._heartbeatDisplay,
    this._schedulingDisplay,
    this._workspaceDisplay,
    this._appDisplay,
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
    GoogleChatWebhookHandler? googleChatWebhookHandler,
    SignalChannel? signalChannel,
    String? webhookSecret,
    MessageRedactor? redactor,
    String? gatewayToken,
    SelfImprovementService? selfImprovement,
    UsageTracker? usageTracker,
    bool authEnabled = true,
    HarnessPool? pool,
    ContentGuardDisplayParams contentGuardDisplay = const ContentGuardDisplayParams(),
    HeartbeatDisplayParams heartbeatDisplay = const HeartbeatDisplayParams(),
    SchedulingDisplayParams schedulingDisplay = const SchedulingDisplayParams(),
    WorkspaceDisplayParams workspaceDisplay = const WorkspaceDisplayParams(),
    AppDisplayParams appDisplay = const AppDisplayParams(),
  }) {
    final turns = pool != null
        ? TurnManager.fromPool(pool: pool)
        : TurnManager(
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
          );
    final server = DartclawServer._(
      sessions,
      messages,
      worker,
      pool,
      turns,
      memoryFile,
      healthService,
      tokenService,
      resetService,
      authEnabled,
      staticDir,
      channelManager,
      whatsAppChannel,
      googleChatWebhookHandler,
      signalChannel,
      guardChain,
      webhookSecret,
      redactor,
      McpProtocolHandler(),
      gatewayToken,
      contentGuardDisplay,
      heartbeatDisplay,
      schedulingDisplay,
      workspaceDisplay,
      appDisplay,
    );

    registerSystemDashboardPages(
      server._pageRegistry,
      healthService: healthService,
      workerStateGetter: () => worker.state,
      whatsAppChannel: whatsAppChannel,
      signalChannel: signalChannel,
      googleChatChannel: googleChatWebhookHandler?.channel,
      guardChain: guardChain,
      runtimeConfigGetter: () => server._runtimeConfig,
      memoryStatusServiceGetter: () => server._memoryStatusService,
      contentGuardDisplay: contentGuardDisplay,
      heartbeatDisplay: heartbeatDisplay,
      schedulingDisplay: schedulingDisplay,
      workspaceDisplay: workspaceDisplay,
      auditReader: appDisplay.dataDir != null ? AuditLogReader(dataDir: appDisplay.dataDir!) : null,
    );

    return server;
  }

  /// Register an MCP tool that will be exposed to agents via the MCP endpoint.
  ///
  /// Must be called before the server starts handling requests. Throws
  /// [StateError] if called after the first MCP request has been processed.
  ///
  /// Duplicate tool names are silently skipped (first registration wins) with
  /// a warning logged. Registered tools appear in the MCP `tools/list`
  /// response and are dispatched via `tools/call`.
  void registerTool(McpTool tool) => _mcpHandler.registerTool(tool);

  /// Register a dashboard page that will appear in the sidebar nav.
  ///
  /// Must be called before the server starts handling requests.
  void registerDashboardPage(DashboardPage page) {
    if (_dashboardPagesLocked) {
      throw StateError('Cannot register dashboard pages after the server has started handling requests');
    }
    _pageRegistry.register(page);
  }

  /// The MCP protocol handler, exposed for testing.
  McpProtocolHandler get mcpHandler => _mcpHandler;

  Future<void> shutdown() async {
    for (final sessionId in _turns.activeSessionIds.toList()) {
      await _turns.cancelTurn(sessionId);
    }
    await _sseBroadcast?.dispose();
    await _channelManager?.dispose();
    if (_pool != null) {
      await _pool.dispose();
    } else {
      await _worker.dispose();
    }
    await _messages.dispose();
    await _memoryFile?.dispose();
    await _configWriter?.dispose();
  }

  Handler get handler => _requestHandler ??= (Request request) {
    _builtHandler ??= () {
      _validateRuntimeServices();
      return _buildHandler();
    }();
    return _builtHandler!(request);
  };

  void _validateRuntimeServices() {
    if (_taskService != null) {
      if (_worktreeManager == null) {
        throw StateError('taskService requires worktreeManager');
      }
      if (_taskFileGuard == null) {
        throw StateError('taskService requires taskFileGuard');
      }
      if (_mergeExecutor == null) {
        throw StateError('taskService requires mergeExecutor');
      }
      if (_agentObserver == null) {
        throw StateError('taskService requires agentObserver');
      }
    }

    if (_configWriter != null) {
      if (_restartService == null) {
        throw StateError('configWriter requires restartService');
      }
      if (_sseBroadcast == null) {
        throw StateError('configWriter requires sseBroadcast');
      }
    }
  }

  Handler _buildHandler() {
    _validateRuntimeServices();
    _dashboardPagesLocked = true;
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
    final webhookRouter = webhookRoutes(
      whatsApp: _whatsAppChannel,
      webhookSecret: _webhookSecret,
      googleChat: _googleChatWebhookHandler,
      eventBus: _eventBus,
      trustedProxies: _config?.trustedProxies ?? const [],
    );
    router.mount('/', webhookRouter.call);

    // WhatsApp pairing page.
    final waChannel = _whatsAppChannel;

    if (waChannel != null) {
      router.get('/whatsapp/pairing', (Request request) async {
        final sidebarData = await buildSidebarData(_sessions);
        final fragment = wantsFragment(request);
        final pairingCode = request.requestedUri.queryParameters['code'];

        // Sidecar crashed / restarting
        if (!waChannel.gowa.isRunning && waChannel.gowa.restartCount > 0) {
          return Response.ok(
            whatsappPairingTemplate(
              showReconnecting: true,
              restartAttempt: waChannel.gowa.restartCount,
              maxRestartAttempts: waChannel.gowa.maxRestartAttempts,
              sidebarData: sidebarData,
              navItems: _pageRegistry.navItems(activePage: 'Settings'),
              fragmentOnly: fragment,
              appName: _appDisplay.name,
            ),
            headers: htmlHeaders,
          );
        }

        try {
          final status = await waChannel.gowa.getStatus();
          if (status.isLoggedIn) {
            return Response.ok(
              whatsappPairingTemplate(
                isConnected: true,
                connectedPhone: jidToPhone(waChannel.gowa.pairedJid ?? status.deviceId),
                sidebarData: sidebarData,
                navItems: _pageRegistry.navItems(activePage: 'Settings'),
                fragmentOnly: fragment,
              ),
              headers: htmlHeaders,
            );
          }
          // GOWA reachable but not logged in — show QR + pairing code
          final loginQr = await waChannel.gowa.getLoginQr();
          // Use local proxy URL to avoid CSP img-src blocking.
          final proxyUrl = loginQr.url != null ? '/whatsapp/pairing/qr' : null;
          return Response.ok(
            whatsappPairingTemplate(
              qrImageUrl: proxyUrl,
              qrDuration: loginQr.durationSeconds,
              pairingCode: pairingCode,
              sidebarData: sidebarData,
              navItems: _pageRegistry.navItems(activePage: 'Settings'),
              fragmentOnly: fragment,
              appName: _appDisplay.name,
            ),
            headers: htmlHeaders,
          );
        } catch (e) {
          return Response.ok(
            whatsappPairingTemplate(
              error: 'Failed to check GOWA status: $e',
              sidebarData: sidebarData,
              navItems: _pageRegistry.navItems(activePage: 'Settings'),
              fragmentOnly: fragment,
              appName: _appDisplay.name,
            ),
            headers: htmlHeaders,
          );
        }
      });

      // GET /whatsapp/pairing/qr — proxy QR image from GOWA to avoid CSP issues.
      router.get('/whatsapp/pairing/qr', (Request request) async {
        try {
          final loginQr = await waChannel.gowa.getLoginQr();
          if (loginQr.url == null) return Response.notFound('No QR available');
          final client = HttpClient();
          try {
            final req = await client.getUrl(Uri.parse(loginQr.url!));
            final resp = await req.close().timeout(const Duration(seconds: 10));
            final bytes = await resp.fold<List<int>>([], (prev, chunk) => prev..addAll(chunk));
            return Response.ok(bytes, headers: {'content-type': 'image/png', 'cache-control': 'no-store'});
          } finally {
            client.close();
          }
        } catch (_) {
          return Response.internalServerError(body: 'Failed to fetch QR');
        }
      });

      // GET /whatsapp/pairing/poll — lightweight status check for HTMX polling.
      // Returns 204 while waiting (HTMX skips swap), or renders full page
      // when pairing completes.
      router.get('/whatsapp/pairing/poll', (Request request) async {
        try {
          final status = await waChannel.gowa.getStatus();
          if (!status.isLoggedIn) return Response(204);
          // Connected — render full page.
          final sidebarData = await buildSidebarData(_sessions);
          return Response.ok(
            whatsappPairingTemplate(
              isConnected: true,
              connectedPhone: jidToPhone(waChannel.gowa.pairedJid ?? status.deviceId),
              sidebarData: sidebarData,
              navItems: _pageRegistry.navItems(activePage: 'Settings'),
              fragmentOnly: wantsFragment(request),
              appName: _appDisplay.name,
            ),
            headers: htmlHeaders,
          );
        } catch (_) {
          return Response(204);
        }
      });

      // POST /whatsapp/pairing/disconnect — reset GOWA and restart for re-pairing.
      router.post('/whatsapp/pairing/disconnect', (Request request) async {
        try {
          await waChannel.disconnect();
          await waChannel.connect();
          return Response.found('/whatsapp/pairing');
        } catch (e) {
          final msg = Uri.encodeQueryComponent('Failed to disconnect: $e');
          return Response.found('/whatsapp/pairing?error=$msg');
        }
      });

      // POST /whatsapp/pairing/code — request pairing code for a phone number.
      router.post('/whatsapp/pairing/code', (Request request) async {
        try {
          final body = await request.readAsString();
          final params = Uri.splitQueryString(body);
          final phone = params['phone'] ?? '';
          if (phone.isEmpty) {
            return Response.found('/whatsapp/pairing?error=${Uri.encodeQueryComponent('Phone number is required')}');
          }
          final result = await waChannel.gowa.requestPairingCode(phone);
          final code = result['code']?.toString() ?? result['pairing_code']?.toString();
          if (code != null) {
            return Response.found('/whatsapp/pairing?code=${Uri.encodeQueryComponent(code)}');
          }
          return Response.found('/whatsapp/pairing?error=${Uri.encodeQueryComponent('No pairing code returned')}');
        } catch (e) {
          final msg = Uri.encodeQueryComponent('Failed to get pairing code: $e');
          return Response.found('/whatsapp/pairing?error=$msg');
        }
      });
    }

    // Signal pairing page + registration routes (extracted for testability).
    final sigChannel = _signalChannel;
    if (sigChannel != null) {
      final sigRouter = signalPairingRoutes(
        signalChannel: sigChannel,
        sessions: _sessions,
        pageRegistry: _pageRegistry,
        appName: _appDisplay.name,
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
        heartbeatIntervalMinutes: _heartbeatDisplay.intervalMinutes,
        scheduledJobs: _schedulingDisplay.jobs,
      );
      router.mount('/', cfgRouter.call);
    }

    // Config API routes (persistent config editing — after toggle routes).
    final cw = _configWriter;
    final cfg = _config;
    final dd = _appDisplay.dataDir;
    if (cw != null && cfg != null && rc != null && dd != null) {
      final cfgApiRouter = configApiRoutes(
        config: cfg,
        writer: cw,
        validator: const ConfigValidator(),
        runtimeConfig: rc,
        dataDir: dd,
        restartService: _restartService,
        sseBroadcast: _sseBroadcast,
        scheduleService: _scheduleService,
        whatsAppChannel: _whatsAppChannel,
        signalChannel: _signalChannel,
        googleChatChannel: _googleChatWebhookHandler?.channel,
        eventBus: _eventBus,
      );
      router.mount('/', cfgApiRouter.call);
    }

    // Memory API routes (prefixed /api/memory/).
    final memStatus = _memoryStatusService;
    final wp = _workspaceDisplay.path;
    if (memStatus != null && wp != null) {
      final memRouter = memoryRoutes(
        statusService: memStatus,
        workspaceDir: wp,
        pruner: _memoryPruner,
        kvService: _kvService,
      );
      router.mount('/', memRouter.call);
    }

    // API routes (prefixed /api/ — no collision with web routes).
    final goalService = _goalService;
    if (goalService != null) {
      final goalRouter = goalRoutes(goalService);
      router.mount('/', goalRouter.call);
    }

    final taskService = _taskService;
    final eventBus = _eventBus;
    if (taskService != null && eventBus != null) {
      final taskSseRouter = taskSseRoutes(taskService, eventBus, observer: _agentObserver);
      router.mount('/', taskSseRouter.call);
      final taskRouter = taskRoutes(
        taskService,
        eventBus,
        turns: _turns,
        worktreeManager: _worktreeManager,
        taskFileGuard: _taskFileGuard,
        mergeExecutor: _mergeExecutor,
        dataDir: _appDisplay.dataDir,
        mergeStrategy: _mergeStrategy ?? 'squash',
        baseRef: _baseRef ?? 'main',
      );
      router.mount('/', taskRouter.call);
    }

    // Agent overview API routes.
    final agentObs = _agentObserver;
    if (agentObs != null) {
      final agentRouter = agentRoutes(agentObs);
      router.mount('/', agentRouter.call);
    }

    final sessionRouter = sessionRoutes(
      _sessions,
      _messages,
      _turns,
      _worker,
      resetService: _resetService,
      redactor: _redactor,
    );
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
      googleChatChannel: _googleChatWebhookHandler?.channel,
      guardChain: _guardChain,
      turns: _turns,
      runtimeConfig: _runtimeConfig,
      memoryStatusService: _memoryStatusService,
      cookieSecure: _config?.cookieSecure ?? false,
      trustedProxies: _config?.trustedProxies ?? const [],
      contentGuardDisplay: _contentGuardDisplay,
      heartbeatDisplay: _heartbeatDisplay,
      schedulingDisplay: _schedulingDisplay,
      workspaceDisplay: _workspaceDisplay,
      appDisplay: _appDisplay,
      pageRegistry: _pageRegistry,
      config: _config,
      taskService: _taskService,
      goalService: _goalService,
      eventBus: _eventBus,
      agentObserver: _agentObserver,
    );
    router.mount('/', webRouter.call);

    var pipeline = const Pipeline()
        .addMiddleware(logRequests(logger: _sanitizedLogger))
        .addMiddleware(securityHeadersMiddleware(enableHsts: _config?.gatewayHsts ?? false))
        .addMiddleware(_corsMiddleware());
    if (_tokenService != null && _gatewayToken != null) {
      pipeline = pipeline.addMiddleware(
        authMiddleware(
          tokenService: _tokenService,
          gatewayToken: _gatewayToken,
          enabled: _authEnabled,
          cookieSecure: _config?.cookieSecure ?? false,
          trustedProxies: _config?.trustedProxies ?? const [],
          eventBus: _eventBus,
          rateLimiter: _authRateLimiter,
          publicPaths: [if (_googleChatWebhookHandler != null) _googleChatWebhookHandler.config.webhookPath],
        ),
      );
    }
    // Cascade: pass through to styled 404 when router finds no matching route.
    final cascade = Cascade()
        .add(router.call)
        .add(
          (_) => Response.notFound(
            errorPageTemplate(404, 'Page Not Found', 'The requested page does not exist.'),
            headers: htmlHeaders,
          ),
        );
    return pipeline.addHandler(cascade.handler);
  }
}

/// Redacts sensitive query parameters (e.g. `secret`) from request log lines.
///
/// Shelf's default `logRequests()` logs the full URI including query strings,
/// which would expose webhook secrets in plaintext. This logger strips the
/// `secret` parameter value before logging. Output goes through the standard
/// [Logger] so it gets colorized level/name and structured formatting.
final _httpLog = Logger('HTTP');

void _sanitizedLogger(String msg, bool isError) {
  final sanitized = msg.replaceAll(RegExp(r'([?&])secret=[^&\s]*'), r'$1secret=REDACTED');
  if (isError) {
    _httpLog.severe(sanitized);
  } else {
    _httpLog.info(sanitized);
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
