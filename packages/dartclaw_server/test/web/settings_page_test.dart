import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
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
      expect(html, contains('Task Workers busy'));
    });
  });
}

Future<String> _renderHtml(SettingsPage page, SessionService sessions) async {
  final response = await page.handler(
    Request('GET', Uri.parse('http://localhost/settings')),
    PageContext(
      sessions: sessions,
      appDisplay: const AppDisplayParams(),
      buildSidebarData: () async => _emptySidebarData,
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
);
