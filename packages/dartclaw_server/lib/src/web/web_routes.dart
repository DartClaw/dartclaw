import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../auth/session_store.dart';
import '../auth/token_service.dart';
import '../health/health_service.dart';
import '../templates/chat.dart';
import '../templates/components.dart';
import '../templates/error_page.dart';
import '../templates/health_dashboard.dart';
import '../templates/layout.dart';
import '../templates/login.dart';
import '../templates/scheduling.dart';
import '../templates/session_info.dart';
import '../templates/settings.dart';
import '../templates/sidebar.dart';
import '../templates/topbar.dart';
import '../turn_manager.dart';

/// HTML page routes for the web UI.
///
/// [workerState] is checked on session page load to show recovery banners.
///
/// SPA navigation: sidebar links send `HX-Request: true` with `hx-get`.
/// When an HTMX request arrives (and it is NOT a history restore), the server
/// returns only the `#main-content` fragment plus out-of-band `#topbar` and
/// `#sidebar` swaps — no full `<html>` document. History restore requests
/// (`HX-History-Restore-Request: true`) and non-HTMX requests receive the
/// full page.
Router webRoutes(
  SessionService sessions,
  MessageService messages, {
  WorkerState? Function()? workerStateGetter,
  TokenService? tokenService,
  SessionStore? sessionStore,
  HealthService? healthService,
  WhatsAppChannel? whatsAppChannel,
  SignalChannel? signalChannel,
  GuardChain? guardChain,
  TurnManager? turns,
  bool heartbeatEnabled = false,
  int heartbeatIntervalMinutes = 30,
  List<Map<String, dynamic>> scheduledJobs = const [],
  String? workspacePath,
  bool gitSyncEnabled = false,
}) {
  final router = Router();
  final signalEnabled = signalChannel != null;
  final systemNav = buildSystemNavItems(activePage: '', signalEnabled: signalEnabled);

  // GET /login — render login page.
  router.get('/login', (Request request) {
    return Response.ok(
      loginPageTemplate(),
      headers: {'content-type': 'text/html; charset=utf-8'},
    );
  });

  // POST /login — validate token, set cookie, redirect.
  router.post('/login', (Request request) async {
    final ts = tokenService;
    final ss = sessionStore;
    if (ts == null || ss == null) {
      return _redirect(request, '/');
    }

    final body = await request.readAsString();
    final params = Uri.splitQueryString(body);
    final candidate = params['token'] ?? '';

    if (!ts.validateToken(candidate)) {
      return Response.ok(
        loginPageTemplate(error: 'Invalid token'),
        headers: {'content-type': 'text/html; charset=utf-8'},
      );
    }

    final sessionId = ss.createSession();
    return _redirect(request, '/', extraHeaders: {
      'set-cookie': 'dart_session=$sessionId; HttpOnly; SameSite=Strict; Path=/; Max-Age=2592000',
    });
  });

  // GET / — redirect to main session (guaranteed to exist after startup).
  router.get('/', (Request request) async {
    final mainSession = (await sessions.listSessions(type: SessionType.main)).firstOrNull;
    if (mainSession != null) {
      return _redirect(request, '/sessions/${mainSession.id}');
    }
    // Fallback: any session
    final all = await sessions.listSessions();
    if (all.isNotEmpty) {
      return _redirect(request, '/sessions/${all.first.id}');
    }

    final sidebarData = await buildSidebarData(sessions);
    final sidebar = sidebarTemplate(
      mainSession: sidebarData.main,
      channelSessions: sidebarData.channels,
      sessionEntries: sidebarData.entries,
      navItems: systemNav,
    );
    final topbar = topbarTemplate();
    final main = emptyAppStateTemplate();
    final bodyHtml = '<div class="shell">$sidebar$topbar$main</div>';
    final page = layoutTemplate(title: 'DartClaw', body: bodyHtml);

    return Response.ok(page, headers: {'content-type': 'text/html; charset=utf-8'});
  });

  // GET /sessions/<id> — full page or SPA fragment.
  router.get('/sessions/<id>', (Request request, String id) async {
    try {
      final session = await sessions.getSession(id);
      if (session == null) return _htmlNotFound('Session not found: $id');

      final sidebarData = await buildSidebarData(sessions);
      final msgs = await messages.getMessages(id);
      final messageList = msgs.map((m) => classifyMessage(id: m.id, role: m.role, content: m.content)).toList();

      final sidebar = sidebarTemplate(
        mainSession: sidebarData.main,
        channelSessions: sidebarData.channels,
        sessionEntries: sidebarData.entries,
        activeSessionId: id,
        navItems: systemNav,
      );
      final topbar = topbarTemplate(title: session.title, sessionId: id, sessionType: session.type);
      final msgsHtml = messagesHtmlFragment(messageList);
      final bannerHtml = StringBuffer();
      if (workerStateGetter?.call() == WorkerState.crashed) {
        bannerHtml.write(
          '<div class="banner banner-warning">Agent interrupted — the worker will restart on next message. '
          'Retry your message.'
          '<button class="dismiss" aria-label="Dismiss">&#10005;</button></div>',
        );
      }
      if (turns?.consumeRecoveryNotice(id) ?? false) {
        bannerHtml.write(
          '<div class="banner banner-warning">This session recovered from an interrupted turn. '
          'Your conversation is intact.'
          '<button class="dismiss" aria-label="Dismiss">&#10005;</button></div>',
        );
      }
      final isArchive = session.type == SessionType.archive;
      final chat = chatAreaTemplate(
        sessionId: id,
        messagesHtml: msgsHtml,
        hasTitle: session.title != null && session.title!.trim().isNotEmpty,
        bannerHtml: bannerHtml.toString(),
        readOnly: isArchive,
      );

      if (_wantsFragment(request)) {
        return _htmlFragment('$chat$topbar$sidebar');
      }

      final bodyHtml = '<div class="shell">$sidebar$topbar$chat</div>';
      final page = layoutTemplate(title: session.title ?? 'New Session', body: bodyHtml);
      return Response.ok(page, headers: {'content-type': 'text/html; charset=utf-8'});
    } catch (e) {
      return _htmlError('Failed to load session: $e');
    }
  });

  // GET /sessions/<id>/messages-html — message list fragment (HTMX swap target).
  router.get('/sessions/<id>/messages-html', (Request request, String id) async {
    try {
      final session = await sessions.getSession(id);
      if (session == null) return _htmlNotFound('Session not found: $id');

      final msgs = await messages.getMessages(id);
      final messageList = msgs.map((m) => classifyMessage(id: m.id, role: m.role, content: m.content)).toList();

      return Response.ok(messagesHtmlFragment(messageList), headers: {'content-type': 'text/html; charset=utf-8'});
    } catch (e) {
      return _htmlError('Failed to load messages: $e');
    }
  });

  // GET /sessions/<id>/info — session info page.
  router.get('/sessions/<id>/info', (Request request, String id) async {
    try {
      final session = await sessions.getSession(id);
      if (session == null) return _htmlNotFound('Session not found: $id');

      final sidebarData = await buildSidebarData(sessions);
      final msgs = await messages.getMessages(id);

      final page = sessionInfoTemplate(
        sessionId: id,
        sessionTitle: session.title ?? '',
        messageCount: msgs.length,
        sidebarData: sidebarData,
        navItems: systemNav,
        createdAt: session.createdAt.toIso8601String(),
      );

      return Response.ok(page, headers: {'content-type': 'text/html; charset=utf-8'});
    } catch (e) {
      return _htmlError('Failed to load session info: $e');
    }
  });

  // GET /health-dashboard — HTML health dashboard.
  router.get('/health-dashboard', (Request request) async {
    try {
      final allSessions = await sessions.listSessions();
      final sidebarData = await buildSidebarData(sessions);

      final status = _getStatus(healthService, workerStateGetter, allSessions.length);

      final page = healthDashboardTemplate(
        status: status['status'] as String? ?? 'healthy',
        uptimeSeconds: status['uptime_s'] as int? ?? 0,
        workerState: status['worker_state'] as String? ?? 'unknown',
        sessionCount: status['session_count'] as int? ?? 0,
        dbSizeBytes: status['db_size_bytes'] as int? ?? 0,
        version: status['version'] as String? ?? 'unknown',
        sidebarData: sidebarData,
        signalEnabled: signalEnabled,
      );

      return Response.ok(page, headers: {'content-type': 'text/html; charset=utf-8'});
    } catch (e) {
      return _htmlError('Failed to load health dashboard: $e');
    }
  });

  // GET /settings — settings hub.
  router.get('/settings', (Request request) async {
    try {
      final allSessions = await sessions.listSessions();
      final sidebarData = await buildSidebarData(sessions);

      final status = _getStatus(healthService, workerStateGetter, allSessions.length);

      final gc = guardChain;
      final guardsEnabled = gc != null;
      final activeGuards = gc != null
          ? gc.guards.map((g) => g.runtimeType.toString().replaceAll('Guard', '-Guard')).toList()
          : <String>[];

      final page = settingsTemplate(
        sidebarData: sidebarData,
        uptimeSeconds: status['uptime_s'] as int? ?? 0,
        sessionCount: status['session_count'] as int? ?? 0,
        dbSizeBytes: status['db_size_bytes'] as int? ?? 0,
        workerState: status['worker_state'] as String? ?? 'unknown',
        version: status['version'] as String? ?? 'unknown',
        whatsAppEnabled: whatsAppChannel != null,
        signalEnabled: signalEnabled,
        signalPhone: signalChannel?.config.phoneNumber,
        signalStatus: signalChannel != null
            ? (signalChannel.sidecar.isRunning ? 'connected' : 'disconnected')
            : 'not configured',
        guardsEnabled: guardsEnabled,
        activeGuards: activeGuards,
        scheduledJobsCount: scheduledJobs.length,
        heartbeatEnabled: heartbeatEnabled,
        heartbeatIntervalMinutes: heartbeatIntervalMinutes,
        workspacePath: workspacePath,
        gitSyncEnabled: gitSyncEnabled,
      );

      return Response.ok(page, headers: {'content-type': 'text/html; charset=utf-8'});
    } catch (e) {
      return _htmlError('Failed to load settings: $e');
    }
  });

  // GET /scheduling — scheduling status page.
  router.get('/scheduling', (Request request) async {
    try {
      final sidebarData = await buildSidebarData(sessions);

      final page = schedulingTemplate(
        sidebarData: sidebarData,
        heartbeatEnabled: heartbeatEnabled,
        heartbeatIntervalMinutes: heartbeatIntervalMinutes,
        jobs: scheduledJobs,
        signalEnabled: signalEnabled,
      );

      return Response.ok(page, headers: {'content-type': 'text/html; charset=utf-8'});
    } catch (e) {
      return _htmlError('Failed to load scheduling page: $e');
    }
  });

  return router;
}

