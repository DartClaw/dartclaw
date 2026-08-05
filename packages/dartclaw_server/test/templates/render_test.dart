import 'dart:io';

import 'package:dartclaw_server/src/templates/chat.dart' show richInputHtmlFromMetadataMap;
import 'package:dartclaw_server/src/templates/components.dart';
import 'package:dartclaw_server/src/templates/error_page.dart';
import 'package:dartclaw_server/src/templates/layout.dart';
import 'package:dartclaw_server/src/templates/loader.dart' as server;
import 'package:dartclaw_server/src/templates/login.dart';
import 'package:dartclaw_server/src/version.dart';
import 'package:test/test.dart';
import 'package:trellis/trellis.dart';

import '../test_utils.dart';

void _expectAll(String html, Iterable<String> needles) {
  for (final needle in needles) {
    expect(html, contains(needle));
  }
}

void _expectNone(String html, Iterable<String> needles) {
  for (final needle in needles) {
    expect(html, isNot(contains(needle)));
  }
}

Map<String, dynamic> _sidebarContext(Map<String, dynamic> overrides) => {
  'mainSession': false,
  'mainHref': '',
  'mainActive': false,
  'tasksEnabledAttr': null,
  'showChannels': true,
  'noChannels': true,
  'noDmChannels': true,
  'hasGroupChannels': false,
  'showDmLabel': false,
  'dmChannels': <Map<String, dynamic>>[],
  'groupChannels': <Map<String, dynamic>>[],
  'noActiveEntries': true,
  'activeEntries': <Map<String, dynamic>>[],
  'hasArchivedEntries': false,
  'archivedEntries': <Map<String, dynamic>>[],
  'archivedCount': 0,
  'archiveContainsActive': false,
  'hasNav': false,
  'showSystemNav': false,
  'showExtensionNav': false,
  'systemMenuLabel': 'System',
  'systemNavItems': <Map<String, dynamic>>[],
  'extensionNavItems': <Map<String, dynamic>>[],
  ...overrides,
};

/// Session info's title/session-id head is the shared `pageHeader` fragment, so
/// the page-level tests compose it through the same engine rather than pinning a
/// literal – a change to the fragment's anatomy must reach these cases.
Future<String> _sessionHeader(Trellis engine, {required String title, required String sessionId}) =>
    engine.renderFileFragment(
      'components',
      fragment: 'pageHeader',
      context: {'title': title, 'subtitle': sessionId, 'actionsHtml': null},
    );

Map<String, dynamic> _sessionInfoContext(Map<String, dynamic> overrides) => {
  'sessionId': 'abc-123',
  'inputStr': '1.2K',
  'outputStr': '3.4K',
  'totalStr': '4.6K',
  'tokenMetricCardsHtml':
      '''<div class="card card-metric card-metric--info"><div class="metric-value">1.2K</div><div class="metric-label">Input</div></div><div class="card card-metric card-metric--info"><div class="metric-value">3.4K</div><div class="metric-label">Output</div></div><div class="card card-metric card-metric--accent"><div class="metric-value">4.6K</div><div class="metric-label">Total</div></div>''',
  'messageCount': 42,
  'createdAt': '2025-01-15',
  'sidebar': '',
  'topbar': '',
  ...overrides,
};

Map<String, dynamic> _settingsContext(Map<String, dynamic> overrides) => {
  'whatsAppEnabled': false,
  'signalConnected': false,
  'signalDisconnected': false,
  'signalNotConfigured': true,
  'signalEnabled': false,
  'googleChatEnabled': false,
  'signalPhone': '',
  'guardsActive': false,
  'activeGuardCount': 0,
  'activeGuards': <String>[],
  'schedulingActive': false,
  'scheduledJobsCount': 0,
  'heartbeatDisplay': 'disabled',
  'healthBadgeHtml': '<span class="status-badge status-badge-success">Healthy</span>',
  'whatsAppStatusBadgeHtml': '<span class="status-badge status-badge-muted">Disabled</span>',
  'signalStatusBadgeHtml': '<span class="status-badge status-badge-muted">Disabled</span>',
  'googleChatStatusBadgeHtml': '<span class="status-badge status-badge-muted">Disabled</span>',
  'uptimeStr': '1h 30m',
  'sessionCount': 5,
  'version': '0.3.0',
  'gitSyncEnabled': false,
  'workspacePathDisplay': '~/.dartclaw/workspace/',
  'gitSyncDisplay': 'Disabled',
  'sidebar': '',
  'topbar': '',
  ...overrides,
};

