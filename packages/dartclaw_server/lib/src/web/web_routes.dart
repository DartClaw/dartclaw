import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_google_chat/dartclaw_google_chat.dart';
import 'package:dartclaw_signal/dartclaw_signal.dart';
import 'package:dartclaw_storage/dartclaw_storage.dart' show TaskEventService, TurnTraceService;
import 'package:dartclaw_whatsapp/dartclaw_whatsapp.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../auth/auth_utils.dart';
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
import '../templates/layout.dart';
import '../templates/login.dart';
import '../templates/memory_dashboard.dart';
import '../memory/memory_status_service.dart';
import '../templates/session_info.dart';
import '../templates/sidebar.dart';
import '../templates/topbar.dart';
import '../runtime_config.dart';
import '../task/agent_observer.dart';
import '../task/goal_service.dart';
import '../task/task_progress_tracker.dart';
import '../task/task_service.dart';
import '../turn_manager.dart';
import 'dashboard_page.dart';
import 'page_registry.dart';
import 'page_support.dart';
import 'sidebar_feature_visibility.dart';
import 'system_pages.dart';
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
  bool cookieSecure = false,
  List<String> trustedProxies = const [],
  HealthService? healthService,
  WhatsAppChannel? whatsAppChannel,
  SignalChannel? signalChannel,
  GoogleChatChannel? googleChatChannel,
  GuardChain? guardChain,
  TurnManager? turns,
  RuntimeConfig? runtimeConfig,
  MemoryStatusService? memoryStatusService,
  ContentGuardDisplayParams contentGuardDisplay = const ContentGuardDisplayParams(),
  HeartbeatDisplayParams heartbeatDisplay = const HeartbeatDisplayParams(),
  SchedulingDisplayParams schedulingDisplay = const SchedulingDisplayParams(),
  WorkspaceDisplayParams workspaceDisplay = const WorkspaceDisplayParams(),
  AppDisplayParams appDisplay = const AppDisplayParams(),
  PageRegistry? pageRegistry,
  DartclawConfig? config,
  TaskService? taskService,
  GoalService? goalService,
  ProjectService? projectService,
  EventBus? eventBus,
  AgentObserver? agentObserver,
  KvService? kvService,
  TurnTraceService? traceService,
  TaskEventService? taskEventService,
  TaskProgressTracker? progressTracker,
  ThreadBindingStore? threadBindingStore,
  bool canvasEnabled = false,
}) {
  final router = Router();
  final auditReader = appDisplay.dataDir != null ? AuditLogReader(dataDir: appDisplay.dataDir!) : null;
  final defaultProvider = ProviderIdentity.normalize(config?.agent.provider);
  final registry = pageRegistry ?? PageRegistry();
  final visibility = computeSidebarFeatureVisibility(
    config: config,
    hasChannels: whatsAppChannel != null || signalChannel != null || googleChatChannel != null,
    guardChain: guardChain,
    hasHealthService: healthService != null,
    hasTaskService: taskService != null,
    hasPubSubHealth: healthService?.pubsubHealth != null,
    heartbeatDisplay: heartbeatDisplay,
    schedulingDisplay: schedulingDisplay,
    workspaceDisplay: workspaceDisplay,
  );
  if (pageRegistry == null) {
    registerSystemDashboardPages(
      registry,
      healthService: healthService,
      workerStateGetter: workerStateGetter,
      whatsAppChannel: whatsAppChannel,
      signalChannel: signalChannel,
      googleChatChannel: googleChatChannel,
      guardChain: guardChain,
      runtimeConfigGetter: () => runtimeConfig,
      memoryStatusServiceGetter: () => memoryStatusService,
      contentGuardDisplay: contentGuardDisplay,
      heartbeatDisplay: heartbeatDisplay,
      schedulingDisplay: schedulingDisplay,
      workspaceDisplay: workspaceDisplay,
      auditReader: auditReader,
      showHealth: visibility.showHealth,
      showMemory: visibility.showMemory,
      showScheduling: visibility.showScheduling,
      showTasks: visibility.showTasks,
      showCanvas: canvasEnabled,
    );
  }
  final systemNav = registry.navItems(activePage: '');
  final pageContext = PageContext(
    sessions: sessions,
    appDisplay: appDisplay,
    dataDir: appDisplay.dataDir,
    config: config,
    taskService: taskService,
    goalService: goalService,
    projectService: projectService,
    eventBus: eventBus,
    messages: messages,
    agentObserver: agentObserver,
    traceService: traceService,
    taskEventService: taskEventService,
    progressTracker: progressTracker,
    threadBindingStore: threadBindingStore,
    buildSidebarData: () => buildSidebarData(
      sessions,
      kvService: kvService,
      defaultProvider: defaultProvider,
      showChannels: visibility.showChannels,
      tasksEnabled: taskService != null && eventBus != null,
    ),
    restartBannerHtml: () => restartBannerHtml(appDisplay.dataDir),
    buildNavItems: ({required String activePage}) => registry.navItems(activePage: activePage),
  );

  // GET /login — render login page.
  router.get('/login', (Request request) {
    return Response.ok(
      loginPageTemplate(
        appName: appDisplay.name,
        nextPath: _sanitizeNextPath(request.url.queryParameters['next']),
        tokenValue: request.url.queryParameters['token'],
      ),
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
    final nextPath = _sanitizeNextPath(params['next']);

    if (!ts.validateToken(candidate)) {
      fireFailedAuthEvent(
        eventBus,
        request,
        source: 'login',
        reason: 'invalid_login_token',
        trustedProxies: trustedProxies,
      );
      return Response.ok(
        loginPageTemplate(error: 'Invalid token', nextPath: nextPath, tokenValue: candidate, appName: appDisplay.name),
        headers: htmlHeaders,
      );
    }

    final sessionToken = createSessionToken(gt);
    return _redirect(
      request,
      nextPath ?? '/',
      extraHeaders: {'set-cookie': sessionCookieHeader(sessionToken, secure: cookieSecure)},
    );
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

    final sidebarData = await buildSidebarData(
      sessions,
      kvService: kvService,
      defaultProvider: defaultProvider,
      showChannels: visibility.showChannels,
      tasksEnabled: taskService != null && eventBus != null,
    );
    final sidebar = sidebarTemplate(
      mainSession: sidebarData.main,
      dmChannels: sidebarData.dmChannels,
      groupChannels: sidebarData.groupChannels,
      activeEntries: sidebarData.activeEntries,
      archivedEntries: sidebarData.archivedEntries,
      showChannels: sidebarData.showChannels,
      tasksEnabled: sidebarData.tasksEnabled,
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

      final sidebarData = await buildSidebarData(
        sessions,
        kvService: kvService,
        defaultProvider: defaultProvider,
        showChannels: visibility.showChannels,
        tasksEnabled: taskService != null && eventBus != null,
      );
      final msgs = await messages.getMessagesTail(id);
      final messageList = msgs
          .map((m) => classifyMessage(id: m.id, role: m.role, content: m.content, senderName: null))
          .toList();
      final earliestCursor = msgs.isEmpty ? null : msgs.first.cursor;
      final hasEarlierMessages = earliestCursor != null && earliestCursor > 1;

      final sidebar = sidebarTemplate(
        mainSession: sidebarData.main,
        dmChannels: sidebarData.dmChannels,
        groupChannels: sidebarData.groupChannels,
        activeEntries: sidebarData.activeEntries,
        archivedEntries: sidebarData.archivedEntries,
        showChannels: sidebarData.showChannels,
        tasksEnabled: sidebarData.tasksEnabled,
        activeSessionId: id,
        navItems: systemNav,
        appName: appDisplay.name,
      );
      final topbar = topbarTemplate(
        title: session.title,
        sessionId: id,
        sessionType: session.type,
        appName: appDisplay.name,
      );
      final msgsHtml = messagesHtmlFragment(messageList);
      final bannerHtml = StringBuffer(restartBannerHtml(appDisplay.dataDir));
      if (workerStateGetter?.call() == WorkerState.crashed) {
        bannerHtml.write(
          '<div class="banner banner-warning">Agent interrupted — the worker will restart on next message. '
          'Retry your message.'
          '<button class="dismiss" aria-label="Dismiss" data-icon="x"></button></div>',
        );
      }
      if (turns?.consumeRecoveryNotice(id) ?? false) {
        bannerHtml.write(
          '<div class="banner banner-warning">This session recovered from an interrupted turn. '
          'Your conversation is intact.'
          '<button class="dismiss" aria-label="Dismiss" data-icon="x"></button></div>',
        );
      }
      final isArchive = session.type == SessionType.archive;
      final chat = chatAreaTemplate(
        sessionId: id,
        messagesHtml: msgsHtml,
        hasTitle: session.title != null && session.title!.trim().isNotEmpty,
        bannerHtml: bannerHtml.toString(),
        readOnly: isArchive,
        earliestCursor: earliestCursor,
        hasEarlierMessages: hasEarlierMessages,
      );

      if (wantsFragment(request)) {
        return htmlFragment('$chat$topbar$sidebar');
      }

      final bodyHtml = '<div class="shell">$sidebar$topbar$chat</div>';
      final page = layoutTemplate(title: session.title ?? 'New Chat', body: bodyHtml, appName: appDisplay.name);
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

      final beforeCursor = int.tryParse(request.url.queryParameters['before'] ?? '');
      final msgs = beforeCursor == null
          ? await messages.getMessagesTail(id)
          : await messages.getMessagesBefore(id, beforeCursor);
      final messageList = msgs
          .map((m) => classifyMessage(id: m.id, role: m.role, content: m.content, senderName: null))
          .toList();
      final earliestCursor = msgs.isEmpty ? null : msgs.first.cursor;
      final hasEarlierMessages = earliestCursor != null && earliestCursor > 1;
      final html = beforeCursor == null || messageList.isNotEmpty ? messagesHtmlFragment(messageList) : '';

      return Response.ok(
        html,
        headers: {
          ...htmlHeaders,
          'x-dartclaw-earliest-cursor': earliestCursor?.toString() ?? '',
          'x-dartclaw-has-earlier-messages': '$hasEarlierMessages',
        },
      );
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

      final recentTurns = msgs.reversed
          .take(8)
          .map((m) {
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
          })
          .toList()
          .reversed
          .toList();

      final usage = await _readSessionUsage(kvService, id, defaultProvider: defaultProvider);
      final page = sessionInfoTemplate(
        sessionId: id,
        sessionTitle: session.title ?? '',
        messageCount: msgs.length,
        sidebarData: await buildSidebarData(
          sessions,
          kvService: kvService,
          defaultProvider: defaultProvider,
          showChannels: visibility.showChannels,
          tasksEnabled: taskService != null && eventBus != null,
        ),
        navItems: systemNav,
        createdAt: session.createdAt.toIso8601String(),
        defaultProvider: defaultProvider,
        provider: usage.provider,
        inputTokens: usage.inputTokens,
        outputTokens: usage.outputTokens,
        estimatedCostUsd: usage.estimatedCostUsd,
        cachedInputTokens: usage.cachedInputTokens,
        bannerHtml: restartBannerHtml(appDisplay.dataDir),
        recentTurns: recentTurns,
        appName: appDisplay.name,
      );

      return Response.ok(page, headers: htmlHeaders);
    } catch (e) {
      return _htmlError('Failed to load session info: $e');
    }
  });

  // GET /health-dashboard/audit — HTMX fragment for audit table polling.
  router.get('/health-dashboard/audit', (Request request) async {
    try {
      final params = request.url.queryParameters;
      final page = int.tryParse(params['page'] ?? '') ?? 1;
      final verdict = params['verdict'];
      final guard = params['guard'];

      final auditPage =
          await auditReader?.read(page: page, verdictFilter: verdict, guardFilter: guard) ?? AuditPage.empty;

      final html = auditTableFragment(auditPage: auditPage, verdictFilter: verdict, guardFilter: guard);

      return Response.ok(html, headers: {...htmlHeaders, 'vary': 'HX-Request'});
    } catch (e) {
      return _htmlError('Failed to load audit table: $e');
    }
  });

  // GET /settings/channels/<type> — channel detail page.
  router.get('/settings/channels/<type>', (Request request, String type) async {
    try {
      if (type != 'whatsapp' && type != 'signal' && type != 'google_chat') {
        return _htmlNotFound('Unknown channel type: $type');
      }

      final sidebarData = await buildSidebarData(
        sessions,
        kvService: kvService,
        defaultProvider: defaultProvider,
        showChannels: visibility.showChannels,
        tasksEnabled: taskService != null && eventBus != null,
      );

      if (type == 'whatsapp') {
        final channel = whatsAppChannel;
        if (channel == null) {
          return _htmlNotFound('WhatsApp channel is not configured');
        }
        final status = await whatsAppChannelStatus(channel);
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
          taskTriggerEnabled: channel.config.taskTrigger.enabled,
          taskTriggerPrefix: channel.config.taskTrigger.prefix,
          taskTriggerDefaultType: channel.config.taskTrigger.defaultType,
          taskTriggerAutoStart: channel.config.taskTrigger.autoStart,
          entryPlaceholder: '15551234567@s.whatsapp.net',
          groupPlaceholder: '12345678@g.us',
          sidebarData: sidebarData,
          navItems: registry.navItems(activePage: 'Settings'),
          pendingPairings: pendingPairingsData(channel.dmAccess),
          bannerHtml: restartBannerHtml(appDisplay.dataDir),
          appName: appDisplay.name,
        );
        return Response.ok(page, headers: htmlHeaders);
      } else if (type == 'signal') {
        final channel = signalChannel;
        if (channel == null) {
          return _htmlNotFound('Signal channel is not configured');
        }
        final status = await signalChannelStatus(channel);
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
          taskTriggerEnabled: channel.config.taskTrigger.enabled,
          taskTriggerPrefix: channel.config.taskTrigger.prefix,
          taskTriggerDefaultType: channel.config.taskTrigger.defaultType,
          taskTriggerAutoStart: channel.config.taskTrigger.autoStart,
          entryPlaceholder: '+15551234567 or UUID',
          groupPlaceholder: 'base64-group-id',
          sidebarData: sidebarData,
          navItems: registry.navItems(activePage: 'Settings'),
          pendingPairings: pendingPairingsData(channel.dmAccess),
          bannerHtml: restartBannerHtml(appDisplay.dataDir),
          appName: appDisplay.name,
        );
        return Response.ok(page, headers: htmlHeaders);
      } else {
        final channel = googleChatChannel;
        if (channel == null) {
          return _htmlNotFound('Google Chat channel is not configured');
        }
        final dmAccess = channel.dmAccess;
        final page = channelDetailTemplate(
          channelType: 'google_chat',
          channelLabel: 'Google Chat',
          statusLabel: channel.config.enabled ? 'Connected' : 'Disconnected',
          statusClass: channel.config.enabled ? 'ok' : 'warn',
          dmAccessMode: dmAccess?.mode.name ?? 'pairing',
          dmAccessModes: ['open', 'disabled', 'allowlist', 'pairing'],
          dmAllowlist: dmAccess?.allowlist.toList() ?? [],
          groupAccessMode: channel.config.groupAccess.name,
          groupAccessModes: ['open', 'disabled', 'allowlist'],
          groupAllowlist: channel.config.groupAllowlist.toList(),
          requireMention: channel.config.requireMention,
          taskTriggerEnabled: channel.config.taskTrigger.enabled,
          taskTriggerPrefix: channel.config.taskTrigger.prefix,
          taskTriggerDefaultType: channel.config.taskTrigger.defaultType,
          taskTriggerAutoStart: channel.config.taskTrigger.autoStart,
          entryPlaceholder: 'users/123456789',
          groupPlaceholder: 'spaces/AAAA',
          sidebarData: sidebarData,
          navItems: registry.navItems(activePage: 'Settings'),
          pendingPairings: dmAccess != null ? pendingPairingsData(dmAccess) : [],
          bannerHtml: restartBannerHtml(appDisplay.dataDir),
          appName: appDisplay.name,
        );
        return Response.ok(page, headers: htmlHeaders);
      }
    } catch (e) {
      return _htmlError('Failed to load channel detail: $e');
    }
  });

  // GET /memory/content — HTMX fragment for 30s polling refresh.
  router.get('/memory/content', (Request request) async {
    try {
      final memService = memoryStatusService;
      if (memService == null) return _htmlError('Memory not configured');

      final status = await memService.getStatus();
      final fragment = memoryDashboardContentFragment(status: status, workspacePath: workspaceDisplay.path ?? '');
      return htmlFragment(fragment);
    } catch (e) {
      return _htmlError('Failed to refresh memory data: $e');
    }
  });

  for (final page in registry.pages) {
    router.get(page.route, (Request request) async {
      try {
        return await page.handler(request, pageContext);
      } catch (e) {
        return _htmlError('Failed to load ${page.title}: $e');
      }
    });
  }

  // Task detail sub-route: /tasks/<id>
  router.get('/tasks/<id>', (Request request, String id) async {
    try {
      final tasksPage = registry.resolve('/tasks');
      if (tasksPage == null) return _htmlNotFound('Tasks page not registered');
      return await tasksPage.handler(request, pageContext);
    } catch (e) {
      return _htmlError('Failed to load task detail: $e');
    }
  });

  return router;
}