// ---------------------------------------------------------------------------
// Sidebar data helper
// ---------------------------------------------------------------------------

/// Fetches and partitions all sessions for sidebar rendering.
Future<SidebarData> buildSidebarData(SessionService sessions) async {
  final all = await sessions.listSessions();
  SidebarSession? main;
  final channels = <SidebarSession>[];
  final entries = <SidebarSession>[]; // user + archive, already sorted by updatedAt desc

  for (final s in all) {
    final entry = (id: s.id, title: s.title ?? '', type: s.type);
    switch (s.type) {
      case SessionType.main:
        main = entry;
      case SessionType.channel:
        channels.add(entry);
      case SessionType.cron:
        break; // hidden from sidebar
      case SessionType.user:
      case SessionType.archive:
        entries.add(entry);
    }
  }

  return (main: main, channels: channels, entries: entries);
}

Map<String, dynamic> _getStatus(
  HealthService? healthService,
  WorkerState? Function()? workerStateGetter,
  int sessionCount,
) {
  if (healthService != null) return healthService.getStatus();
  final ws = workerStateGetter?.call();
  return {
    'status': 'healthy',
    'uptime_s': 0,
    'worker_state': ws?.name ?? 'unknown',
    'session_count': sessionCount,
    'db_size_bytes': 0,
    'version': 'unknown',
  };
}

