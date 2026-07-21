import 'dart:io';

import 'package:dartclaw_server/src/templates/loader.dart' as server;
import 'package:test/test.dart';
import 'package:trellis/trellis.dart';

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
  'navItems': <Map<String, dynamic>>[],
  ...overrides,
};

Map<String, dynamic> _sessionInfoContext(Map<String, dynamic> overrides) => {
  'title': 'My Research',
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

      final emptyState = await engine.renderFileFragment('components', fragment: 'emptyState', context: const {});
      _expectAll(emptyState, ['No messages yet', 'empty-state', '❯_']);
      expect(emptyState, isNot(anyOf(contains('claw-mark'), contains('mascot-'))));

      final emptyAppState = await engine.renderFileFragment('components', fragment: 'emptyAppState', context: const {});
      _expectAll(emptyAppState, ['No chats yet', '❯_']);
      expect(emptyAppState, isNot(anyOf(contains('claw-mark'), contains('mascot-'))));
      expect(emptyAppState, isNot(contains('data-dc-legacy-action')));
    });
  });

  group('layout and topbars', () {
    test('layout includes document chrome, assets, requested scripts, and escaped title', () async {
      final html = await engine.renderFile('layout', {
        'title': '<script>xss</script>',
        'body': '<p>Hello</p>',
        'appName': 'DartClaw',
        'scriptsHtml': '<script defer="defer" src="/static/extra-page.js"></script>',
      });
      _expectAll(html, [
        '<!DOCTYPE html>',
        '&lt;script&gt;',
        'htmx.org',
        'marked',
        'purify.min.js',
        '/static/tokens.css',
        '/static/app-tokens.css',
        '/static/design-system.css',
        '/static/app.css',
        '/static/mascot-favicon-32.png',
        '/static/mascot-favicon-16.png',
        '/static/controllers/index.js',
        '/static/extra-page.js',
      ]);
      _expectNone(html, ['<script>xss</script>', '/static/app.js', '/static/settings.js', 'href="data:,"']);
    });

    test('topbar fragments render expected controls', () async {
      final session = await engine.renderFileFragment(
        'topbar',
        fragment: 'sessionTopbar',
        context: {
          'displayTitle': 'My Chat',
          'sessionId': 'sess-1',
          'isArchive': false,
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
          'isArchive': true,
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
        '>New Chat</button>',
        'data-icon="x"',
        'data-icon="chevron-down"',
      ]);
      expect(
        providers,
        isNot(
          anyOf(contains('data-icon="hash"'), contains('data-icon="message-circle"'), contains('data-icon="archive"')),
        ),
      );

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
        'hx-select-oob="#topbar,#sidebar"',
        'Research',
        'data-session-archive="true"',
        'data-session-delete="true"',
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
        context: _sessionInfoContext({}),
      );
      _expectAll(basic, ['My Research', 'abc-123', '1.2K', '3.4K', '4.6K', '42']);

      final claude = await engine.renderFileFragment(
        'session_info',
        fragment: 'sessionInfo',
        context: _sessionInfoContext({
          'title': 'Claude Session',
          'sessionId': 'claude-1',
          'inputStr': '120',
          'outputStr': '80',
          'totalStr': '200',
          'messageCount': 2,
          'provider': 'claude',
          'providerLabel': 'Claude',
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
          'title': 'Codex Session',
          'sessionId': 'codex-1',
          'inputStr': '310',
          'outputStr': '90',
          'totalStr': '400',
          'messageCount': 4,
          'provider': 'codex',
          'providerLabel': 'Codex',
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
        context: _sessionInfoContext({'title': '<script>xss</script>', 'sessionId': 'x'}),
      );
      expect(escaped, contains('&lt;script&gt;'));
    });

    test('defaults legacy usage data to Claude-style cost display', () async {
      final html = await engine.renderFileFragment(
        'session_info',
        fragment: 'sessionInfo',
        context: _sessionInfoContext({
          'title': 'Legacy Session',
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
          'heartbeatMetricCardsHtml':
              '<div class="card card-metric card-metric--info"><div class="metric-value">every 30 min</div><div class="metric-label">Interval</div></div><div class="card card-metric card-metric--accent"><div class="metric-value">Active</div><div class="metric-label">Status</div></div>',
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
          'heartbeatMetricCardsHtml':
              '<div class="card card-metric card-metric--info"><div class="metric-value">-</div><div class="metric-label">Interval</div></div><div class="card card-metric card-metric--warning"><div class="metric-value">Disabled</div><div class="metric-label">Status</div></div>',
          'hasJobs': false,
          'jobs': <Map<String, dynamic>>[],
          'sidebar': '',
          'topbar': '',
        },
      );
      _expectAll(empty, ['No scheduled jobs configured', 'Disabled']);
    });

    test('health dashboard renders metrics and escapes version', () async {
      final html = await engine.renderFileFragment(
        'health_dashboard',
        fragment: 'healthDashboard',
        context: {
          'statusColorClass': 'status-healthy',
          'statusIcon': '<svg>check</svg>',
          'statusLabel': 'Healthy',
          'uptimeStr': '3d 14h 22m',
          'version': '0.3.0',
          'workerState': 'running',
          'cardsHtml': '<div class="card"><span class="card-title">Worker</span><span>running</span></div>',
          'metricsHtml': '<div class="metric-value">12</div><div class="metric-label">DB Size</div><div>2.4 MB</div>',
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
          'uptimeStr': '0m',
          'version': '<script>',
          'workerState': 'crashed',
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
      _expectNone(html, ['<style', 'summary-stat', 'summary-value', 'summary-label', 'page-content', 'page-inner']);
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
          'richInputHtml': '<div class="msg-rich-input"><span class="composer-chip">notes.md</span></div>',
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
        '<kbd>/</kbd> commands',
        '<kbd>Ctrl/⌘</kbd> + <kbd>Enter</kbd> to send',
      ]);
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