Future<({int? inputTokens, int? outputTokens, int? cachedInputTokens, double? estimatedCostUsd, String provider})>
_readSessionUsage(KvService? kvService, String sessionId, {String defaultProvider = 'claude'}) async {
  if (kvService == null) {
    return (
      inputTokens: null,
      outputTokens: null,
      cachedInputTokens: null,
      estimatedCostUsd: null,
      provider: defaultProvider,
    );
  }

  final raw = await kvService.get('session_cost:$sessionId');
  if (raw == null) {
    return (
      inputTokens: null,
      outputTokens: null,
      cachedInputTokens: null,
      estimatedCostUsd: null,
      provider: defaultProvider,
    );
  }

  try {
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      return (
        inputTokens: null,
        outputTokens: null,
        cachedInputTokens: null,
        estimatedCostUsd: null,
        provider: defaultProvider,
      );
    }

    // Prefer canonical field names (written by TurnRunner post-S06);
    // fall back to legacy 'cached_input_tokens' for KV entries written
    // by older versions.
    final cacheReadTokens =
        (decoded['cache_read_tokens'] as num?)?.toInt() ??
        (decoded['cached_input_tokens'] as num?)?.toInt();
    return (
      inputTokens: (decoded['input_tokens'] as num?)?.toInt(),
      outputTokens: (decoded['output_tokens'] as num?)?.toInt(),
      cachedInputTokens: cacheReadTokens,
      estimatedCostUsd: (decoded['estimated_cost_usd'] as num?)?.toDouble(),
      provider: switch (decoded['provider']) {
        final String value when value.trim().isNotEmpty => value,
        _ => defaultProvider,
      },
    );
  } catch (e) {
    return (
      inputTokens: null,
      outputTokens: null,
      cachedInputTokens: null,
      estimatedCostUsd: null,
      provider: defaultProvider,
    );
  }
}

