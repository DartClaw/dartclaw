import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../api/config_api_routes.dart' show readRestartPending;
import '../auth/session_token.dart';
import '../auth/token_service.dart';
import '../health/health_service.dart';
import '../params/display_params.dart';
import '../templates/channel_detail.dart';
import '../templates/chat.dart';
import '../templates/components.dart';
import '../templates/error_page.dart';
import '../audit/audit_log_reader.dart';
import '../templates/audit_table.dart';
import '../templates/health_dashboard.dart';
import '../templates/layout.dart';
import '../templates/login.dart';
import '../templates/memory_dashboard.dart';
import '../memory/memory_status_service.dart';
import '../templates/restart_banner.dart';
import '../templates/scheduling.dart';
import '../templates/session_info.dart';
import '../templates/guard_config_summary.dart';
import '../templates/settings.dart';
import '../templates/sidebar.dart';
import '../templates/topbar.dart';
import '../runtime_config.dart';
import '../turn_manager.dart';
import 'channel_status.dart';
import 'web_utils.dart';

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
  String? gatewayToken,
  HealthService? healthService,
  WhatsAppChannel? whatsAppChannel,
  SignalChannel? signalChannel,
  GuardChain? guardChain,
  TurnManager? turns,
  RuntimeConfig? runtimeConfig,
  MemoryStatusService? memoryStatusService,
  ContentGuardDisplayParams contentGuardDisplay = const ContentGuardDisplayParams(),
  HeartbeatDisplayParams heartbeatDisplay = const HeartbeatDisplayParams(),
  SchedulingDisplayParams schedulingDisplay = const SchedulingDisplayParams(),
  WorkspaceDisplayParams workspaceDisplay = const WorkspaceDisplayParams(),
  AppDisplayParams appDisplay = const AppDisplayParams(),
}) {
  final router = Router();
  final signalEnabled = signalChannel != null;
  final systemNav = buildSystemNavItems(activePage: '');
  final auditReader = appDisplay.dataDir != null ? AuditLogReader(dataDir: appDisplay.dataDir!) : null;

  // GET /login — render login page.
  router.get('/login', (Request request) {
    return Response.ok(
      loginPageTemplate(appName: appDisplay.name),
      headers: htmlHeaders,
    );
  });

  // POST /login — validate token, set cookie, redirect.
  router.post('/login', (Request request) async {
    final ts = tokenService;
    final gt = gatewayToken;
    if (ts == null || gt == null) {
      return _redirect(request, '/');
    }

    final body = await request.readAsString();
    final params = Uri.splitQueryString(body);
    final candidate = params['token'] ?? '';

    if (!ts.validateToken(candidate)) {
      return Response.ok(
        loginPageTemplate(error: 'Invalid token', appName: appDisplay.name),
        headers: htmlHeaders,
      );
    }

    final sessionToken = createSessionToken(gt);
    return _redirect(request, '/', extraHeaders: {
      'set-cookie': sessionCookieHeader(sessionToken),
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
      appName: appDisplay.name,
    );
    final topbar = topbarTemplate(appName: appDisplay.name);
    final main = emptyAppStateTemplate(appName: appDisplay.name);
    final bodyHtml = '<div class="shell">$sidebar$topbar$main</div>';
    final page = layoutTemplate(title: appDisplay.name, body: bodyHtml, appName: appDisplay.name);

    return Response.ok(page, headers: htmlHeaders);
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
        appName: appDisplay.name,
      );
      final topbar = topbarTemplate(title: session.title, sessionId: id, sessionType: session.type, appName: appDisplay.name);
      final msgsHtml = messagesHtmlFragment(messageList);
      final bannerHtml = StringBuffer(_restartBannerHtml(appDisplay.dataDir));
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

      if (wantsFragment(request)) {
        return htmlFragment('$chat$topbar$sidebar');
      }

      final bodyHtml = '<div class="shell">$sidebar$topbar$chat</div>';
      final page = layoutTemplate(title: session.title ?? 'New Session', body: bodyHtml, appName: appDisplay.name);
      return Response.ok(page, headers: htmlHeaders);
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

      return Response.ok(messagesHtmlFragment(messageList), headers: htmlHeaders);
    } catch (e) {
      return _htmlError('Failed to load messages: $e');
    }
  });

  // GET /sessions/<id>/info — session info page.
  router.get('/sessions/<id>/info', (Request request, String id) async {
    try {
      final session = await sessions.getSession(id);
      if (session == null) return _htmlNotFound('Session not found: $id');

      final msgs = await messages.getMessages(id);

      final recentTurns = msgs.reversed.take(8).map((m) {
        final text = m.content.replaceAll('\n', ' ');
        final excerpt = text.length > 80 ? '${text.substring(0, 80)}\u2026' : text;
        final h = m.createdAt.hour.toString().padLeft(2, '0');
        final min = m.createdAt.minute.toString().padLeft(2, '0');
        final isUser = m.role == 'user';
        return <String, String>{
          'time': '$h:$min',
          'roleLabel': isUser ? 'You' : 'Assistant',
          'roleClass': isUser ? 'turn-role-user' : 'turn-role-assistant',
          'excerpt': excerpt,
        };
      }).toList().reversed.toList();

      final page = sessionInfoTemplate(
        sessionId: id,
        sessionTitle: session.title ?? '',
        messageCount: msgs.length,
        sidebarData: await buildSidebarData(sessions),
        navItems: systemNav,
        createdAt: session.createdAt.toIso8601String(),
        bannerHtml: _restartBannerHtml(appDisplay.dataDir),
        recentTurns: recentTurns,
        appName: appDisplay.name,
      );

      return Response.ok(page, headers: htmlHeaders);
    } catch (e) {
      return _htmlError('Failed to load session info: $e');
    }
  });

  // GET /health-dashboard — HTML health dashboard.
  router.get('/health-dashboard', (Request request) async {
    try {
      final params = request.url.queryParameters;
      final verdictFilter = params['verdict'];
      final guardFilter = params['guard'];

      final allSessions = await sessions.listSessions();
      final sidebarData = await buildSidebarData(sessions);

      final status = await _getStatus(healthService, workerStateGetter, allSessions.length);

      final auditPage = await auditReader?.read(
            verdictFilter: verdictFilter,
            guardFilter: guardFilter,
          ) ??
          AuditPage.empty;

      final page = healthDashboardTemplate(
        status: status['status'] as String? ?? 'healthy',
        uptimeSeconds: status['uptime_s'] as int? ?? 0,
        workerState: status['worker_state'] as String? ?? 'unknown',
        sessionCount: status['session_count'] as int? ?? 0,
        dbSizeBytes: status['db_size_bytes'] as int? ?? 0,
        version: status['version'] as String? ?? 'unknown',
        sidebarData: sidebarData,
        auditPage: auditPage,
        verdictFilter: verdictFilter,
        guardFilter: guardFilter,
        bannerHtml: _restartBannerHtml(appDisplay.dataDir),
        appName: appDisplay.name,
      );

      return Response.ok(page, headers: htmlHeaders);
    } catch (e) {
      return _htmlError('Failed to load health dashboard: $e');
    }
  });

  // GET /health-dashboard/audit — HTMX fragment for audit table polling.
  router.get('/health-dashboard/audit', (Request request) async {
    try {
      final params = request.url.queryParameters;
      final page = int.tryParse(params['page'] ?? '') ?? 1;
      final verdict = params['verdict'];
      final guard = params['guard'];

      final auditPage = await auditReader?.read(
            page: page,
            verdictFilter: verdict,
            guardFilter: guard,
          ) ??
          AuditPage.empty;

      final html = auditTableFragment(
        auditPage: auditPage,
        verdictFilter: verdict,
        guardFilter: guard,
      );

      return Response.ok(html, headers: {
        ...htmlHeaders,
        'vary': 'HX-Request',
      });
    } catch (e) {
      return _htmlError('Failed to load audit table: $e');
    }
  });

  // GET /settings — settings hub.
  router.get('/settings', (Request request) async {
    try {
      final allSessions = await sessions.listSessions();
      final sidebarData = await buildSidebarData(sessions);

      final status = await _getStatus(healthService, workerStateGetter, allSessions.length);

      final gc = guardChain;
      final guardsEnabled = gc != null;
      final guardConfigs = extractGuardConfigs(
        gc,
        contentGuardDisplay: contentGuardDisplay,
      );

      final waStatus = await _whatsAppChannelStatus(whatsAppChannel);
      final sigStatus = await _signalChannelStatus(signalChannel);

      final page = settingsTemplate(
        sidebarData: sidebarData,
        uptimeSeconds: status['uptime_s'] as int? ?? 0,
        sessionCount: status['session_count'] as int? ?? 0,
        workerState: status['worker_state'] as String? ?? 'unknown',
        version: status['version'] as String? ?? 'unknown',
        whatsAppEnabled: whatsAppChannel != null,
        whatsAppStatusLabel: waStatus.label,
        whatsAppStatusClass: waStatus.badgeClass,
        whatsAppPhone: jidToPhone(whatsAppChannel?.gowa.pairedJid),
        whatsAppPendingCount: whatsAppChannel?.dmAccess.pendingPairings.length ?? 0,
        signalEnabled: signalEnabled,
        signalPhone: signalChannel?.sidecar.registeredPhone,
        signalStatusLabel: sigStatus.label,
        signalStatusClass: sigStatus.badgeClass,
        signalPendingCount: signalChannel?.dmAccess.pendingPairings.length ?? 0,
        guardsEnabled: guardsEnabled,
        guardFailOpen: gc?.failOpen ?? false,
        guardConfigs: guardConfigs,
        workspacePath: workspaceDisplay.path,
        bannerHtml: _restartBannerHtml(appDisplay.dataDir),
        appName: appDisplay.name,
      );

      return Response.ok(page, headers: htmlHeaders);
    } catch (e) {
      return _htmlError('Failed to load settings: $e');
    }
  });

  // GET /settings/channels/<type> — channel detail page.
  router.get('/settings/channels/<type>', (Request request, String type) async {
    try {
      if (type != 'whatsapp' && type != 'signal') {
        return _htmlNotFound('Unknown channel type: $type');
      }

      final sidebarData = await buildSidebarData(sessions);

      if (type == 'whatsapp') {
        final channel = whatsAppChannel;
        if (channel == null) {
          return _htmlNotFound('WhatsApp channel is not configured');
        }
        final status = await _whatsAppChannelStatus(channel);
        final page = channelDetailTemplate(
          channelType: 'whatsapp',
          channelLabel: 'WhatsApp',
          statusLabel: status.label,
          statusClass: status.badgeClass,
          phone: jidToPhone(channel.gowa.pairedJid),
          dmAccessMode: channel.dmAccess.mode.name,
          dmAccessModes: ['open', 'disabled', 'allowlist', 'pairing'],
          dmAllowlist: channel.dmAccess.allowlist.toList(),
          groupAccessMode: channel.config.groupAccess.name,
          groupAccessModes: ['open', 'disabled', 'allowlist'],
          groupAllowlist: channel.config.groupAllowlist.toList(),
          requireMention: channel.config.requireMention,
          entryPlaceholder: '15551234567@s.whatsapp.net',
          groupPlaceholder: '12345678@g.us',
          sidebarData: sidebarData,
          pendingPairings: _pendingPairingsData(channel.dmAccess),
          bannerHtml: _restartBannerHtml(appDisplay.dataDir),
          appName: appDisplay.name,
        );
        return Response.ok(page, headers: htmlHeaders);
      } else {
        final channel = signalChannel;
        if (channel == null) {
          return _htmlNotFound('Signal channel is not configured');
        }
        final status = await _signalChannelStatus(channel);
        final page = channelDetailTemplate(
          channelType: 'signal',
          channelLabel: 'Signal',
          statusLabel: status.label,
          statusClass: status.badgeClass,
          phone: channel.sidecar.registeredPhone,
          dmAccessMode: channel.dmAccess.mode.name,
          dmAccessModes: ['open', 'disabled', 'allowlist', 'pairing'],
          dmAllowlist: channel.dmAccess.allowlist.toList(),
          groupAccessMode: channel.config.groupAccess.name,
          groupAccessModes: ['open', 'disabled', 'allowlist'],
          groupAllowlist: channel.config.groupAllowlist.toList(),
          requireMention: channel.config.requireMention,
          entryPlaceholder: '+15551234567 or UUID',
          groupPlaceholder: 'base64-group-id',
          sidebarData: sidebarData,
          pendingPairings: _pendingPairingsData(channel.dmAccess),
          bannerHtml: _restartBannerHtml(appDisplay.dataDir),
          appName: appDisplay.name,
        );
        return Response.ok(page, headers: htmlHeaders);
      }
    } catch (e) {
      return _htmlError('Failed to load channel detail: $e');
    }
  });

  // GET /scheduling — scheduling status page.
  router.get('/scheduling', (Request request) async {
    try {
      final sidebarData = await buildSidebarData(sessions);

      final liveHb = runtimeConfig?.heartbeatEnabled ?? heartbeatDisplay.enabled;

      final page = schedulingTemplate(
        sidebarData: sidebarData,
        heartbeatEnabled: liveHb,
        heartbeatIntervalMinutes: heartbeatDisplay.intervalMinutes,
        jobs: schedulingDisplay.jobs,
        systemJobNames: schedulingDisplay.systemJobNames,
        bannerHtml: _restartBannerHtml(appDisplay.dataDir),
        appName: appDisplay.name,
      );

      return Response.ok(page, headers: htmlHeaders);
    } catch (e) {
      return _htmlError('Failed to load scheduling page: $e');
    }
  });

  // GET /memory — memory dashboard page.
  router.get('/memory', (Request request) async {
    try {
      final memService = memoryStatusService;
      if (memService == null) {
        return _htmlError('Memory dashboard not available — workspace not configured');
      }

      final sidebarData = await buildSidebarData(sessions);
      final status = await memService.getStatus();

      final page = memoryDashboardTemplate(
        status: status,
        sidebarData: sidebarData,
        workspacePath: workspaceDisplay.path ?? '~/.dartclaw/workspace/',
        bannerHtml: _restartBannerHtml(appDisplay.dataDir),
        appName: appDisplay.name,
      );

      return Response.ok(page, headers: htmlHeaders);
    } catch (e) {
      return _htmlError('Failed to load memory dashboard: $e');
    }
  });

  // GET /memory/content — HTMX fragment for 30s polling refresh.
  router.get('/memory/content', (Request request) async {
    try {
      final memService = memoryStatusService;
      if (memService == null) return _htmlError('Memory not configured');

      final status = await memService.getStatus();
      final fragment = memoryDashboardContentFragment(
        status: status,
        workspacePath: workspaceDisplay.path ?? '',
      );
      return htmlFragment(fragment);
    } catch (e) {
      return _htmlError('Failed to refresh memory data: $e');
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

Future<Map<String, dynamic>> _getStatus(
  HealthService? healthService,
  WorkerState? Function()? workerStateGetter,
  int sessionCount,
) async {
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

Future<ChannelStatus> _whatsAppChannelStatus(WhatsAppChannel? channel) async {
  if (channel == null) return ChannelStatus.disabled;
  final gowa = channel.gowa;
  if (!gowa.isRunning) {
    if (gowa.restartCount > 0) return ChannelStatus.reconnecting;
    return gowa.wasPaired ? ChannelStatus.connectionError : ChannelStatus.notRunning;
  }
  try {
    final status = await gowa.getStatus();
    return status.isLoggedIn ? ChannelStatus.connected : ChannelStatus.pairingNeeded;
  } catch (_) {
    return ChannelStatus.pairingNeeded;
  }
}

Future<ChannelStatus> _signalChannelStatus(SignalChannel? channel) async {
  if (channel == null) return ChannelStatus.disabled;
  final sidecar = channel.sidecar;
  if (!sidecar.isRunning) {
    if (sidecar.restartCount > 0) return ChannelStatus.reconnecting;
    return sidecar.wasPaired ? ChannelStatus.connectionError : ChannelStatus.notRunning;
  }
  try {
    final registered = await sidecar.isAccountRegistered();
    return registered ? ChannelStatus.connected : ChannelStatus.pairingNeeded;
  } catch (_) {
    return ChannelStatus.pairingNeeded;
  }
}

// ---------------------------------------------------------------------------
// HTMX SPA helpers
// ---------------------------------------------------------------------------

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
  headers: htmlHeaders,
);

Response _htmlError(String message) => Response.internalServerError(
  body: errorPageTemplate(500, 'Internal Server Error', message),
  headers: htmlHeaders,
);

List<Map<String, dynamic>> _pendingPairingsData(DmAccessController controller) {
  final now = DateTime.now();
  return controller.pendingPairings.map((p) {
    final remaining = p.expiresAt.difference(now).inMinutes;
    return {
      'code': p.code,
      'senderId': p.jid,
      'displayName': p.displayName,
      'remainingLabel': remaining > 0 ? '${remaining}m' : '<1m',
    };
  }).toList();
}

String _restartBannerHtml(String? dataDir) {
  if (dataDir == null) return '';
  final pending = readRestartPending(dataDir);
  if (pending == null) return '';
  final fields =
      (pending['fields'] as List<dynamic>?)?.whereType<String>().toList() ??
          [];
  return restartBannerTemplate(pendingFields: fields);
}
