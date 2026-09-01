import 'dart:io';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager;
import 'package:dartclaw_google_chat/dartclaw_google_chat.dart';
import 'package:dartclaw_signal/dartclaw_signal.dart';
import 'package:dartclaw_whatsapp/dartclaw_whatsapp.dart';
import 'package:dartclaw_workflow/dartclaw_workflow.dart' show WorkflowDefinitionSource, WorkflowService;
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../api/api_helpers.dart';
import '../auth/auth_utils.dart';
import '../auth/session_token.dart';
import '../auth/token_service.dart';
import '../health/health_service.dart';
import '../project/project_mutation_service.dart';
import '../templates/chat.dart';
import '../templates/components.dart';
import '../templates/error_page.dart';
import '../audit/audit_log_reader.dart';
import '../templates/audit_table.dart';
import '../templates/layout.dart';
import '../templates/login.dart';
import '../templates/memory_dashboard.dart';
import '../memory/memory_status_service.dart';
import '../memory/memory_prune_service.dart';
import '../session/session_display_title.dart';
import '../templates/session_info.dart';
import '../templates/sidebar.dart';
import '../templates/topbar.dart';
import '../templates/wiki_document.dart';
import '../runtime_config.dart';
import '../task/runner_observer.dart';
import '../task/goal_service.dart';
import '../task/task_progress_tracker.dart';
import '../task/task_action_service.dart';
import '../task/task_creation_service.dart';
import '../task/task_service.dart';
import '../turn_manager.dart' show TurnManager;
import 'dashboard_page.dart';
import 'page_registry.dart';
import 'page_support.dart';
import 'pages/settings_page.dart';
import 'session_usage.dart';
import 'sidebar_data_builder.dart';
import 'sidebar_feature_visibility.dart';
import 'system_pages.dart';
import 'web_utils.dart';

