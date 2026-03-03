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
      final loader = server.TemplateLoader(templatesDir);
      // Should not throw.
      loader.validate();
    });

    test('validate() throws when templates are missing', () {
      final tmpDir = Directory.systemTemp.createTempSync('tpl_test_');
      addTearDown(() => tmpDir.deleteSync(recursive: true));

      final loader = server.TemplateLoader(tmpDir.path);
      expect(() => loader.validate(), throwsA(isA<StateError>()));
    });

    test('validate() error message lists missing templates', () {
      final tmpDir = Directory.systemTemp.createTempSync('tpl_test_');
      addTearDown(() => tmpDir.deleteSync(recursive: true));

      final loader = server.TemplateLoader(tmpDir.path);
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
      final loader = server.TemplateLoader(templatesDir);
      final html = loader.trellis.render(
        loader.source('error_page'),
        {'code': 404, 'title': 'Not Found', 'detail': 'Gone'},
      );
      expect(html, contains('404'));
      expect(html, contains('Not Found'));
    });

    test('source() throws for unknown template', () {
      final loader = server.TemplateLoader(templatesDir);
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
      final html = await engine.renderFileFragment(
        'login',
        fragment: 'loginPage',
        context: {'error': null},
      );
      expect(html, contains('login-form'));
      expect(html, contains('name="token"'));
      expect(html, contains('type="password"'));
    });

    test('renders error message when error is provided', () async {
      final html = await engine.renderFileFragment(
        'login',
        fragment: 'loginPage',
        context: {'error': 'Invalid token'},
      );
      expect(html, contains('login-error'));
      expect(html, contains('Invalid token'));
    });

    test('hides error div when error is null', () async {
      final html = await engine.renderFileFragment(
        'login',
        fragment: 'loginPage',
        context: {'error': null},
      );
      expect(html, isNot(contains('login-error')));
    });

    test('contains DartClaw branding', () async {
      final html = await engine.renderFileFragment(
        'login',
        fragment: 'loginPage',
        context: {'error': null},
      );
      expect(html, contains('DartClaw'));
    });

    test('contains remember checkbox', () async {
      final html = await engine.renderFileFragment(
        'login',
        fragment: 'loginPage',
        context: {'error': null},
      );
      expect(html, contains('name="remember"'));
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
      final html = await engine.renderFileFragment(
        'components',
        fragment: 'emptyState',
        context: const {},
      );
      expect(html, contains('No messages yet'));
      expect(html, contains('empty-state'));
    });

    test('emptyAppState renders create session button', () async {
      final html = await engine.renderFileFragment(
        'components',
        fragment: 'emptyAppState',
        context: const {},
      );
      expect(html, contains('No sessions yet'));
      expect(html, contains('data-action="create-session"'));
    });
  });

  group('layout.html', () {
    test('renders full HTML document with title', () async {
      final html = await engine.renderFile('layout', {
        'title': 'Test Page',
        'body': '<p>Hello</p>',
      });
      expect(html, contains('<!DOCTYPE html>'));
      expect(html, contains('Test Page - DartClaw'));
    });

    test('includes required CDN scripts', () async {
      final html = await engine.renderFile('layout', {
        'title': 'T',
        'body': '',
      });
      expect(html, contains('htmx.org'));
      expect(html, contains('marked'));
      expect(html, contains('purify.min.js'));
    });

    test('includes static asset references', () async {
      final html = await engine.renderFile('layout', {
        'title': 'T',
        'body': '',
      });
      expect(html, contains('/static/tokens.css'));
      expect(html, contains('/static/components.css'));
      expect(html, contains('/static/app.js'));
    });

    test('escapes title to prevent XSS', () async {
      final html = await engine.renderFile('layout', {
        'title': '<script>xss</script>',
        'body': '',
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
        context: const {},
      );
      expect(html, contains('DartClaw'));
      expect(html, contains('theme-toggle'));
    });

    test('pageTopbar renders static title with back link', () async {
      final html = await engine.renderFileFragment(
        'topbar',
        fragment: 'pageTopbar',
        context: {
          'title': 'Settings',
          'backHref': '/',
          'backLabel': 'Back',
        },
      );
      expect(html, contains('Settings'));
      expect(html, contains('href="/"'));
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
          'noChannels': true,
          'channels': <Map<String, dynamic>>[],
          'noEntries': true,
          'entries': <Map<String, dynamic>>[],
          'hasNav': false,
          'navItems': <Map<String, dynamic>>[],
        },
      );
      expect(html, contains('No active channels'));
      expect(html, contains('No sessions yet'));
    });

    test('renders session entries with HTMX SPA nav attrs', () async {
      final html = await engine.renderFileFragment(
        'sidebar',
        fragment: 'sidebar',
        context: {
          'mainSession': false,
          'mainHref': '',
          'mainActive': false,
          'noChannels': true,
          'channels': <Map<String, dynamic>>[],
          'noEntries': false,
          'entries': [
            {
              'id': 's1',
              'href': '/sessions/s1',
              'active': true,
              'isArchive': false,
              'archiveClass': '',
              'title': 'Research',
            },
          ],
          'hasNav': false,
          'navItems': <Map<String, dynamic>>[],
        },
      );
      expect(html, contains('hx-target="#main-content"'));
      expect(html, contains('hx-push-url="true"'));
      expect(html, contains('hx-select-oob="#topbar,#sidebar"'));
      expect(html, contains('Research'));
    });

    test('renders nav items in system section', () async {
      final html = await engine.renderFileFragment(
        'sidebar',
        fragment: 'sidebar',
        context: {
          'mainSession': false,
          'mainHref': '',
          'mainActive': false,
          'noChannels': true,
          'channels': <Map<String, dynamic>>[],
          'noEntries': true,
          'entries': <Map<String, dynamic>>[],
          'hasNav': true,
          'navItems': [
            {'label': 'Health', 'href': '/health-dashboard', 'active': true, 'ariaCurrent': 'page'},
            {'label': 'Settings', 'href': '/settings', 'active': false, 'ariaCurrent': null},
          ],
        },
      );
      expect(html, contains('Health'));
      expect(html, contains('Settings'));
      expect(html, contains('sidebar-nav-item'));
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
          'cards': [
            {
              'title': 'Worker',
              'badgeClass': 'badge-success',
              'badgeText': 'OK',
              'rows': [
                {'label': 'State', 'valueClass': '', 'value': 'running'},
              ],
            },
          ],
          'metrics': [
            {'value': '12', 'label': 'Sessions'},
            {'value': '2.4 MB', 'label': 'DB Size'},
          ],
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
          'cards': <Map<String, dynamic>>[],
          'metrics': <Map<String, dynamic>>[],
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
          'healthBadgeClass': 'status-badge-success',
          'healthLabel': 'Healthy',
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
          'healthBadgeClass': '',
          'healthLabel': 'OK',
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
      expect(html, contains('/whatsapp/pairing'));
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
      expect(html, contains('You'));
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
      final html = await engine.renderFileFragment(
        'chat',
        fragment: 'turnFailed',
        context: {'detail': null},
      );
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
    });

    test('sendResponse renders user message and SSE connector', () async {
      final html = await engine.renderFileFragment(
        'chat',
        fragment: 'sendResponse',
        context: {
          'message': 'Hello <world>',
          'sseUrl': '/api/sessions/s1/stream?turn=t1',
        },
      );
      expect(html, contains('msg-user'));
      expect(html, contains('Hello &lt;world&gt;'));
      expect(html, contains('streaming-msg'));
      expect(html, contains('data-sse-url="/api/sessions/s1/stream?turn=t1"'));
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