void main() {
  final templatesDir = Directory('lib/src/templates').existsSync()
      ? 'lib/src/templates'
      : 'packages/dartclaw_server/lib/src/templates';
  late Trellis engine;

  setUpAll(() {
    engine = Trellis(loader: FileSystemLoader(templatesDir));
  });

  group('TemplateLoader', () {
    test('validates and renders known templates', () {
      final loader = server.TemplateLoaderService(templatesDir);
      loader.validate();

      final html = loader.trellis.render(loader.source('error_page'), {
        'code': 404,
        'title': 'Not Found',
        'detail': 'Gone',
      });
      _expectAll(html, ['404', 'Not Found']);
    });

    test('reports missing and unknown templates', () {
      final tmpDir = Directory.systemTemp.createTempSync('tpl_test_');
      addTearDown(() => tmpDir.deleteSync(recursive: true));

      final missingLoader = server.TemplateLoaderService(tmpDir.path);
      expect(() => missingLoader.validate(), throwsA(isA<StateError>()));
      try {
        missingLoader.validate();
        fail('Expected StateError');
      } on StateError catch (error) {
        _expectAll(error.message, ['Missing templates', 'error_page.html', 'login.html']);
      }

      final loader = server.TemplateLoaderService(templatesDir);
      expect(() => loader.source('nonexistent'), throwsA(isA<StateError>()));
    });
  });

  group('basic fragments', () {
    test('error page renders content, escapes input, and links home', () async {
      final html = await engine.renderFileFragment(
        'error_page',
        fragment: 'errorPage',
        context: {'code': 400, 'title': '<Bad Request>', 'detail': 'x&y'},
      );
      _expectAll(html, ['400', '&lt;Bad Request&gt;', 'x&amp;y', 'href="/"', 'Back to Home']);
    });

    test('login renders form states', () async {
      final empty = await engine.renderFileFragment('login', fragment: 'loginPage', context: {'error': null});
      _expectAll(empty, [
        'terminal-frame terminal-frame--crt login-terminal',
        'terminal-frame-bar',
        'terminal-frame-dots',
        'terminal-frame-body',
        'login-mascot pixel-art',
        'login-wordmark',
        'login-form',
        'name="token"',
        'type="password"',
        'name="remember"',
      ]);
      expect(empty, isNot(contains('login-error')));

      final withError = await engine.renderFileFragment(
        'login',
        fragment: 'loginPage',
        context: {'error': 'Invalid token', 'appName': 'DartClaw', 'nextPath': '/tasks?status=review'},
      );
      _expectAll(withError, [
        'login-error',
        'Invalid token',
        'DartClaw',
        'name="next"',
        'value="/tasks?status=review"',
      ]);
    });

    test('components render banner and empty states', () async {
      final banner = await engine.renderFileFragment(
        'components',
        fragment: 'banner',
        context: {'type': 'warning', 'message': '<b>oops</b>'},
      );
      _expectAll(banner, ['banner-warning', '&lt;b&gt;oops']);

      final emptyState = await engine.renderFileFragment(
        'components',
        fragment: 'emptyState',
        context: const {'title': 'No messages yet', 'body': 'Send a message to start the conversation.'},
      );
      _expectAll(emptyState, ['No messages yet', 'empty-state', '❯_']);
      expect(emptyState, isNot(anyOf(contains('claw-mark'), contains('mascot-'))));

      final emptyAppState = await engine.renderFileFragment('components', fragment: 'emptyAppState', context: const {});
      // The empty-install state uses the same brand recipe as the generic
      // fragment's mascot variant: one 64px decorative mascot, a titled
      // headline, and a verb+noun action with an icon rather than a '+ ' label.
      _expectAll(emptyAppState, [
        'No chats yet',
        'empty-state-title',
        'mascot-avatar-512-8bit.png',
        'class="pixel-art"',
        'alt=""',
        'data-icon="plus"',
        '>New Chat<',
      ]);
      expect(emptyAppState, isNot(contains('❯_')));
      expect(emptyAppState, isNot(contains('+ New Chat')));
      expect(emptyAppState, isNot(contains('claw-mark')));
      expect(emptyAppState, isNot(contains('data-dc-legacy-action')));
    });
  });

  group('layout and topbars', () {
    test('layout includes document chrome, assets, requested scripts, and escaped title', () async {
      final html = await engine.renderFile('layout', {
        'title': '<script>xss</script>',
        'body': '<p>Hello</p>',
        'appName': 'DartClaw',
        'assetPrefix': '/static/v$dartclawVersion',
        'scriptsHtml': '<script defer="defer" src="/static/extra-page.js"></script>',
      });
      _expectAll(html, [
        '<!DOCTYPE html>',
        '&lt;script&gt;',
        '/static/v$dartclawVersion/htmx.min.js',
        '/static/v$dartclawVersion/marked.min.js',
        'purify.min.js',
        '/static/v$dartclawVersion/fonts/jetbrains-mono-latin.woff2',
        '/static/v$dartclawVersion/tokens.css',
        '/static/v$dartclawVersion/app-tokens.css',
        '/static/v$dartclawVersion/design-system.css',
        '/static/v$dartclawVersion/app.css',
        '/static/v$dartclawVersion/mascot-favicon-32.png',
        '/static/v$dartclawVersion/mascot-favicon-16.png',
        '/static/v$dartclawVersion/controllers/index.js',
        '/static/extra-page.js',
      ]);
      _expectNone(html, ['<script>xss</script>', '/static/app.js', '/static/settings.js', 'href="data:,"']);

      // Every runtime dependency is vendored, so the rendered layout must name
      // no external origin at all. Asserting the absence of any scheme (rather
      // than of the specific hosts once loaded here) also catches a CDN nobody
      // predicted, and catches it in the rendered output rather than the source
      // template, where `${assetPrefix}` has already been applied.
      _expectNone(html, ['https://', 'http://', 'src="//', 'href="//']);

      // htmx must execute before the SSE extension registers against it; both
      // are `defer`, so document order is execution order.
      expect(
        html.indexOf('/static/v$dartclawVersion/htmx.min.js'),
        lessThan(html.indexOf('/static/v$dartclawVersion/sse.js')),
      );
    });

    test('topbar fragments render expected controls', () async {
      final session = await engine.renderFileFragment(
        'topbar',
        fragment: 'sessionTopbar',
        context: {
          'displayTitle': 'My Chat',
          'sessionId': 'sess-1',
          'isWorkspace': false,
          'isArchive': false,
          'isEditable': true,
          'showResume': false,
          'showReset': true,
          'infoHref': '/sessions/sess-1/info',
          'resetHref': '/api/sessions/sess-1/reset',
        },
      );
      _expectAll(session, ['session-title', 'My Chat', 'sess-1', 'data-icon="menu"', 'data-icon="info"']);

      final archive = await engine.renderFileFragment(
        'topbar',
        fragment: 'sessionTopbar',
        context: {
          'displayTitle': 'Old Chat',
          'sessionId': 'a1',
          'isWorkspace': false,
          'isArchive': true,
          'isEditable': false,
          'showResume': true,
          'showReset': false,
          'infoHref': '/sessions/a1/info',
          'resetHref': '/api/sessions/a1/reset',
        },
      );
      expect(archive, contains('>Resume<'));

      final plain = await engine.renderFileFragment(
        'topbar',
        fragment: 'plainTopbar',
        context: const {'appName': 'DartClaw'},
      );
      _expectAll(plain, ['DartClaw', 'theme-toggle', 'data-icon="menu"']);

      final page = await engine.renderFileFragment(
        'topbar',
        fragment: 'pageTopbar',
        context: {'title': 'Settings', 'backHref': '/', 'backLabel': 'Back'},
      );
      _expectAll(page, ['Settings', 'href="/"', 'icon-arrow-left']);
    });
  });

  group('sidebar.html', () {
    test('archived session delete carries the escaped title, not just the id', () async {
      // The delete confirmation names the chat the way the sidebar does, so a
      // hostile title must survive as attribute text rather than as markup.
      final html = await engine.renderFileFragment(
        'sidebar',
        fragment: 'sidebar',
        context: _sidebarContext({
          'hasArchivedEntries': true,
          'archivedEntries': [
            {
              'id': 's2',
              'href': '/sessions/s2',
              'active': false,
              'extraClass': '',
              'title': 'Deploy "prod" <now> & wait',
              'provider': 'claude',
              'providerLabel': 'Claude',
              'showProvider': true,
            },
          ],
          'archivedCount': 1,
        }),
      );

      expect(html, contains('data-session-id="s2"'));
      expect(html, contains('data-session-title="Deploy &quot;prod&quot; <now> &amp; wait"'));
      expect(html, isNot(contains('data-session-title="Deploy "prod"')));
    });

    test('renders empty, provider, navigation, and action states', () async {
      final empty = await engine.renderFileFragment('sidebar', fragment: 'sidebar', context: _sidebarContext({}));
      _expectAll(empty, ['No active channels', 'No chats yet']);

      final providers = await engine.renderFileFragment(
        'sidebar',
        fragment: 'sidebar',
        context: _sidebarContext({
          'mainSession': true,
          'mainHref': '/sessions/main',
          'mainActive': true,
          'mainProvider': 'claude',
          'mainProviderLabel': 'Claude',
          'noChannels': false,
          'noDmChannels': false,
          'hasGroupChannels': true,
          'showDmLabel': true,
          'dmChannels': [
            {
              'id': 'dm-1',
              'href': '/sessions/dm-1',
              'active': false,
              'title': 'DM session',
              'provider': 'codex',
              'providerLabel': 'Codex',
              'showProvider': true,
            },
          ],
          'groupChannels': [
            {
              'id': 'group-1',
              'href': '/sessions/group-1',
              'active': false,
              'title': 'Group session',
              'provider': 'claude',
              'providerLabel': 'Claude',
              'showProvider': true,
            },
          ],
          'noActiveEntries': false,
          'activeEntries': [
            {
              'id': 's1',
              'href': '/sessions/s1',
              'active': true,
              'extraClass': 'active',
              'title': 'Active session',
              'provider': 'codex',
              'providerLabel': 'Codex',
              'showProvider': true,
            },
          ],
          'hasArchivedEntries': true,
          'archivedEntries': [
            {
              'id': 's2',
              'href': '/sessions/s2',
              'active': false,
              'extraClass': '',
              'title': 'Archived session',
              'provider': 'claude',
              'providerLabel': 'Claude',
              'showProvider': true,
            },
          ],
          'archivedCount': 1,
        }),
      );
      _expectAll(providers, [
        'provider-badge',
        'provider-badge-claude',
        'provider-badge-codex',
        'Claude',
        'Codex',
        'data-icon="terminal"',
        'data-identicon-id="dm-1"',
        'data-identicon-id="group-1"',
        'data-identicon-id="s1"',
        'data-identicon-id="s2"',
        'data-icon="new-session"',
        'class="btn-new-session-label">New Chat</span>',
        'data-icon="x"',
        'data-icon="archive"',
        'data-icon="chevron-down"',
      ]);
      expect(providers, isNot(anyOf(contains('data-icon="hash"'), contains('data-icon="message-circle"'))));

      final entries = await engine.renderFileFragment(
        'sidebar',
        fragment: 'sidebar',
        context: _sidebarContext({
          'noActiveEntries': false,
          'activeEntries': [
            {'id': 's1', 'href': '/sessions/s1', 'active': true, 'extraClass': 'active', 'title': 'Research'},
            {'id': 'active-1', 'href': '/sessions/active-1', 'active': false, 'extraClass': '', 'title': 'Active chat'},
          ],
          'hasArchivedEntries': true,
          'archivedEntries': [
            {
              'id': 'archived-1',
              'href': '/sessions/archived-1',
              'active': false,
              'extraClass': '',
              'title': 'Archived chat',
            },
          ],
          'archivedCount': 1,
        }),
      );
      _expectAll(entries, [
        'hx-target="#main-content"',
        'hx-push-url="true"',
        // Navigation replaces the restart slot alongside the topbar, so the
        // banner cannot survive as stale chrome from the previous page.
        'hx-select-oob="#topbar,#restart-banner-slot,#sidebar"',
        'Research',
        'data-session-archive="true"',
        'data-session-delete="true"',
        'class="session-action session-archive"',
        'class="delete-btn session-delete"',
        'aria-label="Archive chat"',
        'aria-label="Delete session"',
      ]);

      final nav = await engine.renderFileFragment(
        'sidebar',
        fragment: 'sidebar',
        context: _sidebarContext({
          'hasNav': true,
          'showSystemNav': true,
          'showExtensionNav': true,
          'systemMenuLabel': 'System · Health',
          'systemNavItems': [
            {'label': 'Health', 'href': '/health-dashboard', 'active': true, 'ariaCurrent': 'page', 'icon': 'health'},
            {'label': 'Settings', 'href': '/settings', 'active': false, 'ariaCurrent': null, 'icon': 'settings'},
          ],
          'extensionNavItems': [
            {'label': 'Optional', 'href': '/optional', 'active': false, 'ariaCurrent': null, 'icon': null},
          ],
        }),
      );
      _expectAll(nav, [
        'sidebar-system-menu',
        'System · Health',
        'aria-label="System navigation"',
        'Health',
        'Settings',
        'Optional',
        'sidebar-nav-item',
        'data-icon="health"',
        'data-icon="settings"',
      ]);
      expect(nav, isNot(contains('data-icon="null"')));
    });
  });

  group('session_info.html', () {
    test('renders token usage, provider cost states, and escaped title', () async {
      final basic = await engine.renderFileFragment(
        'session_info',
        fragment: 'sessionInfo',
        context: _sessionInfoContext({
          'pageHeaderHtml': await _sessionHeader(engine, title: 'My Research', sessionId: 'abc-123'),
        }),
      );
      _expectAll(basic, ['My Research', 'abc-123', '1.2K', '3.4K', '4.6K', '42']);

      final claude = await engine.renderFileFragment(
        'session_info',
        fragment: 'sessionInfo',
        context: _sessionInfoContext({
          'pageHeaderHtml': await _sessionHeader(engine, title: 'Claude Session', sessionId: 'claude-1'),
          'sessionId': 'claude-1',
          'inputStr': '120',
          'outputStr': '80',
          'totalStr': '200',
          'messageCount': 2,
          'provider': 'claude',
          'providerLabel': 'Claude',
          'showProvider': true,
          'hasEstimatedCost': true,
          'estimatedCostUsd': 0.42,
          'estimatedCostDisplay': r'$0.42',
          'cachedInputTokens': 18,
          'hasCachedTokens': true,
          'cachedTokensDisplay': '18',
        }),
      );
      _expectAll(claude, ['Claude Session', r'$0.42', 'Cached Input', '18']);
      expect(claude, isNot(contains('cost unavailable')));

      final codex = await engine.renderFileFragment(
        'session_info',
        fragment: 'sessionInfo',
        context: _sessionInfoContext({
          'pageHeaderHtml': await _sessionHeader(engine, title: 'Codex Session', sessionId: 'codex-1'),
          'sessionId': 'codex-1',
          'inputStr': '310',
          'outputStr': '90',
          'totalStr': '400',
          'messageCount': 4,
          'provider': 'codex',
          'providerLabel': 'Codex',
          'showProvider': true,
          'hasEstimatedCost': false,
          'estimatedCostUsd': 0.0,
          'estimatedCostDisplay': null,
          'cachedInputTokens': 64,
          'hasCachedTokens': true,
          'cachedTokensDisplay': '64',
        }),
      );
      _expectAll(codex, ['Codex Session', 'cost unavailable', 'Cached Input', '64']);

      final escaped = await engine.renderFileFragment(
        'session_info',
        fragment: 'sessionInfo',
        context: _sessionInfoContext({
          'pageHeaderHtml': await _sessionHeader(engine, title: '<script>xss</script>', sessionId: 'x'),
          'sessionId': 'x',
        }),
      );
      expect(escaped, contains('&lt;script&gt;'));
      expect(escaped, isNot(contains('<script>xss')));
    });

    test('defaults legacy usage data to Claude-style cost display', () async {
      final html = await engine.renderFileFragment(
        'session_info',
        fragment: 'sessionInfo',
        context: _sessionInfoContext({
          'pageHeaderHtml': await _sessionHeader(engine, title: 'Legacy Session', sessionId: 'legacy-1'),
          'sessionId': 'legacy-1',
          'inputStr': '10',
          'outputStr': '15',
          'totalStr': '25',
          'messageCount': 1,
          'hasEstimatedCost': true,
          'estimatedCostUsd': 0.10,
          'estimatedCostDisplay': r'$0.10',
        }),
      );
      _expectAll(html, ['Legacy Session', r'$0.10']);
      _expectNone(html, ['cost unavailable', 'Cached Input']);
    });
  });

  group('status pages', () {
    test('scheduling renders active and empty states', () async {
      final active = await engine.renderFileFragment(
        'scheduling',
        fragment: 'scheduling',
        context: {
          'pulseClass': 'pulse-active',
          'heartbeatBadgeHtml': '<span class="status-badge status-badge-success">Active</span>',
          'hasHeartbeatMetrics': true,
          'heartbeatMetricCardsHtml':
              '<div class="card card-metric card-metric--info"><div class="metric-value t-metric">30</div>'
              '<div class="metric-label">Interval (min)</div></div>',
          'hasJobs': true,
          'jobs': [
            {
              'name': 'Daily Digest',
              'schedule': '0 9 * * *',
              'delivery': 'announce',
              'deliveryBadgeClass': 'announce',
              'status': 'active',
              'statusDotClass': 'active',
              'rowClass': '',
            },
          ],
          'sidebar': '',
          'topbar': '',
        },
      );
      _expectAll(active, ['Heartbeat', 'Active', 'Daily Digest', '0 9 * * *']);

      final empty = await engine.renderFileFragment(
        'scheduling',
        fragment: 'scheduling',
        context: {
          'pulseClass': '',
          'heartbeatBadgeHtml': '<span class="status-badge status-badge-muted">Disabled</span>',
          // Disabled: no interval to report, so no metric card is emitted at all.
          'hasHeartbeatMetrics': false,
          'jobsEmptyStateHtml':
              '<div class="empty-state"><p class="empty-state-title t-label">No scheduled jobs</p></div>',
          'hasJobs': false,
          'jobs': <Map<String, dynamic>>[],
          'sidebar': '',
          'topbar': '',
        },
      );
      _expectAll(empty, ['No scheduled jobs', 'Disabled']);
      _expectNone(empty, ['card-metric']);
    });

    test('health dashboard renders metrics and escapes version', () async {
      final html = await engine.renderFileFragment(
        'health_dashboard',
        fragment: 'healthDashboard',
        context: {
          'statusColorClass': 'status-healthy',
          'statusIcon': '<svg>check</svg>',
          'statusLabel': 'Healthy',
          'version': '0.3.0',
          'workerState': 'running',
          'workerValueClass': 'text-success',
          'cardsHtml': '<div class="card"><span class="card-title">Storage</span><span>SQLite</span></div>',
          // Uptime is a KPI tile now, not a hero row – the fixture mirrors that.
          'metricsHtml':
              '<div class="metric-value">3d 14h 22m</div><div class="metric-label">Uptime</div>'
              '<div class="metric-value">12</div><div class="metric-label">DB Size</div><div>2.4 MB</div>',
          'sidebar': '',
          'topbar': '',
        },
      );
      _expectAll(html, ['Healthy', '3d 14h 22m', '0.3.0', 'running', '12', '2.4 MB']);

      final escaped = await engine.renderFileFragment(
        'health_dashboard',
        fragment: 'healthDashboard',
        context: {
          'statusColorClass': 'status-error',
          'statusIcon': '',
          'statusLabel': 'Down',
          'version': '<script>',
          'workerState': 'crashed',
          'workerValueClass': 'text-error',
          'cardsHtml': '',
          'metricsHtml': '',
          'sidebar': '',
          'topbar': '',
        },
      );
      expect(escaped, contains('&lt;script&gt;'));
    });
  });

  group('settings.html', () {
    test('renders cards and channel configure links', () async {
      final html = await engine.renderFileFragment('settings', fragment: 'settings', context: _settingsContext({}));
      _expectAll(html, [
        'Settings',
        'WhatsApp Channel',
        'Security',
        'Scheduling',
        'Authentication',
        'System Health',
        'Workspace',
        '/settings/channels/whatsapp',
        '/settings/channels/signal',
        '/settings/channels/google_chat',
        'class="content-area print-in"',
        'class="content-inner"',
        'card card-metric card-metric--info',
        'card card-metric card-metric--accent',
        'card card-metric card-metric--warning',
      ]);
      expect(RegExp('data-mutability-summary[^>]*hidden').allMatches(html), hasLength(7));
      _expectNone(html, [
        '<style',
        'summary-stat',
        'summary-value',
        'summary-label',
        'page-content',
        'page-inner',
        'id="agent"',
        'id="server"',
        'id="channels"',
      ]);
    });

    test('shows WhatsApp configure link when enabled', () async {
      final html = await engine.renderFileFragment(
        'settings',
        fragment: 'settings',
        context: _settingsContext({
          'whatsAppEnabled': true,
          'healthBadgeHtml': '<span class="status-badge status-badge-success">OK</span>',
          'whatsAppStatusBadgeHtml': '<span class="status-badge status-badge-success">Connected</span>',
          'uptimeStr': '0m',
          'sessionCount': 0,
          'workspacePathDisplay': '/tmp',
        }),
      );
      _expectAll(html, ['/settings/channels/whatsapp', 'Configure']);
    });
  });

  group('chat.html', () {
    test('rich input metadata uses canonical chip anatomy', () {
      final html = richInputHtmlFromMetadataMap({
        'attachments': [
          {'filename': 'notes.md', 'state': 'ready'},
        ],
        'references': [
          {'id': 'memory-1', 'label': 'Memory note', 'type': 'memory'},
        ],
      });

      _expectAll(html!, [
        'msg-rich-input chip-row',
        'class="chip"',
        'class="chip chip--ref"',
        'chip-name',
        'chip-meta',
      ]);
      expect(html, isNot(contains('composer-chip')));
    });

    test('message fragments render expected content and optional states', () async {
      final user = await engine.renderFileFragment(
        'chat',
        fragment: 'userMessage',
        context: {'content': 'Hello <world>'},
      );
      _expectAll(user, ['msg-user', '>You<', 'Hello &lt;world&gt;']);
      expect(user, contains('msg-user print-in'));

      final rich = await engine.renderFileFragment(
        'chat',
        fragment: 'userMessage',
        context: {
          'content': 'Review this',
          'richInputHtml': '<div class="msg-rich-input chip-row"><span class="chip">notes.md</span></div>',
        },
      );
      _expectAll(rich, ['msg-rich-input', 'notes.md']);

      final assistant = await engine.renderFileFragment(
        'chat',
        fragment: 'assistantMessage',
        context: {'content': 'Here is the answer'},
      );
      _expectAll(assistant, ['msg-assistant', 'data-markdown', 'Here is the answer']);
      expect(assistant, contains('msg-assistant print-in'));

      final guard = await engine.renderFileFragment(
        'chat',
        fragment: 'guardBlock',
        context: {'detail': 'Dangerous command detected'},
      );
      _expectAll(guard, ['GUARD BLOCKED', 'Dangerous command detected']);

      final failed = await engine.renderFileFragment(
        'chat',
        fragment: 'turnFailed',
        context: {'detail': 'Process exited with code 1'},
      );
      _expectAll(failed, ['Turn failed', 'Process exited with code 1']);

      final failedWithoutDetail = await engine.renderFileFragment(
        'chat',
        fragment: 'turnFailed',
        context: {'detail': null},
      );
      expect(failedWithoutDetail, contains('Turn failed'));
      expect(failedWithoutDetail, isNot(contains('msg-turn-failed-detail')));
    });

    test('chat area and send response render HTMX/SSE wiring', () async {
      final area = await engine.renderFileFragment(
        'chat',
        fragment: 'chatArea',
        context: {
          'sessionId': 'abc-123',
          'hasTitle': 'true',
          'bannerHtml': null,
          'messagesHtml': '<div class="msg">test</div>',
          'readOnly': false,
          'sendUrl': '/api/sessions/abc-123/send',
          'placeholder': 'Type a message...',
          'inputDisabled': null,
        },
      );
      _expectAll(area, [
        'data-session-id="abc-123"',
        'class="msg">test',
        'hx-post="/api/sessions/abc-123/send"',
        'hx-target="#messages"',
        'hx-swap="beforeend"',
        'name="attachments"',
        'data-dc-chat-target="commandPalette"',
        'composer-palette card card-glass',
        'composer-reference-palette card card-glass',
        'class="composer-toolbar"',
        'class="composer-hints"',
        'data-action="dc-chat#applySuggestion"',
        'Ctrl/⌘',
        'class="composer-meta"',
        'btn btn-primary btn-icon composer-send',
        'data-icon="arrow-up" aria-label="Send"',
      ]);
      expect(area, isNot(contains('composer-row')));
      expect(area, isNot(contains('sse-container')));

      final response = await engine.renderFileFragment(
        'chat',
        fragment: 'sendResponse',
        context: {'message': 'Hello <world>', 'sseUrl': '/api/sessions/s1/stream?turn=t1'},
      );
      _expectAll(response, [
        'msg-user print-in',
        'Hello &lt;world&gt;',
        'msg-assistant print-in',
        'id="streaming-msg"',
        'sse-connect="/api/sessions/s1/stream?turn=t1"',
        'hx-ext="sse"',
        'sse-close="done"',
        'sse-swap="delta"',
        'id="turn-error-target" sse-swap="turn_error" hx-swap="innerHTML" hidden',
      ]);
      expect(response, isNot(contains('id="streaming-content" class="print-in"')));
      expect(response, isNot(contains('display:none')));
    });
  });

  group('shell scaffolding contracts', () {
    setUp(() => server.initTemplates(resolveTemplatesDir()));
    tearDown(server.resetTemplates);

    test('skip link is emitted only where the body supplies #main-content', () {
      // A skip link is a focusable control. Rendering one on a body with no
      // #main-content gives the keyboard operator a first Tab stop that does
      // nothing, which is worse than having no skip link at all.
      final shell = layoutTemplate(
        title: 'Test',
        body: '<main id="main-content" tabindex="-1"></main>',
        showSkipLink: true,
      );
      expect('skip-link'.allMatches(shell).length, 1);
      expect(shell, contains('<a class="skip-link" href="#main-content">Skip to content</a>'));
      expect(shell, contains('id="main-content"'));
      expect(
        shell.indexOf('skip-link'),
        lessThan(shell.indexOf('id="main-content"')),
        reason: 'the skip link must precede its target so it is the first Tab stop',
      );
      final bodyOpenEnd = shell.indexOf('>', shell.indexOf('<body')) + 1;
      expect(
        shell.substring(bodyOpenEnd, shell.indexOf('<a class="skip-link"')).trim(),
        isEmpty,
        reason: 'the skip link must be the first element in <body> so nothing focusable precedes it',
      );

      final login = loginPageTemplate();
      expect(login, isNot(contains('skip-link')));
      expect(login, isNot(contains('id="main-content"')));

      final bareError = errorPageTemplate(404, 'Not Found', 'Gone');
      expect(bareError, isNot(contains('skip-link')));
      expect(bareError, isNot(contains('id="main-content"')));
    });

    test('the shared topbar owns the page h1', () async {
      // The topbar is the only <h1> on a page; per-surface templates carry a
      // subtitle or description head instead.
      final page = await engine.renderFileFragment(
        'topbar',
        fragment: 'pageTopbar',
        context: {'title': 'Settings', 'backHref': '/', 'backLabel': 'Back'},
      );
      expect('<h1'.allMatches(page).length, 1);
      expect(page, contains('<h1 class="session-title-static t-page-title">Settings</h1>'));

      final plain = await engine.renderFileFragment(
        'topbar',
        fragment: 'plainTopbar',
        context: const {'appName': 'DartClaw'},
      );
      expect('<h1'.allMatches(plain).length, 1);
      expect(plain, contains('t-page-title'));

      // User/channel titles are editable inputs and archive titles are
      // read-only spans. Neither treatment competes with a page heading.
      final session = await engine.renderFileFragment(
        'topbar',
        fragment: 'sessionTopbar',
        context: {
          'displayTitle': 'My Chat',
          'sessionId': 'sess-1',
          'isWorkspace': false,
          'isArchive': false,
          'isEditable': true,
          'showResume': false,
          'showReset': false,
          'infoHref': '/sessions/sess-1/info',
          'resetHref': '/api/sessions/sess-1/reset',
        },
      );
      expect(session, isNot(contains('<h1')));
    });
  });

  group('shared page fragments', () {
    setUp(() => server.initTemplates(resolveTemplatesDir()));
    tearDown(server.resetTemplates);

    test('pageHeader emits one heading treatment with optional subtitle and actions', () {
      final full = pageHeaderTemplate(
        title: 'Projects',
        subtitle: 'Repositories the agent can work in.',
        actionsHtml: '<button class="btn btn-primary" data-icon="plus">Add Project</button>',
      );
      _expectAll(full, [
        '<header class="pagehead">',
        '<h2 class="t-page-title">Projects</h2>',
        'Repositories the agent can work in.',
        'pagehead-actions',
        'Add Project',
      ]);
      // The topbar owns the page's single <h1>; this heading is one tier down.
      expect(full, isNot(contains('<h1')));
      expect(full.indexOf('t-page-title'), lessThan(full.indexOf('page-subtitle')));
      expect(full.indexOf('page-subtitle'), lessThan(full.indexOf('pagehead-actions')));

      final headless = pageHeaderTemplate(
        subtitle: 'No title on this one.',
        actionsHtml: '<button class="btn">Act</button>',
      );
      expect(headless, isNot(contains('<h2')));
      _expectAll(headless, ['No title on this one.', 'pagehead-actions', 'Act']);

      final bare = pageHeaderTemplate(title: 'Tasks');
      _expectAll(bare, ['<h2 class="t-page-title">Tasks</h2>']);
      _expectNone(bare, ['pagehead-actions', 'page-subtitle']);

      expect(pageHeaderTemplate(title: '<script>x</script>'), contains('&lt;script&gt;'));
    });

    test('emptyState is one implementation with two bounded visual branches', () {
      final plain = emptyStateTemplate(title: 'No tasks yet', body: 'Tasks will appear here when created.');
      _expectAll(plain, [
        'class="empty-state"',
        'class="icon" aria-hidden="true"',
        '<p class="empty-state-title t-label">No tasks yet</p>',
        'Tasks will appear here when created.',
      ]);
      _expectNone(plain, ['mascot-', '<button', 'pixel-art']);

      final withAction = emptyStateTemplate(
        title: 'No projects registered',
        body: 'Add a project to run tasks against external repositories.',
        actionHtml: '<button class="btn btn-primary" data-project-dialog-open>Add Project</button>',
      );
      _expectAll(withAction, ['No projects registered', 'data-project-dialog-open', 'Add Project']);
      expect(withAction, contains('class="icon" aria-hidden="true"'));

      // The mascot is the one bounded alternative visual, decorative because
      // title and body carry the state. The in-session chat caller is its only consumer.
      final mascot = emptyStateTemplate(title: 'No messages yet', body: 'Say something.', useMascot: true);
      expect('pixel-art'.allMatches(mascot).length, 1);
      _expectAll(mascot, ['mascot-avatar-512-8bit.png', 'width="64"', 'height="64"', 'alt=""']);
      expect(mascot, isNot(contains('class="icon"')));

      // Caller-supplied title and body are escaped; only the action slot is raw.
      expect(
        emptyStateTemplate(title: '<script>x</script>', body: 'a & b'),
        allOf(contains('&lt;script&gt;'), contains('a &amp; b')),
      );
    });

    test('metricCard binds the canonical metric tier once for every consumer', () {
      final card = metricCardTemplate(color: 'accent', value: '42', label: 'Tasks');
      expect(card, contains('class="metric-value t-metric"'));
      _expectAll(card, ['card card-metric', 'card-metric--accent', '42', 'Tasks']);
    });

    test('metricCard renders the canon absent treatment, and a real zero stays a zero', () {
      // The rendered half of the absent contract: helpers_test pins the record,
      // this pins that the Trellis ternary and the context key actually emit it.
      final absent = metricCardTemplate(color: 'info', value: null, label: 'Input');
      expect(absent, contains('class="metric-value t-metric value-absent"'));
      // Empty, so canon's .value-absent:empty::before supplies the dash.
      expect(absent, contains('value-absent"></div>'));

      for (final zero in <Object>[0, '0']) {
        final card = metricCardTemplate(color: 'info', value: zero, label: 'Steps');
        expect(card, isNot(contains('value-absent')), reason: '$zero is a value, not an absent field');
        expect(card, contains('>$zero</div>'));
      }
    });
  });

  group('no htmlEscape calls in .html templates', () {
    test('template files do not contain htmlEscape()', () {
      final dir = Directory(templatesDir);
      final htmlFiles = dir.listSync().whereType<File>().where((file) => file.path.endsWith('.html'));
      for (final file in htmlFiles) {
        final content = file.readAsStringSync();
        expect(content, isNot(contains('htmlEscape')), reason: '${file.path} contains htmlEscape()');
      }
    });
  });
}