/// Caps the unauthenticated login form read: a token and a next-path only.
const _maxLoginFormBytes = 8 * 1024;

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
  MemoryPruneService? memoryPruneService,
  MemoryService? memoryService,
  TemporalKnowledgeGraphService? kgService,
  String? dataDir,
  bool contentGuardApiKeyConfigured = false,
  bool contentGuardFailOpen = false,
  List<Map<String, dynamic>> schedulingJobs = const [],
  List<String> systemJobNames = const [],
  PageRegistry? pageRegistry,
  DartclawConfig? config,
  TaskService? taskService,
  TaskCreationService? taskCreationService,
  TaskActionService? taskActionService,
  GoalService? goalService,
  ProjectService? projectService,
  ProjectMutationService? projectMutations,
  EventBus? eventBus,
  RunnerObserver? runnerObserver,
  KvService? kvService,
  TurnTraceService? traceService,
  TaskEventService? taskEventService,
  TaskProgressTracker? progressTracker,
  ThreadBindingStore? threadBindingStore,
  WorkflowService? workflowService,
  WorkflowDefinitionSource? workflowDefinitionSource,
}) {
  final router = Router();
  final auditReader = dataDir != null ? AuditLogReader(dataDir: dataDir) : null;
  final appName = config?.server.name ?? 'DartClaw';
  final defaultProvider = ProviderIdentity.normalize(config?.agent.provider);
  final registry = pageRegistry ?? PageRegistry();
  final visibility = computeSidebarFeatureVisibility(
    config: config,
    hasChannels: whatsAppChannel != null || signalChannel != null || googleChatChannel != null,
    hasTaskService: taskService != null,
    schedulingJobs: schedulingJobs,
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
      memoryPruneServiceGetter: () => memoryPruneService,
      memoryServiceGetter: () => memoryService,
      kgServiceGetter: () => kgService,
      config: config,
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
    dataDir: dataDir,
    config: config,
    contentGuardApiKeyConfigured: contentGuardApiKeyConfigured,
    contentGuardFailOpen: contentGuardFailOpen,
    schedulingJobs: schedulingJobs,
    systemJobNames: systemJobNames,
    taskService: taskService,
    taskCreationService: taskCreationService,
    taskActionService: taskActionService,
    goalService: goalService,
    projectService: projectService,
    projectMutations: projectMutations,
    eventBus: eventBus,
    messages: messages,
    turns: turns,
    runnerObserver: runnerObserver,
    traceService: traceService,
    taskEventService: taskEventService,
    progressTracker: progressTracker,
    threadBindingStore: threadBindingStore,
    workflowService: workflowService,
    definitionSource: workflowDefinitionSource,
    sidebar: sidebarBuilder,
    restartBannerHtml: () => restartBannerHtml(dataDir),
    buildNavItems: ({required String activePage}) => registry.navItems(activePage: activePage),
  );

  // GET /login — render login page.
  router.get('/login', (Request request) {
    return Response.ok(
      loginPageTemplate(
        appName: appName,
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

    final bodyResult = await readRequestBody(request, maxBytes: _maxLoginFormBytes);
    if (bodyResult.error != null) return bodyResult.error!;
    final params = Uri.splitQueryString(bodyResult.body!);
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
        loginPageTemplate(error: 'Invalid token', nextPath: nextPath, tokenValue: candidate, appName: appName),
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

  // The settings form predates page-declared routes; its registered page is
  // still the only source of a writable surface.
  router.post('/settings', (Request request) async {
    final page = registry.resolve('/settings');
    final surface = page is SettingsPage ? page.settingsSurface : null;
    if (surface == null) return _htmlNotFound('Settings editing is not available on this server');
    return surface.handleSubmit(request);
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
    final sidebar = buildSidebar(sidebarData: sidebarData, navItems: systemNav, appName: appName);
    final topbar = topbarTemplate(appName: appName, restartBannerHtml: restartBannerHtml(dataDir));
    final main = emptyAppStateTemplate(appName: appName);
    final bodyHtml = '<div class="shell">$sidebar<div class="shell-main">$topbar$main</div></div>';
    final page = layoutTemplate(title: appName, body: bodyHtml, appName: appName, scripts: standardShellScripts());

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

      final sidebar = buildSidebar(sidebarData: sidebarData, navItems: systemNav, appName: appName);
      final displayTitle = displaySessionTitle(session.title, session.type);
      final topbar = topbarTemplate(
        title: session.title,
        sessionId: id,
        sessionType: session.type,
        appName: appName,
        restartBannerHtml: restartBannerHtml(dataDir),
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
        final documentTitle = documentTitleFragment(title: displayTitle, appName: appName);
        return htmlFragment('$documentTitle$chat$topbar$sidebar');
      }

      final bodyHtml = '<div class="shell">$sidebar<div class="shell-main">$topbar$chat</div></div>';
      final page = layoutTemplate(
        title: displayTitle,
        body: bodyHtml,
        appName: appName,
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
        restartBannerHtml: restartBannerHtml(dataDir),
        recentTurns: recentTurns,
        turnStatus: turns?.turnStatus(id).toJson(),
        appName: appName,
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

  // GET /memory/content — HTMX fragment for 30s polling refresh.
  router.get('/memory/content', (Request request) async {
    try {
      final memService = memoryStatusService;
      if (memService == null) return _htmlError('Memory not configured');

      final status = await memService.getStatus();
      final fragment = memoryDashboardContentFragment(status: status, workspacePath: config?.workspaceDir ?? '');
      return htmlFragment(fragment);
    } catch (e) {
      return _htmlError('Failed to refresh memory data: $e');
    }
  });

  // Every rejection returns one indistinguishable 404 so the route cannot be
  // used to probe the workspace for existence, type, or reachability.
  router.get('/knowledge/wiki/<sourcePath|.*>', (Request request, String sourcePath) async {
    final workspaceDir = config?.workspaceDir;
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
      restartBannerHtml: restartBannerHtml(dataDir),
      appName: appName,
    );
    return Response.ok(page, headers: htmlHeaders);
  });

  for (final page in registry.pages) {
    Future<Response> servePage(Request request) async {
      try {
        return await page.handler(request, pageContext);
      } catch (e) {
        return _htmlError('Failed to load ${page.title}: $e');
      }
    }

    router.get(page.route, servePage);
    for (final declared in page.declaredRoutes) {
      router.add(declared.method, declared.path, servePage);
    }
  }

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
