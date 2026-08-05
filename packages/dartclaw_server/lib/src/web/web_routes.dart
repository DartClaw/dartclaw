import 'dart:io';

import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager;
import 'package:dartclaw_google_chat/dartclaw_google_chat.dart';
import 'package:dartclaw_signal/dartclaw_signal.dart';
import 'package:dartclaw_storage/dartclaw_storage.dart'
    show MemoryService, TaskEventService, TemporalKnowledgeGraphService, TurnTraceService;
import 'package:dartclaw_whatsapp/dartclaw_whatsapp.dart';
import 'package:dartclaw_workflow/dartclaw_workflow.dart' show WorkflowDefinitionSource, WorkflowService;
import 'package:path/path.dart' as p;
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
import '../session/session_display_title.dart';
import '../templates/session_info.dart';
import '../templates/sidebar.dart';
import '../templates/topbar.dart';
import '../templates/wiki_document.dart';
import '../runtime_config.dart';
import '../task/agent_observer.dart';
import '../task/goal_service.dart';
import '../task/task_progress_tracker.dart';
import '../task/task_service.dart';
import '../turn_manager.dart' show TurnManager;
import 'channel_status.dart';
import 'dashboard_page.dart';
import 'page_registry.dart';
import 'page_support.dart';
import 'session_usage.dart';
import 'sidebar_data_builder.dart';
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
  MemoryService? memoryService,
  TemporalKnowledgeGraphService? kgService,
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
  WorkflowService? workflowService,
  WorkflowDefinitionSource? workflowDefinitionSource,
}) {
  final router = Router();
  final auditReader = appDisplay.dataDir != null ? AuditLogReader(dataDir: appDisplay.dataDir!) : null;
  final defaultProvider = ProviderIdentity.normalize(config?.agent.provider);
  final registry = pageRegistry ?? PageRegistry();
  final visibility = computeSidebarFeatureVisibility(
    config: config,
    hasChannels: whatsAppChannel != null || signalChannel != null || googleChatChannel != null,
    hasTaskService: taskService != null,
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
      memoryServiceGetter: () => memoryService,
      kgServiceGetter: () => kgService,
      contentGuardDisplay: contentGuardDisplay,
      heartbeatDisplay: heartbeatDisplay,
      schedulingDisplay: schedulingDisplay,
      workspaceDisplay: workspaceDisplay,
      auditReader: auditReader,
      showMemory: visibility.showMemory,
      showScheduling: visibility.showScheduling,
      showTasks: visibility.showTasks,
      showWorkflows: workflowService != null,
    );
  }
  final systemNav = registry.navItems(activePage: '');
  final sidebarBuilder = SidebarDataBuilder(
    sessions: sessions,
    kvService: kvService,
    defaultProvider: defaultProvider,
    showChannels: visibility.showChannels,
    tasksEnabled: taskService != null && eventBus != null,
    taskService: taskService,
    workflowService: workflowService,
  );
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
    turns: turns,
    agentObserver: agentObserver,
    traceService: traceService,
    taskEventService: taskEventService,
    progressTracker: progressTracker,
    threadBindingStore: threadBindingStore,
    workflowService: workflowService,
    definitionSource: workflowDefinitionSource,
    sidebar: sidebarBuilder,
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

    final sidebarData = await pageContext.sidebar.build();
    final sidebar = buildSidebar(sidebarData: sidebarData, navItems: systemNav, appName: appDisplay.name);
    final topbar = topbarTemplate(appName: appDisplay.name, restartBannerHtml: restartBannerHtml(appDisplay.dataDir));
    final main = emptyAppStateTemplate(appName: appDisplay.name);
    final bodyHtml = '<div class="shell">$sidebar<div class="shell-main">$topbar$main</div></div>';
    final page = layoutTemplate(
      title: appDisplay.name,
      body: bodyHtml,
      appName: appDisplay.name,
      scripts: standardShellScripts(),
    );

    return Response.ok(page, headers: htmlHeaders);
  });

  // GET /sessions/<id> — full page or SPA fragment.
  router.get('/sessions/<id>', (Request request, String id) async {
    try {
      final session = await sessions.getSession(id);
      if (session == null) return _htmlNotFound('Session not found: $id');

      final sidebarData = await pageContext.sidebar.build(activeSessionId: id);
      final msgs = await messages.getMessagesTail(id);
      final messageList = msgs
          .map(
            (m) => classifyMessage(id: m.id, role: m.role, content: m.content, metadata: m.metadata, senderName: null),
          )
          .toList();
      final earliestCursor = msgs.isEmpty ? null : msgs.first.cursor;
      final hasEarlierMessages = earliestCursor != null && earliestCursor > 1;

      final sidebar = buildSidebar(sidebarData: sidebarData, navItems: systemNav, appName: appDisplay.name);
      final displayTitle = displaySessionTitle(session.title, session.type);
      final topbar = topbarTemplate(
        title: session.title,
        sessionId: id,
        sessionType: session.type,
        appName: appDisplay.name,
        restartBannerHtml: restartBannerHtml(appDisplay.dataDir),
      );
      final msgsHtml = messagesHtmlFragment(messageList);
      // Restart state is persistent shell chrome and lives in the topbar slot;
      // these two are one-shot, session-scoped notices and stay page-local.
      final chatNoticeHtml = StringBuffer();
      if (workerStateGetter?.call() == WorkerState.crashed) {
        chatNoticeHtml.write(
          '<div class="banner banner-warning">Agent interrupted — the worker will restart on next message. '
          'Retry your message.'
          '<button class="dismiss" aria-label="Dismiss" data-icon="x"></button></div>',
        );
      }
      if (turns?.consumeRecoveryNotice(id) ?? false) {
        chatNoticeHtml.write(
          '<div class="banner banner-warning">This session recovered from an interrupted turn. '
          'Your conversation is intact.'
          '<button class="dismiss" aria-label="Dismiss" data-icon="x"></button></div>',
        );
      }
      final isArchive = session.type == SessionType.archive;
      final turnStatus = turns?.turnStatus(id);
      final chat = chatAreaTemplate(
        sessionId: id,
        messagesHtml: msgsHtml,
        hasTitle: session.type == SessionType.main || (session.title != null && session.title!.trim().isNotEmpty),
        chatNoticeHtml: chatNoticeHtml.toString(),
        readOnly: isArchive,
        autofocus: messageList.isEmpty && !isArchive,
        isNewChatDraft:
            session.type == SessionType.user &&
            session.channelKey == null &&
            (session.provider == null || session.provider!.trim().isEmpty) &&
            (session.title == null || session.title!.trim().isEmpty) &&
            messageList.isEmpty &&
            !isActiveTurnStatusState(turnStatus?.state.name ?? 'idle'),
        earliestCursor: earliestCursor,
        hasEarlierMessages: hasEarlierMessages,
        turnStatus: turnStatus?.toJson(),
      );

      if (wantsFragment(request)) {
        final documentTitle = documentTitleFragment(title: displayTitle, appName: appDisplay.name);
        return htmlFragment('$documentTitle$chat$topbar$sidebar');
      }

      final bodyHtml = '<div class="shell">$sidebar<div class="shell-main">$topbar$chat</div></div>';
      final page = layoutTemplate(
        title: displayTitle,
        body: bodyHtml,
        appName: appDisplay.name,
        scripts: standardShellScripts(),
      );
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
          .map(
            (m) => classifyMessage(id: m.id, role: m.role, content: m.content, metadata: m.metadata, senderName: null),
          )
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

      final usage = await readSessionUsage(kvService, id, defaultProvider: defaultProvider);
      final page = sessionInfoTemplate(
        sessionId: id,
        sessionTitle: displaySessionTitle(session.title, session.type),
        messageCount: msgs.length,
        sidebarData: await pageContext.sidebar.build(),
        navItems: systemNav,
        createdAt: session.createdAt.toIso8601String(),
        defaultProvider: defaultProvider,
        provider: usage.provider,
        inputTokens: usage.inputTokens,
        outputTokens: usage.outputTokens,
        effectiveTokens: usage.effectiveTokens,
        estimatedCostUsd: usage.estimatedCostUsd,
        cachedInputTokens: usage.cachedInputTokens,
        restartBannerHtml: restartBannerHtml(appDisplay.dataDir),
        recentTurns: recentTurns,
        turnStatus: turns?.turnStatus(id).toJson(),
        appName: appDisplay.name,
      );

      return Response.ok(page, headers: htmlHeaders);
    } catch (e) {
      return _htmlError('Failed to load session info: $e');
    }
  });

  // GET /health-dashboard/audit — HTMX fragment for audit table polling, and
  // the full health page for a direct navigation. Rendered inline rather than
  // redirected: a redirect to /health-dashboard would drop page/verdict/guard.
  router.get('/health-dashboard/audit', (Request request) async {
    try {
      if (!wantsFragment(request)) {
        final healthPage = registry.resolve('/health-dashboard');
        if (healthPage == null) return _htmlNotFound('Health page not registered');
        return await healthPage.handler(request, pageContext);
      }

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

      final sidebarData = await pageContext.sidebar.build();

      if (type == 'whatsapp') {
        final channel = whatsAppChannel;
        final status = channel != null ? await whatsAppChannelStatus(channel) : ChannelStatus.disabled;
        final page = channelDetailTemplate(
          channelType: 'whatsapp',
          channelLabel: 'WhatsApp',
          status: status,
          phone: channel != null ? jidToPhone(channel.gowa.pairedJid) : null,
          dmAccessMode: channel?.dmAccess.mode.name ?? 'disabled',
          dmAccessModes: ['open', 'disabled', 'allowlist', 'pairing'],
          dmAllowlist: channel?.dmAccess.allowlist.toList() ?? const [],
          groupAccessMode: channel?.config.groupAccess.name ?? 'disabled',
          groupAccessModes: ['open', 'disabled', 'allowlist'],
          groupAllowlist: channel?.config.groupIds ?? const [],
          requireMention: channel?.config.requireMention ?? false,
          taskTriggerEnabled: channel?.config.taskTrigger.enabled ?? false,
          taskTriggerPrefix: channel?.config.taskTrigger.prefix ?? 'task:',
          taskTriggerDefaultType: channel?.config.taskTrigger.defaultType ?? 'research',
          taskTriggerAutoStart: channel?.config.taskTrigger.autoStart ?? true,
          entryPlaceholder: '15551234567@s.whatsapp.net',
          groupPlaceholder: '12345678@g.us',
          sidebarData: sidebarData,
          navItems: registry.navItems(activePage: 'Settings'),
          pendingPairings: channel != null ? pendingPairingsData(channel.dmAccess) : const [],
          restartBannerHtml: restartBannerHtml(appDisplay.dataDir),
          appName: appDisplay.name,
        );
        return Response.ok(page, headers: htmlHeaders);
      } else if (type == 'signal') {
        final channel = signalChannel;
        final status = channel != null ? await signalChannelStatus(channel) : ChannelStatus.disabled;
        final page = channelDetailTemplate(
          channelType: 'signal',
          channelLabel: 'Signal',
          status: status,
          phone: channel?.sidecar.registeredPhone,
          dmAccessMode: channel?.dmAccess.mode.name ?? 'disabled',
          dmAccessModes: ['open', 'disabled', 'allowlist', 'pairing'],
          dmAllowlist: channel?.dmAccess.allowlist.toList() ?? const [],
          groupAccessMode: channel?.config.groupAccess.name ?? 'disabled',
          groupAccessModes: ['open', 'disabled', 'allowlist'],
          groupAllowlist: channel?.config.groupIds ?? const [],
          requireMention: channel?.config.requireMention ?? false,
          taskTriggerEnabled: channel?.config.taskTrigger.enabled ?? false,
          taskTriggerPrefix: channel?.config.taskTrigger.prefix ?? 'task:',
          taskTriggerDefaultType: channel?.config.taskTrigger.defaultType ?? 'research',
          taskTriggerAutoStart: channel?.config.taskTrigger.autoStart ?? true,
          entryPlaceholder: '+15551234567 or UUID',
          groupPlaceholder: 'base64-group-id',
          sidebarData: sidebarData,
          navItems: registry.navItems(activePage: 'Settings'),
          pendingPairings: channel != null ? pendingPairingsData(channel.dmAccess) : const [],
          restartBannerHtml: restartBannerHtml(appDisplay.dataDir),
          appName: appDisplay.name,
        );
        return Response.ok(page, headers: htmlHeaders);
      } else {
        final channel = googleChatChannel;
        final dmAccess = channel?.dmAccess;
        final googleChatConfig =
            config?.getChannelConfig<GoogleChatConfig>(ChannelType.googlechat) ?? const GoogleChatConfig.disabled();
        final status = googleChatChannelStatus(channel, enabledInConfig: googleChatConfig.enabled);
        final page = channelDetailTemplate(
          channelType: 'google_chat',
          channelLabel: 'Google Chat',
          status: status,
          dmAccessMode: dmAccess?.mode.name ?? 'disabled',
          dmAccessModes: ['open', 'disabled', 'allowlist', 'pairing'],
          dmAllowlist: dmAccess?.allowlist.toList() ?? const [],
          groupAccessMode: channel?.config.groupAccess.name ?? 'disabled',
          groupAccessModes: ['open', 'disabled', 'allowlist'],
          groupAllowlist: channel?.config.groupIds ?? const [],
          requireMention: channel?.config.requireMention ?? false,
          taskTriggerEnabled: channel?.config.taskTrigger.enabled ?? false,
          taskTriggerPrefix: channel?.config.taskTrigger.prefix ?? 'task:',
          taskTriggerDefaultType: channel?.config.taskTrigger.defaultType ?? 'research',
          taskTriggerAutoStart: channel?.config.taskTrigger.autoStart ?? true,
          entryPlaceholder: 'users/123456789',
          groupPlaceholder: 'spaces/AAAA',
          sidebarData: sidebarData,
          navItems: registry.navItems(activePage: 'Settings'),
          pendingPairings: dmAccess != null ? pendingPairingsData(dmAccess) : const [],
          restartBannerHtml: restartBannerHtml(appDisplay.dataDir),
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

  // Every rejection returns one indistinguishable 404 so the route cannot be
  // used to probe the workspace for existence, type, or reachability.
  router.get('/knowledge/wiki/<sourcePath|.*>', (Request request, String sourcePath) async {
    final workspaceDir = workspaceDisplay.path;
    if (workspaceDir == null) return _wikiNotFound();
    final decoded = sourcePath.split('/').map(Uri.decodeComponent).join('/');
    if (!decoded.startsWith('wiki/') || !decoded.endsWith('.md')) return _wikiNotFound();
    final wikiRoot = p.normalize(p.absolute(p.join(workspaceDir, 'wiki')));
    final relativePath = decoded.substring('wiki/'.length);
    final filePath = p.normalize(p.absolute(p.join(wikiRoot, relativePath)));
    if (!p.isWithin(wikiRoot, filePath)) return _wikiNotFound();
    final file = File(filePath);
    if (!file.existsSync()) return _wikiNotFound();

    final String markdown;
    try {
      final canonicalWikiRoot = p.normalize(Directory(wikiRoot).resolveSymbolicLinksSync());
      final canonicalFilePath = p.normalize(file.resolveSymbolicLinksSync());
      if (!p.isWithin(canonicalWikiRoot, canonicalFilePath)) return _wikiNotFound();
      // Read the path that was verified, not the one that was requested: the
      // workspace is agent-writable, so re-resolving through `file` would let a
      // symlink swapped in after the check serve content from outside the root.
      markdown = File(canonicalFilePath).readAsStringSync();
    } on FileSystemException {
      return _wikiNotFound();
    }

    final page = wikiDocumentTemplate(
      title: p.basename(relativePath),
      markdown: markdown,
      sidebarData: await pageContext.sidebar.build(),
      navItems: registry.navItems(activePage: 'Knowledge'),
      restartBannerHtml: restartBannerHtml(appDisplay.dataDir),
      appName: appDisplay.name,
    );
    return Response.ok(page, headers: htmlHeaders);
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

  // Workflow detail sub-routes: /workflows/<runId> and /workflows/<runId>/steps/<stepIndex>
  // The page registry registers an exact /workflows match; parameterized sub-paths need
  // explicit entries here — same pattern as /tasks/<id> above.
  router.get('/workflows/<runId>', (Request request, String runId) async {
    try {
      final workflowsPage = registry.resolve('/workflows');
      if (workflowsPage == null) return _htmlNotFound('Workflows page not registered');
      return await workflowsPage.handler(request, pageContext);
    } catch (e) {
      return _htmlError('Failed to load workflow detail: $e');
    }
  });
  router.get('/workflows/<runId>/steps/<stepIndex>', (Request request, String runId, String stepIndex) async {
    try {
      final workflowsPage = registry.resolve('/workflows');
      if (workflowsPage == null) return _htmlNotFound('Workflows page not registered');
      return await workflowsPage.handler(request, pageContext);
    } catch (e) {
      return _htmlError('Failed to load workflow step detail: $e');
    }
  });

  return router;
}

String? _sanitizeNextPath(String? rawValue) {
  final trimmed = rawValue?.trim();
  if (trimmed == null || trimmed.isEmpty) return null;
  if (!trimmed.startsWith('/')) return null;
  if (trimmed.startsWith('//')) return null;
  return trimmed;
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

/// The single opaque rejection for `/knowledge/wiki/<path>`.
///
/// Every guard shares it so status, content type and body stay byte-identical
/// across missing workspace, bad locator, traversal, symlink escape and I/O
/// failure — no branch is distinguishable from the response.
Response _wikiNotFound() => _htmlNotFound('Wiki source not found');

Response _htmlError(String message) =>
    Response.internalServerError(body: errorPageTemplate(500, 'Internal Server Error', message), headers: htmlHeaders);
