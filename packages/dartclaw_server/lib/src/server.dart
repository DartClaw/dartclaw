import 'dart:convert';
import 'dart:io';

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
import 'web/signal_pairing.dart';
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
  final SessionStore? _sessionStore;
  final SessionResetService? _resetService;
  final bool _authEnabled;
  final String _staticDir;
  final ChannelManager? _channelManager;
  final WhatsAppChannel? _whatsAppChannel;
  final SignalChannel? _signalChannel;
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
    this._signalChannel,
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
    SignalChannel? signalChannel,
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
      signalChannel,
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
    final sigEnabled = _signalChannel != null;
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
                signalEnabled: sigEnabled,
              ),
              headers: _htmlHeaders,
            );
          }
          // GOWA reachable but not logged in — show QR
          final qrUrl = await waChannel.gowa.getLoginQr();
          return Response.ok(
            whatsappPairingTemplate(qrImageUrl: qrUrl, sidebarData: sidebarData, signalEnabled: sigEnabled),
            headers: _htmlHeaders,
          );
        } catch (e) {
          return Response.ok(
            whatsappPairingTemplate(
              error: 'Failed to check GOWA status: $e',
              sidebarData: sidebarData,
              signalEnabled: sigEnabled,
            ),
            headers: _htmlHeaders,
          );
        }
      });
    }

    // Signal pairing page + registration routes.
    final sigChannel = _signalChannel;
    if (sigChannel != null) {
      router.get('/signal/pairing', (Request request) async {
        final sidebarData = await buildSidebarData(_sessions);
        final phone = sigChannel.config.phoneNumber;
        final error = request.requestedUri.queryParameters['error'];
        final step = request.requestedUri.queryParameters['step'];

        var verificationPending = false;
        var isConnected = false;
        String? connectedPhone;
        String? configuredPhone = phone;
        String? linkDeviceUri;
        String? templateError = error;

        if (step == 'verify') {
          // SMS verification pending — show code entry form.
          verificationPending = true;
        } else {
          try {
            final reachable = await sigChannel.sidecar.healthCheck();
            if (reachable) {
              final registered = await sigChannel.sidecar.isAccountRegistered();
              if (registered) {
                isConnected = true;
                connectedPhone = phone;
                configuredPhone = null;
                templateError = null;
              } else {
                // Sidecar up but not registered — fetch link device URI.
                linkDeviceUri = await sigChannel.sidecar.getLinkDeviceUri();
              }
            }
          } catch (e) {
            templateError = 'Failed to check signal-cli status: $e';
          }
        }

        return Response.ok(
          signalPairingTemplate(
            verificationPending: verificationPending,
            isConnected: isConnected,
            connectedPhone: connectedPhone,
            configuredPhone: configuredPhone,
            linkDeviceUri: linkDeviceUri,
            error: templateError,
            sidebarData: sidebarData,
            signalEnabled: true,
          ),
          headers: _htmlHeaders,
        );
      });

      // POST /signal/pairing/register — trigger SMS verification.
      router.post('/signal/pairing/register', (Request request) async {
        try {
          await sigChannel.sidecar.requestSmsVerification();
          return Response.found('/signal/pairing?step=verify');
        } catch (e) {
          final msg = Uri.encodeQueryComponent('Failed to send SMS: $e');
          return Response.found('/signal/pairing?error=$msg');
        }
      });

      // POST /signal/pairing/verify — complete SMS verification.
      router.post('/signal/pairing/verify', (Request request) async {
        try {
          final body = await request.readAsString();
          final params = Uri.splitQueryString(body);
          final token = params['token'] ?? '';
          if (token.isEmpty) {
            return Response.found('/signal/pairing?step=verify&error=${Uri.encodeQueryComponent('Code is required')}');
          }
          await sigChannel.sidecar.verifySmsCode(token);
          return Response.found('/signal/pairing');
        } catch (e) {
          final msg = Uri.encodeQueryComponent('Verification failed: $e');
          return Response.found('/signal/pairing?step=verify&error=$msg');
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
      signalChannel: _signalChannel,
      guardChain: _guardChain,
      turns: _turns,
    );
    router.mount('/', webRouter.call);

    var pipeline = const Pipeline()
        .addMiddleware(logRequests(logger: _sanitizedLogger))
        .addMiddleware(securityHeadersMiddleware())
        .addMiddleware(_corsMiddleware());
    if (_tokenService != null && _sessionStore != null) {
      pipeline = pipeline.addMiddleware(
        authMiddleware(tokenService: _tokenService, sessionStore: _sessionStore, enabled: _authEnabled),
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
