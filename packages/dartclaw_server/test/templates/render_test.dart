import 'dart:io';

import 'package:dartclaw_server/src/templates/loader.dart' as server;
import 'package:test/test.dart';
import 'package:trellis/trellis.dart';

void main() {
  final templatesDir = Directory('lib/src/templates').existsSync()
      ? 'lib/src/templates'
      : 'packages/dartclaw_server/lib/src/templates';
  late Trellis engine;

  setUpAll(() {
    engine = Trellis(loader: FileSystemLoader(templatesDir));
  });

  group('TemplateLoader', () {
    test('validate() succeeds when all templates exist', () {
      final loader = server.TemplateLoaderService(templatesDir);
      // Should not throw.
      loader.validate();
    });

    test('validate() throws when templates are missing', () {
      final tmpDir = Directory.systemTemp.createTempSync('tpl_test_');
      addTearDown(() => tmpDir.deleteSync(recursive: true));

      final loader = server.TemplateLoaderService(tmpDir.path);
      expect(() => loader.validate(), throwsA(isA<StateError>()));
    });

    test('validate() error message lists missing templates', () {
      final tmpDir = Directory.systemTemp.createTempSync('tpl_test_');
      addTearDown(() => tmpDir.deleteSync(recursive: true));

      final loader = server.TemplateLoaderService(tmpDir.path);
      try {
        loader.validate();
        fail('Expected StateError');
      } on StateError catch (e) {
        expect(e.message, contains('Missing templates'));
        expect(e.message, contains('error_page.html'));
        expect(e.message, contains('login.html'));
      }
    });

    test('source() returns template content and trellis renders it', () {
      final loader = server.TemplateLoaderService(templatesDir);
      final html = loader.trellis.render(loader.source('error_page'), {
        'code': 404,
        'title': 'Not Found',
        'detail': 'Gone',
      });
      expect(html, contains('404'));
      expect(html, contains('Not Found'));
    });

    test('source() throws for unknown template', () {
      final loader = server.TemplateLoaderService(templatesDir);
      expect(() => loader.source('nonexistent'), throwsA(isA<StateError>()));
    });
  });

  group('error_page.html', () {
    test('renders error code, title, and detail', () async {
      final html = await engine.renderFileFragment(
        'error_page',
        fragment: 'errorPage',
        context: {'code': 500, 'title': 'Server Error', 'detail': 'Something broke'},
      );
      expect(html, contains('500'));
      expect(html, contains('Server Error'));
      expect(html, contains('Something broke'));
    });

    test('auto-escapes title with special characters', () async {
      final html = await engine.renderFileFragment(
        'error_page',
        fragment: 'errorPage',
        context: {'code': 400, 'title': '<Bad Request>', 'detail': 'x&y'},
      );
      expect(html, contains('&lt;Bad Request&gt;'));
      expect(html, contains('x&amp;y'));
    });

    test('contains back-to-home link', () async {
      final html = await engine.renderFileFragment(
        'error_page',
        fragment: 'errorPage',
        context: {'code': 404, 'title': 'Not Found', 'detail': ''},
      );
      expect(html, contains('href="/"'));
      expect(html, contains('Back to Home'));
    });
  });

  group('login.html', () {
    test('renders login form with token input', () async {
      final html = await engine.renderFileFragment('login', fragment: 'loginPage', context: {'error': null});
      expect(html, contains('login-form'));
      expect(html, contains('name="token"'));
      expect(html, contains('type="password"'));
    });

    test('renders error message when error is provided', () async {
      final html = await engine.renderFileFragment('login', fragment: 'loginPage', context: {'error': 'Invalid token'});
      expect(html, contains('login-error'));
      expect(html, contains('Invalid token'));
    });

    test('hides error div when error is null', () async {
      final html = await engine.renderFileFragment('login', fragment: 'loginPage', context: {'error': null});
      expect(html, isNot(contains('login-error')));
    });

    test('contains DartClaw branding', () async {
      final html = await engine.renderFileFragment(
        'login',
        fragment: 'loginPage',
        context: {'error': null, 'appName': 'DartClaw'},
      );
      expect(html, contains('DartClaw'));
    });

    test('contains remember checkbox', () async {
      final html = await engine.renderFileFragment('login', fragment: 'loginPage', context: {'error': null});
      expect(html, contains('name="remember"'));
    });

    test('renders next-path hidden input when provided', () async {
      final html = await engine.renderFileFragment(
        'login',
        fragment: 'loginPage',
        context: {'error': null, 'nextPath': '/tasks?status=review'},
      );
      expect(html, contains('name="next"'));
      expect(html, contains('value="/tasks?status=review"'));
    });
  });

  group('components.html', () {
    test('banner renders with type class and message', () async {
      final html = await engine.renderFileFragment(
        'components',
        fragment: 'banner',
        context: {'type': 'error', 'message': 'Something went wrong'},
      );
      expect(html, contains('banner-error'));
      expect(html, contains('Something went wrong'));
    });

    test('banner escapes message content', () async {
      final html = await engine.renderFileFragment(
        'components',
        fragment: 'banner',
        context: {'type': 'warning', 'message': '<b>oops</b>'},
      );
      expect(html, contains('&lt;b&gt;oops'));
    });

    test('emptyState renders prompt text', () async {
      final html = await engine.renderFileFragment('components', fragment: 'emptyState', context: const {});
      expect(html, contains('No messages yet'));
      expect(html, contains('empty-state'));
    });

    test('emptyAppState renders create session button', () async {
      final html = await engine.renderFileFragment('components', fragment: 'emptyAppState', context: const {});
      expect(html, contains('No chats yet'));
      expect(html, contains('data-action="create-session"'));
    });
  });

  group('layout.html', () {
    test('renders full HTML document with title', () async {
      final html = await engine.renderFile('layout', {
        'title': 'Test Page',
        'body': '<p>Hello</p>',
        'appName': 'DartClaw',
        'scriptsHtml': '<script defer="defer" src="/static/app.js"></script>',
      });
      expect(html, contains('<!DOCTYPE html>'));
      expect(html, contains('Test Page - DartClaw'));
    });

    test('includes required CDN scripts', () async {
      final html = await engine.renderFile('layout', {
        'title': 'T',
        'body': '',
        'scriptsHtml': '<script defer="defer" src="/static/app.js"></script>',
      });
      expect(html, contains('htmx.org'));
      expect(html, contains('marked'));
      expect(html, contains('purify.min.js'));
    });

    test('includes static asset references', () async {
      final html = await engine.renderFile('layout', {
        'title': 'T',
        'body': '',
        'scriptsHtml': '<script defer="defer" src="/static/app.js"></script>',
      });
      expect(html, contains('/static/tokens.css'));
      expect(html, contains('/static/components.css'));
      expect(html, contains('/static/app.js'));
      expect(html, isNot(contains('/static/settings.js')));
    });

    test('renders explicit page scripts only when requested', () async {
      final html = await engine.renderFile('layout', {
        'title': 'T',
        'body': '',
        'scriptsHtml':
            '<script defer="defer" src="/static/app.js"></script>\n<script defer="defer" src="/static/settings.js"></script>',
      });
      expect(html, contains('/static/settings.js'));
    });

    test('escapes title to prevent XSS', () async {
      final html = await engine.renderFile('layout', {
        'title': '<script>xss</script>',
        'body': '',
        'scriptsHtml': '<script defer="defer" src="/static/app.js"></script>',
      });
      expect(html, contains('&lt;script&gt;'));
      expect(html, isNot(contains('<script>xss</script>')));
    });
  });

  group('topbar.html', () {
    test('sessionTopbar renders editable title input', () async {
      final html = await engine.renderFileFragment(
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
      expect(html, contains('session-title'));
      expect(html, contains('My Chat'));
      expect(html, contains('sess-1'));
      expect(html, contains('data-icon="menu"'));
      expect(html, contains('data-icon="info"'));
    });

    test('sessionTopbar shows resume button for archives', () async {
      final html = await engine.renderFileFragment(
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
      expect(html, contains('resume-archive'));
    });

    test('plainTopbar renders DartClaw branding', () async {
      final html = await engine.renderFileFragment(
        'topbar',
        fragment: 'plainTopbar',
        context: const {'appName': 'DartClaw'},
      );
      expect(html, contains('DartClaw'));
      expect(html, contains('theme-toggle'));
      expect(html, contains('data-icon="menu"'));
    });

    test('pageTopbar renders static title with back link', () async {
      final html = await engine.renderFileFragment(
        'topbar',
        fragment: 'pageTopbar',
        context: {'title': 'Settings', 'backHref': '/', 'backLabel': 'Back'},
      );
      expect(html, contains('Settings'));
      expect(html, contains('href="/"'));
      expect(html, contains('icon-arrow-left'));
    });
  });

  group('sidebar.html', () {
    test('renders with empty data showing placeholders', () async {
      final html = await engine.renderFileFragment(
        'sidebar',
        fragment: 'sidebar',
        context: {
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
        },
      );
      expect(html, contains('No active channels'));
      expect(html, contains('No chats yet'));
    });

    test('renders provider badges for session entries across sidebar sections', () async {
      final html = await engine.renderFileFragment(
        'sidebar',
        fragment: 'sidebar',
        context: {
          'mainSession': true,
          'mainHref': '/sessions/main',
          'mainActive': true,
          'tasksEnabledAttr': null,
          'mainProvider': 'claude',
          'mainProviderLabel': 'Claude',
          'showChannels': true,
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
          'archiveContainsActive': false,
          'hasNav': false,
          'navItems': <Map<String, dynamic>>[],
        },
      );

      expect(html, contains('provider-badge'));
      expect(html, contains('provider-badge-claude'));
      expect(html, contains('provider-badge-codex'));
      expect(html, contains('Claude'));
      expect(html, contains('Codex'));
      expect(html, contains('data-icon="terminal"'));
      expect(html, contains('data-icon="hash"'));
      expect(html, contains('data-icon="message-circle"'));
      expect(html, contains('data-icon="archive"'));
      expect(html, contains('data-icon="new-session"'));
      expect(html, contains('>New Chat</button>'));
      expect(html, contains('data-icon="x"'));
      expect(html, contains('data-icon="chevron-down"'));
    });

    test('renders session entries with HTMX SPA nav attrs', () async {
      final html = await engine.renderFileFragment(
        'sidebar',
        fragment: 'sidebar',
        context: {
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
          'noActiveEntries': false,
          'activeEntries': [
            {'id': 's1', 'href': '/sessions/s1', 'active': true, 'extraClass': 'active', 'title': 'Research'},
          ],
          'hasArchivedEntries': false,
          'archivedEntries': <Map<String, dynamic>>[],
          'archivedCount': 0,
          'archiveContainsActive': false,
          'hasNav': false,
          'navItems': <Map<String, dynamic>>[],
        },
      );
      expect(html, contains('hx-target="#main-content"'));
      expect(html, contains('hx-push-url="true"'));
      expect(html, contains('hx-select-oob="#topbar,#sidebar"'));
      expect(html, contains('Research'));
    });

    test('renders archive and delete actions in the correct sidebar sections', () async {
      final html = await engine.renderFileFragment(
        'sidebar',
        fragment: 'sidebar',
        context: {
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
          'noActiveEntries': false,
          'activeEntries': [
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
          'archiveContainsActive': false,
          'hasNav': false,
          'navItems': <Map<String, dynamic>>[],
        },
      );

      expect(html, contains('data-action="archive-session"'));
      expect(html, contains('data-action="delete-session"'));
      expect(html, contains('aria-label="Archive chat"'));
      expect(html, contains('aria-label="Delete session"'));
    });

    test('renders nav items in system section', () async {
      final html = await engine.renderFileFragment(
        'sidebar',
        fragment: 'sidebar',
        context: {
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
        },
      );
      expect(html, contains('Health'));
      expect(html, contains('Settings'));
      expect(html, contains('Optional'));
      expect(html, contains('sidebar-nav-item'));
      expect(html, contains('data-icon="health"'));
      expect(html, contains('data-icon="settings"'));
      expect(html, isNot(contains('data-icon="null"')));
    });
  });

  group('session_info.html', () {
    test('renders session title, ID, and token usage', () async {
      final html = await engine.renderFileFragment(
        'session_info',
        fragment: 'sessionInfo',
        context: {
          'title': 'My Research',
          'sessionId': 'abc-123',
          'inputStr': '1.2K',
          'outputStr': '3.4K',
          'totalStr': '4.6K',
          'messageCount': 42,
          'createdAt': '2025-01-15',
          'sidebar': '',
          'topbar': '',
        },
      );
      expect(html, contains('My Research'));
      expect(html, contains('abc-123'));
      expect(html, contains('1.2K'));
      expect(html, contains('3.4K'));
      expect(html, contains('4.6K'));
      expect(html, contains('42'));
    });

    test('renders Claude cost and cached token details when usage data includes provider information', () async {
      final html = await engine.renderFileFragment(
        'session_info',
        fragment: 'sessionInfo',
        context: {
          'title': 'Claude Session',
          'sessionId': 'claude-1',
          'inputStr': '120',
          'outputStr': '80',
          'totalStr': '200',
          'messageCount': 2,
          'createdAt': '2025-01-15',
          'sidebar': '',
          'topbar': '',
          'provider': 'claude',
          'providerLabel': 'Claude',
          'hasEstimatedCost': true,
          'estimatedCostUsd': 0.42,
          'estimatedCostDisplay': r'$0.42',
          'cachedInputTokens': 18,
          'hasCachedTokens': true,
          'cachedTokensDisplay': '18',
        },
      );

      expect(html, contains('Claude Session'));
      expect(html, contains(r'$0.42'));
      expect(html, contains('Cached Input'));
      expect(html, contains('18'));
      expect(html, isNot(contains('cost unavailable')));
    });

    test('renders Codex cost fallback and cached input tokens when USD cost is unavailable', () async {
      final html = await engine.renderFileFragment(
        'session_info',
        fragment: 'sessionInfo',
        context: {
          'title': 'Codex Session',
          'sessionId': 'codex-1',
          'inputStr': '310',
          'outputStr': '90',
          'totalStr': '400',
          'messageCount': 4,
          'createdAt': '2025-01-15',
          'sidebar': '',
          'topbar': '',
          'provider': 'codex',
          'providerLabel': 'Codex',
          'hasEstimatedCost': false,
          'estimatedCostUsd': 0.0,
          'estimatedCostDisplay': null,
          'cachedInputTokens': 64,
          'hasCachedTokens': true,
          'cachedTokensDisplay': '64',
        },
      );

      expect(html, contains('Codex Session'));
      expect(html, contains('cost unavailable'));
      expect(
        html,
        contains('This provider does not report USD cost. Token counts are tracked for governance budgets.'),
      );
      expect(html, contains('Cached Input'));
      expect(html, contains('64'));
    });

    test('defaults legacy usage data to Claude-style cost display', () async {
      final html = await engine.renderFileFragment(
        'session_info',
        fragment: 'sessionInfo',
        context: {
          'title': 'Legacy Session',
          'sessionId': 'legacy-1',
          'inputStr': '10',
          'outputStr': '15',
          'totalStr': '25',
          'messageCount': 1,
          'createdAt': '2025-01-15',
          'sidebar': '',
          'topbar': '',
          'hasEstimatedCost': true,
          'estimatedCostUsd': 0.10,
          'estimatedCostDisplay': r'$0.10',
        },
      );

      expect(html, contains('Legacy Session'));
      expect(html, contains(r'$0.10'));
      expect(html, isNot(contains('cost unavailable')));
      expect(html, isNot(contains('Cached Input')));
    });

    test('escapes session title with special chars', () async {
      final html = await engine.renderFileFragment(
        'session_info',
        fragment: 'sessionInfo',
        context: {
          'title': '<script>xss</script>',
          'sessionId': 'x',
          'inputStr': '0',
          'outputStr': '0',
          'totalStr': '0',
          'messageCount': 0,
          'createdAt': '—',
          'sidebar': '',
          'topbar': '',
        },
      );
      expect(html, contains('&lt;script&gt;'));
    });
  });

  group('scheduling.html', () {
    test('renders heartbeat status and job table', () async {
      final html = await engine.renderFileFragment(
        'scheduling',
        fragment: 'scheduling',
        context: {
          'pulseClass': 'pulse-active',
          'badgeClass': 'badge-success',
          'badgeText': 'Active',
          'intervalDisplay': 'every 30 min',
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
      expect(html, contains('Heartbeat'));
      expect(html, contains('Active'));
      expect(html, contains('Daily Digest'));
      expect(html, contains('0 9 * * *'));
    });

    test('renders empty job table placeholder', () async {
      final html = await engine.renderFileFragment(
        'scheduling',
        fragment: 'scheduling',
        context: {
          'pulseClass': '',
          'badgeClass': 'badge-muted',
          'badgeText': 'Disabled',
          'intervalDisplay': '—',
          'hasJobs': false,
          'jobs': <Map<String, dynamic>>[],
          'sidebar': '',
          'topbar': '',
        },
      );
      expect(html, contains('No scheduled jobs configured'));
      expect(html, contains('Disabled'));
    });
  });

  group('health_dashboard.html', () {
    test('renders status hero and metrics', () async {
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
          'cardsHtml':
              '<div class="card"><div class="card-header">'
              '<span class="card-title">Worker</span>'
              '<span class="card-badge badge-success">OK</span></div>'
              '<div class="card-rows"><div class="card-row">'
              '<span class="card-row-label">State</span>'
              '<span class="card-row-value">running</span></div></div></div>',
          'metricsHtml':
              '<div class="card card-metric card-metric--info">'
              '<div class="metric-value">12</div>'
              '<div class="metric-label">Sessions</div></div>'
              '<div class="card card-metric card-metric--info">'
              '<div class="metric-value">2.4 MB</div>'
              '<div class="metric-label">DB Size</div></div>',
          'sidebar': '',
          'topbar': '',
        },
      );
      expect(html, contains('Healthy'));
      expect(html, contains('3d 14h 22m'));
      expect(html, contains('0.3.0'));
      expect(html, contains('running'));
      expect(html, contains('12'));
      expect(html, contains('2.4 MB'));
    });

    test('escapes version string', () async {
      final html = await engine.renderFileFragment(
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
      expect(html, contains('&lt;script&gt;'));
    });
  });

  group('settings.html', () {
    test('renders all settings cards', () async {
      final html = await engine.renderFileFragment(
        'settings',
        fragment: 'settings',
        context: {
          'whatsAppEnabled': false,
          'signalConnected': false,
          'signalDisconnected': false,
          'signalNotConfigured': true,
          'signalEnabled': false,
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
        },
      );
      expect(html, contains('Settings'));
      expect(html, contains('WhatsApp Channel'));
      expect(html, contains('Security'));
      expect(html, contains('Scheduling'));
      expect(html, contains('Authentication'));
      expect(html, contains('System Health'));
      expect(html, contains('Workspace'));
    });

    test('shows WhatsApp configure link when enabled', () async {
      final html = await engine.renderFileFragment(
        'settings',
        fragment: 'settings',
        context: {
          'whatsAppEnabled': true,
          'signalConnected': false,
          'signalDisconnected': false,
          'signalNotConfigured': true,
          'signalEnabled': false,
          'signalPhone': '',
          'guardsActive': false,
          'activeGuardCount': 0,
          'activeGuards': <String>[],
          'schedulingActive': false,
          'scheduledJobsCount': 0,
          'heartbeatDisplay': 'disabled',
          'healthBadgeHtml': '<span class="status-badge status-badge-success">OK</span>',
          'whatsAppStatusBadgeHtml': '<span class="status-badge status-badge-success">Connected</span>',
          'signalStatusBadgeHtml': '<span class="status-badge status-badge-muted">Disabled</span>',
          'googleChatStatusBadgeHtml': '<span class="status-badge status-badge-muted">Disabled</span>',
          'uptimeStr': '0m',
          'sessionCount': 0,
          'version': '0.3.0',
          'gitSyncEnabled': false,
          'workspacePathDisplay': '/tmp',
          'gitSyncDisplay': 'Disabled',
          'sidebar': '',
          'topbar': '',
        },
      );
      expect(html, contains('/settings/channels/whatsapp'));
      expect(html, contains('Configure'));
    });
  });

  group('chat.html', () {
    test('userMessage renders with msg-user class and escaped content', () async {
      final html = await engine.renderFileFragment(
        'chat',
        fragment: 'userMessage',
        context: {'content': 'Hello <world>'},
      );
      expect(html, contains('msg-user'));
      expect(html, contains('>You<'));
      expect(html, contains('Hello &lt;world&gt;'));
    });

    test('assistantMessage renders with data-markdown', () async {
      final html = await engine.renderFileFragment(
        'chat',
        fragment: 'assistantMessage',
        context: {'content': 'Here is the answer'},
      );
      expect(html, contains('msg-assistant'));
      expect(html, contains('data-markdown'));
      expect(html, contains('Here is the answer'));
    });

    test('guardBlock renders blocked reason', () async {
      final html = await engine.renderFileFragment(
        'chat',
        fragment: 'guardBlock',
        context: {'detail': 'Dangerous command detected'},
      );
      expect(html, contains('GUARD BLOCKED'));
      expect(html, contains('Dangerous command detected'));
    });

    test('turnFailed renders with optional detail', () async {
      final html = await engine.renderFileFragment(
        'chat',
        fragment: 'turnFailed',
        context: {'detail': 'Process exited with code 1'},
      );
      expect(html, contains('Turn failed'));
      expect(html, contains('Process exited with code 1'));
    });

    test('turnFailed hides detail when null', () async {
      final html = await engine.renderFileFragment('chat', fragment: 'turnFailed', context: {'detail': null});
      expect(html, contains('Turn failed'));
      expect(html, isNot(contains('msg-turn-failed-detail')));
    });

    test('chatArea renders session container with HTMX form', () async {
      final html = await engine.renderFileFragment(
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
      expect(html, contains('data-session-id="abc-123"'));
      expect(html, contains('class="msg">test'));
      expect(html, contains('hx-post="/api/sessions/abc-123/send"'));
      expect(html, isNot(contains('sse-container')));
      expect(html, contains('hx-target="#messages"'));
      expect(html, contains('hx-swap="beforeend"'));
    });

    test('sendResponse renders user message and SSE connector', () async {
      final html = await engine.renderFileFragment(
        'chat',
        fragment: 'sendResponse',
        context: {'message': 'Hello <world>', 'sseUrl': '/api/sessions/s1/stream?turn=t1'},
      );
      expect(html, contains('msg-user'));
      expect(html, contains('Hello &lt;world&gt;'));
      expect(html, contains('streaming-msg'));
      expect(html, contains('sse-connect="/api/sessions/s1/stream?turn=t1"'));
      expect(html, contains('hx-ext="sse"'));
      expect(html, contains('sse-close="done"'));
      expect(html, contains('sse-swap="delta"'));
    });
  });

  group('no htmlEscape calls in .html templates', () {
    test('template files do not contain htmlEscape()', () {
      final dir = Directory(templatesDir);
      final htmlFiles = dir.listSync().whereType<File>().where((f) => f.path.endsWith('.html'));
      for (final file in htmlFiles) {
        final content = file.readAsStringSync();
        expect(content, isNot(contains('htmlEscape')), reason: '${file.path} contains htmlEscape()');
      }
    });
  });
}
