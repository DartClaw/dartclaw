import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:shelf_static/shelf_static.dart';

import 'api/session_routes.dart';
import 'api/webhook_routes.dart';
import 'auth/auth_middleware.dart';
import 'auth/security_headers.dart';
import 'auth/session_store.dart';
import 'auth/token_service.dart';
import 'concurrency/session_lock_manager.dart';
import 'context/context_monitor.dart';
import 'context/result_trimmer.dart';
import 'health/health_service.dart';
import 'session/session_reset_service.dart';
import 'templates/error_page.dart';
import 'turn_manager.dart';
import 'web/web_routes.dart';
import 'web/whatsapp_pairing.dart';

class DartclawServer {
  final SessionService _sessions;
  final MessageService _messages;
  final AgentHarness _worker;
  final TurnManager _turns;
  TurnManager get turns => _turns;
  final MemoryFileService? _memoryFile;
  final HealthService? _healthService;
  final TokenService? _tokenService;
  final SessionStore? _sessionStore;
  final SessionResetService? _resetService;
  final bool _authEnabled;
  final String _staticDir;
  final ChannelManager? _channelManager;
  final WhatsAppChannel? _whatsAppChannel;
  final GuardChain? _guardChain;
  final String? _webhookSecret;

  DartclawServer._(
    this._sessions,
    this._messages,
    this._worker,
    this._turns,
    this._memoryFile,
    this._healthService,
    this._tokenService,
    this._sessionStore,
    this._resetService,
    this._authEnabled,
    this._staticDir,
    this._channelManager,
    this._whatsAppChannel,
    this._guardChain,
    this._webhookSecret,
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
    SessionStore? sessionStore,
    SessionLockManager? lockManager,
    SessionResetService? resetService,
    ContextMonitor? contextMonitor,
    ResultTrimmer? resultTrimmer,
    ChannelManager? channelManager,
    WhatsAppChannel? whatsAppChannel,
    String? webhookSecret,
    bool authEnabled = true,
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
      ),
      memoryFile,
      healthService,
      tokenService,
      sessionStore,
      resetService,
      authEnabled,
      staticDir,
      channelManager,
      whatsAppChannel,
      guardChain,
      webhookSecret,
    );
  }

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
      router.get('/health', (Request request) {
        final status = hs.getStatus();
        return Response.ok(jsonEncode(status), headers: {'Content-Type': 'application/json'});
      });
    }

    // Static files at /static/ prefix.
    final staticHandler = createStaticHandler(_staticDir, defaultDocument: null);
    router.mount('/static/', staticHandler);

    // Webhook routes (unauthenticated — before auth middleware).
    final webhookRouter = webhookRoutes(whatsApp: _whatsAppChannel, webhookSecret: _webhookSecret);
    router.mount('/', webhookRouter.call);

    // WhatsApp pairing page.
    final waChannel = _whatsAppChannel;
    if (waChannel != null) {
      router.get('/whatsapp/pairing', (Request request) async {
        final sidebarData = await buildSidebarData(_sessions);
        try {
          final status = await waChannel.gowa.getStatus();
          if (status.isLoggedIn) {
            return Response.ok(
              whatsappPairingTemplate(
                isConnected: true,
                connectedPhone: status.deviceId,
                sidebarData: sidebarData,
              ),
              headers: {'content-type': 'text/html; charset=utf-8'},
            );
          }
          // GOWA reachable but not logged in — show QR
          final qrUrl = await waChannel.gowa.getLoginQr();
          return Response.ok(
            whatsappPairingTemplate(qrImageUrl: qrUrl, sidebarData: sidebarData),
            headers: {'content-type': 'text/html; charset=utf-8'},
          );
        } catch (e) {
          return Response.ok(
            whatsappPairingTemplate(error: 'Failed to check GOWA status: $e', sidebarData: sidebarData),
            headers: {'content-type': 'text/html; charset=utf-8'},
          );
        }
      });
    }

    // API routes (prefixed /api/ — no collision with web routes).
    final sessionRouter = sessionRoutes(_sessions, _messages, _turns, _worker, resetService: _resetService);
    router.mount('/', sessionRouter.call);

    // Web/HTML routes (/, /sessions/*, /login).
    final webRouter = webRoutes(
      _sessions,
      _messages,
      workerStateGetter: () => _worker.state,
      tokenService: _tokenService,
      sessionStore: _sessionStore,
      healthService: _healthService,
      whatsAppChannel: _whatsAppChannel,
      guardChain: _guardChain,
      turns: _turns,
    );
    router.mount('/', webRouter.call);

    var pipeline = const Pipeline()
        .addMiddleware(logRequests())
        .addMiddleware(securityHeadersMiddleware())
        .addMiddleware(_corsMiddleware());
    if (_tokenService != null && _sessionStore != null) {
      pipeline = pipeline.addMiddleware(
        authMiddleware(tokenService: _tokenService, sessionStore: _sessionStore, enabled: _authEnabled),
      );
    }
    // Cascade: pass through to styled 404 when router finds no matching route.
    final cascade = Cascade().add(router.call).add(
      (_) => Response.notFound(
        errorPageTemplate(404, 'Page Not Found', 'The requested page does not exist.'),
        headers: {'content-type': 'text/html; charset=utf-8'},
      ),
    );
    return pipeline.addHandler(cascade.handler);
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
