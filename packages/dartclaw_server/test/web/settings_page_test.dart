import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide GoogleJwtVerifier, TurnManager, TurnRunner;
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:dartclaw_server/src/templates/sidebar.dart';
import 'package:dartclaw_server/src/web/pages/settings_page.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import '../test_utils.dart';

void main() {
  late SettingsPage page;
  late Directory tempDir;
  late SessionService sessions;

  setUpAll(() {
    initTemplates(resolveTemplatesDir());
  });

  tearDownAll(() {
    resetTemplates();
  });

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('settings_page_test_');
    sessions = SessionService(baseDir: tempDir.path);
    page = SettingsPage();
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  group('SettingsPage shell', () {
    test('keeps the existing route metadata', () {
      expect(page.route, '/settings');
      expect(page.title, 'Settings');
      expect(page.navGroup, 'system');
    });

    test('renders the current settings sections', () async {
      final html = await _renderHtml(page, sessions);

      expect(html, contains('Settings'));
      expect(html, contains('Channels'));
      expect(html, contains('Security'));
      expect(html, contains('System Health'));
    });

    test('renders configured provider cards and provider-specific status hooks', () async {
      final providerStatus = await _seededProviderStatus();
      final html = await _renderHtml(SettingsPage(providerStatus: providerStatus), sessions);

      expect(html, contains('href="#providers"'));
      expect(html, _hasMatchCount('data-provider-id="', 3));
      expect(html, contains('data-provider-id="claude"'));
      expect(html, contains('data-provider-id="codex"'));
      expect(html, contains('data-provider-id="ghost_ai"'));
      expect(html, contains('Default'));
      expect(html, contains('provider-error-banner'));
      expect(html, contains('CODEX_API_KEY'));
      expect(html, contains('Unavailable'));
      expect(html, contains('credential-dot'));
      expect(html, contains('credential-dot-ok'));
      expect(html, contains('credential-dot-missing'));
      expect(html, contains('Provider ID: codex'));
      expect(html, contains('worker leases active'));
      expect(html, contains('Worker Capacity'));
      expect(html, contains('class="meter meter--empty"'));
      expect(html, isNot(contains('pool-bar')));
    });

    test('the tab strip is a real tab widget and the topbar keeps the only h1', () async {
      final html = await _renderHtml(page, sessions);

      expect(html, contains('role="tablist"'));
      // Ten controls, ten panel groups: every card is a panel, and the four
      // that share the Server tab are named on one aria-controls list.
      expect(html, _hasMatchCount('role="tab"', 10));
      expect(html, _hasMatchCount('role="tabpanel"', 16));
      expect(
        html,
        contains('aria-controls="panel-server-config panel-server-auth panel-server-health panel-server-workspace"'),
      );
      // Every aria-controls token resolves to an element that exists.
      for (final id in RegExp(r'aria-controls="([^"]*)"').allMatches(html).expand((m) => m.group(1)!.split(' '))) {
        expect(html, contains('id="$id"'), reason: 'aria-controls names a panel that is not rendered: $id');
      }
      // The topbar owns the page title; the in-page head carries the subtitle.
      expect(html, _hasMatchCount('<h1', 1));
      expect(html, contains('Configuration and system status'));
    });

    test('settings states what it does not know instead of faking it', () async {
      final html = await _renderHtml(page, sessions);

      // No field advertises loading through its own text or placeholder; the
      // in-flight treatment is a skeleton the controller swaps out on populate.
      expect(html, isNot(contains('Loading...')));
      expect(html, contains('data-field-skeleton'));
      // agent.effort declares no allowed values, so the control is not
      // presented as a picker whose only row is a bare em dash.
      expect(html, isNot(contains('<option value="">—</option>')));
      expect(html, contains('<option value="">Default</option>'));
    });

    test('the guard editor renders from the canonical tab and table components', () async {
      final html = await _renderHtml(page, sessions);

      expect(html, contains('class="data-table guard-editor-table"'));
      expect(html, isNot(contains('guard-editor-tab"')));
      expect(html, contains('<div class="tabs" role="tablist" aria-label="Guard types" data-guard-editor-tabs='));
    });

    test('related fields read as labelled groups and short numerics are capped', () async {
      final html = await _renderHtml(page, sessions);

      // Grouping, not decoration: each well is a role pair or a named cluster
      // with its own accessible name.
      expect(RegExp('class="well ').allMatches(html).length, greaterThanOrEqualTo(8));
      expect(RegExp('role="group"').allMatches(html).length, greaterThanOrEqualTo(8));
      for (final field in ['field-port', 'field-agent-max-turns', 'field-sessions-reset-hour']) {
        expect(
          RegExp('form-input--num[^>]*id="$field"').hasMatch(html),
          isTrue,
          reason: '$field spans the card measure for a two-character value',
        );
      }
      // The width scale is canon's; settings applies it and declares none.
      expect(html, isNot(contains('max-width')));
    });
  });
}

Future<String> _renderHtml(SettingsPage page, SessionService sessions) async {
  final response = await page.handler(
    Request('GET', Uri.parse('http://localhost/settings')),
    PageContext(
      sessions: sessions,
      appDisplay: const AppDisplayParams(),
      sidebarData: () async => _emptySidebarData,
      restartBannerHtml: () => '',
      buildNavItems: ({required String activePage}) => const [],
    ),
  );

  return response.readAsString();
}

Future<ProviderStatusService> _seededProviderStatus() async {
  final service = ProviderStatusService(
    providers: const ProvidersConfig(
      entries: {
        'claude': ProviderEntry(executable: 'claude', poolSize: 2),
        'codex': ProviderEntry(executable: 'codex', poolSize: 1),
        'ghost_ai': ProviderEntry(executable: 'ghost-ai', poolSize: 1),
      },
    ),
    registry: CredentialRegistry(
      credentials: const CredentialsConfig(entries: {'anthropic': CredentialEntry(apiKey: 'anthropic-key')}),
    ),
    defaultProvider: 'claude',
  );

  await service.probe(
    commandProbe: _probeResults({
      'claude': _probeOk('Claude CLI 5.0.0'),
      'codex': _probeOk('Codex CLI 2.0.0'),
      'ghost-ai': _probeMissing('ghost-ai'),
    }),
    authProbe: (_, {String? providerId}) async => false,
  );

  return service;
}

Matcher _hasMatchCount(String pattern, int expectedCount) {
  return predicate<String>(
    (value) => RegExp(pattern).allMatches(value).length == expectedCount,
    'contains $expectedCount matches for $pattern',
  );
}

CommandProbe _probeResults(Map<String, CommandProbe> probes) {
  return (executable, arguments) {
    final probe = probes[executable];
    if (probe == null) {
      throw ProcessException(executable, arguments, 'No probe configured for test');
    }
    return probe(executable, arguments);
  };
}

CommandProbe _probeOk(String stdout, {String stderr = ''}) {
  return (executable, arguments) async => ProcessResult(1, 0, stdout, stderr);
}

CommandProbe _probeMissing(String executableName) {
  return (executable, arguments) async => throw ProcessException(executableName, arguments, 'missing binary');
}

final _emptySidebarData = (
  main: null,
  dmChannels: <SidebarSession>[],
  groupChannels: <SidebarSession>[],
  activeEntries: <SidebarSession>[],
  archivedEntries: <SidebarSession>[],
  activeTasks: <SidebarActiveTask>[],
  activeWorkflows: <SidebarActiveWorkflow>[],
  showChannels: true,
  tasksEnabled: false,
  activeSessionId: null,
);