// ---------------------------------------------------------------------------
// HTMX SPA helpers
// ---------------------------------------------------------------------------

/// Whether the request is an HTMX SPA navigation that expects a fragment
/// (not a history-restore which needs the full page).
bool _wantsFragment(Request request) {
  final isHx = request.headers['HX-Request'] == 'true';
  final isHistoryRestore = request.headers['HX-History-Restore-Request'] == 'true';
  return isHx && !isHistoryRestore;
}

/// Returns an HTML fragment response (used for SPA partial swaps).
Response _htmlFragment(String html) => Response.ok(html, headers: {'content-type': 'text/html; charset=utf-8'});

/// Redirect helper: HTMX requests get `HX-Location` (client-side redirect),
/// non-HTMX requests get a standard 302.
Response _redirect(Request request, String path, {Map<String, String>? extraHeaders}) {
  final headers = <String, String>{...?extraHeaders};
  if (request.headers['HX-Request'] == 'true') {
    headers['HX-Location'] = path;
    return Response.ok('', headers: headers);
  }
  return Response.found(path, headers: headers);
}

Response _htmlNotFound(String message) => Response.notFound(
  errorPageTemplate(404, 'Page Not Found', message),
  headers: {'content-type': 'text/html; charset=utf-8'},
);

Response _htmlError(String message) => Response.internalServerError(
  body: errorPageTemplate(500, 'Internal Server Error', message),
  headers: {'content-type': 'text/html; charset=utf-8'},
);