String? _sanitizeNextPath(String? rawValue) {
  final trimmed = rawValue?.trim();
  if (trimmed == null || trimmed.isEmpty) return null;
  if (!trimmed.startsWith('/')) return null;
  if (trimmed.startsWith('//')) return null;
  return trimmed;
}

// ---------------------------------------------------------------------------
// Sidebar data helper
// ---------------------------------------------------------------------------

/// Fetches and partitions all sessions for sidebar rendering.
Future<SidebarData> buildSidebarData(
  SessionService sessions, {
  KvService? kvService,
  String defaultProvider = 'claude',
  bool showChannels = true,
  bool tasksEnabled = false,
}) async {
  final all = await sessions.listSessions();
  SidebarSession? main;
  final dmChannels = <SidebarSession>[];
  final groupChannels = <SidebarSession>[];
  final activeEntries = <SidebarSession>[];
  final archivedEntries = <SidebarSession>[];

  for (final s in all) {
    final provider = await _resolveSidebarProvider(s, kvService, defaultProvider: defaultProvider);
    final entry = (id: s.id, title: s.title ?? '', type: s.type, provider: provider);
    switch (s.type) {
      case SessionType.main:
        main = entry;
      case SessionType.channel:
        if (_isGroupChannel(s.channelKey)) {
          groupChannels.add(entry);
        } else {
          dmChannels.add(entry);
        }
      case SessionType.cron:
        break; // hidden from sidebar
      case SessionType.task:
        break; // task sessions managed via /tasks page
      case SessionType.user:
        activeEntries.add(entry);
      case SessionType.archive:
        archivedEntries.add(entry);
    }
  }

  return (
    main: main,
    dmChannels: dmChannels,
    groupChannels: groupChannels,
    activeEntries: activeEntries,
    archivedEntries: archivedEntries,
    showChannels: showChannels,
    tasksEnabled: tasksEnabled,
  );
}

Future<String> _resolveSidebarProvider(
  Session session,
  KvService? kvService, {
  String defaultProvider = 'claude',
}) async {
  final sessionProvider = session.provider?.trim();
  if (sessionProvider != null && sessionProvider.isNotEmpty) {
    return ProviderIdentity.normalize(sessionProvider);
  }
  final usage = await _readSessionUsage(kvService, session.id, defaultProvider: defaultProvider);
  return usage.provider;
}

/// Returns true if the channel key represents a group session.
bool _isGroupChannel(String? channelKey) {
  if (channelKey == null) return false;
  try {
    return SessionKey.parse(channelKey).scope == 'group';
  } catch (e) {
    return false;
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

Response _htmlNotFound(String message) =>
    Response.notFound(errorPageTemplate(404, 'Page Not Found', message), headers: htmlHeaders);

Response _htmlError(String message) =>
    Response.internalServerError(body: errorPageTemplate(500, 'Internal Server Error', message), headers: htmlHeaders);
