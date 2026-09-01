import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide GoogleJwtVerifier, TurnManager, TurnRunner;
import 'package:dartclaw_runtime/dartclaw_runtime.dart';
import 'package:dartclaw_runtime/src/templates/sidebar.dart';
import 'package:dartclaw_runtime/src/health/health_service.dart';
import 'package:dartclaw_runtime/src/web/pages/settings_page.dart';
import 'package:dartclaw_runtime/src/web/settings/settings_sections.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import '../test_utils.dart';

void main() {
  late SettingsPage page;
  late Directory tempDir;
  late SessionService sessions;

  setUpAll(() async {
    initTemplates(await resolveTemplatesDir());
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

    test('declares every channel and guard route while web_routes owns none of them', () async {
      expect(page.declaredRoutes, contains((method: 'GET', path: '/settings/channels/<type>')));
      expect(page.declaredRoutes, contains((method: 'POST', path: '/settings/channels/<type>/access')));
      expect(page.declaredRoutes, contains((method: 'GET', path: '/settings/guards/<guard>')));
      final webRoutesSource = File(p.normalize(p.join(await resolveStaticDir(), '..', 'web', 'web_routes.dart')))
          .readAsStringSync();
      expect(webRoutesSource, isNot(contains("'/settings/channels/")));
      expect(webRoutesSource, isNot(contains("'/settings/guards/")));
    });

    test('every registered channels and guards field has exactly one owning surface', () {
      final owners = <String>[];
      for (final type in ['whatsapp', 'signal', 'google_chat']) {
        owners.addAll(channelRegistryFields(type).map((field) => field.yamlPath));
        owners.addAll(
          channelPurposeBuiltConfigFields.map((field) => 'channels.$type.$field').where(ConfigMeta.fields.containsKey),
        );
      }
      owners.addAll(guardRegistryFields().map((field) => field.yamlPath));
      owners.addAll(guardEditorConfigFields.where(ConfigMeta.fields.containsKey));

      final expected = ConfigMeta.fields.keys
          .where((path) => path.startsWith('channels.') || path.startsWith('guards.'))
          .toSet();
      expect(owners.toSet(), expected);
      expect(owners.length, expected.length, reason: 'a registered field is claimed by more than one surface');
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
      // One control per tab and one panel group per card: the strip and the
      // panels both come from the section map, so the counts are its size.
      expect(html, _hasMatchCount('role="tab"', settingsTabs.length));
      // Every panel plus the guard editor's own inner tabpanel.
      expect(html, _hasMatchCount('role="tabpanel"', settingsPanels.length + 1));
      expect(
        html,
        contains(
          'aria-controls="panel-server-config panel-server-gateway panel-server-github panel-server-git-sync '
          'panel-server-auth panel-server-health panel-server-workspace"',
        ),
      );
      // Every aria-controls token resolves to an element that exists.
      for (final id in RegExp(r'aria-controls="([^"]*)"').allMatches(html).expand((m) => m.group(1)!.split(' '))) {
        expect(html, contains('id="$id"'), reason: 'aria-controls names a panel that is not rendered: $id');
      }
      // The topbar owns the page title; the in-page head carries the subtitle.
      expect(html, _hasMatchCount('<h1', 1));
      expect(html, contains('Configuration and system status'));
    });

    test('a worker executing a turn is labelled healthy, the same word /health reports', () async {
      final html = await _renderHtml(SettingsPage(workerStateGetter: () => WorkerState.busy), sessions);
      final healthCard = _systemHealthCard(html);

      // The badge is a projection of healthStatusForWorkerState, not a second
      // reading of the raw worker state: a busy worker is a working worker.
      expect(healthCard, contains('>${_capitalize(healthStatusForWorkerState(WorkerState.busy))}<'));
      expect(healthCard, contains('status-badge-success'));
      expect(healthCard, isNot(contains('Unhealthy')));
    });

    test('a worker the server cannot report reads degraded, the same word /health reports', () async {
      final html = await _renderHtml(SettingsPage(), sessions);
      final healthCard = _systemHealthCard(html);

      expect(healthCard, contains('>${_capitalize(healthStatusForWorkerState(null))}<'));
      expect(healthCard, contains('status-badge-warning'));
    });

    test('a server with no writable config says so instead of showing dead controls', () async {
      final html = await _renderHtml(page, sessions);

      // Values are server-rendered now, so nothing advertises loading and no
      // control waits behind a placeholder a client fetch would resolve.
      expect(html, isNot(contains('Loading...')));
      expect(html, isNot(contains('data-field-skeleton')));
      // This page has no ConfigWriter wired, so every editable panel renders
      // the shared empty state — an empty container would leave the tab strip
      // pointing at nothing.
      expect(html, contains('Configuration editing unavailable'));
      expect(html, contains('class="empty-state"'));
    });

    test('the guard editor renders from the canonical tab and table components', () async {
      final html = await _renderHtml(page, sessions);

      expect(html, contains('class="data-table guard-editor-table"'));
      expect(html, isNot(contains('guard-editor-tab"')));
      expect(html, contains('<div class="tabs" role="tablist" aria-label="Guard types" data-guard-editor-tabs='));
    });

    test('a nearing-expiry subscription credential is fully readable on its card', () async {
      final providerStatus = await _seededProviderStatus();
      providerStatus.recordCredentialHealth(
        providerId: 'claude',
        state: CredentialHealthState.nearingExpiry,
        checkedAt: DateTime.now().subtract(const Duration(hours: 3)),
        mode: CredentialMode.subscription,
        expiry: CredentialExpiry(
          issuedAt: DateTime.now().subtract(const Duration(days: 345)),
          expiresAt: DateTime.now().add(const Duration(days: 20, hours: 1)),
          derived: true,
        ),
        remediation: 'claude setup-token',
      );
      final html = await _renderHtml(SettingsPage(providerStatus: providerStatus), sessions);
      final card = _credentialSection(html, 'claude');

      expect(card, contains('Subscription'));
      expect(card, contains('Renewal in 20d · derived'));
      expect(card, contains('Nearing expiry'));
      expect(card, contains('status-badge-warning'));
      expect(card, contains('Checked 3h ago'));
      expect(card, contains('<code>claude setup-token</code>'));
      expect(card, contains('Fix:'));
      // The card's top-level badge follows the credential state rather than
      // contradicting it. This assertion previously pinned the opposite
      // (`status-badge-success` beside a "Nearing expiry" warning), which left
      // the most-read element on the surface an operator with no alert target
      // is left with reading green while the section under it did not.
      final cardHtml = _providerCardHtml(html, 'claude');
      expect(cardHtml, isNot(contains('status-badge-success')));
      expect(cardHtml, contains('Degraded'));
    });

    test('a card presenting a stored subscription names the store, not an API-key env var', () async {
      final providerStatus = await _seededProviderStatus();
      providerStatus.recordCredentialHealth(
        providerId: 'claude',
        state: CredentialHealthState.healthy,
        checkedAt: DateTime.now(),
        mode: CredentialMode.subscription,
      );
      final card = _credentialSection(
        await _renderHtml(SettingsPage(providerStatus: providerStatus), sessions),
        'claude',
      );

      // The env-var line sits directly above the mode label, so naming the
      // API-key variable here told the operator the card presented a key while
      // the next line read "Subscription".
      expect(card, contains('Stored subscription credential'));
      expect(card, contains('Subscription'));
      expect(card, isNot(contains('ANTHROPIC_API_KEY')));
    });

    test('an API-key card still names the environment variable its key comes from', () async {
      final providerStatus = await _seededProviderStatus();
      providerStatus.recordCredentialHealth(
        providerId: 'claude',
        state: CredentialHealthState.healthy,
        checkedAt: DateTime.now(),
        mode: CredentialMode.apiKey,
      );
      final card = _credentialSection(
        await _renderHtml(SettingsPage(providerStatus: providerStatus), sessions),
        'claude',
      );

      expect(card, contains('ANTHROPIC_API_KEY'));
      expect(card, isNot(contains('Stored subscription credential')));
    });

    test('an API-key provider gains a mode label and nothing that ages', () async {
      final providerStatus = await _seededProviderStatus();
      providerStatus.recordCredentialHealth(
        providerId: 'claude',
        state: CredentialHealthState.healthy,
        checkedAt: DateTime.now(),
        mode: CredentialMode.apiKey,
      );
      final card = _credentialSection(
        await _renderHtml(SettingsPage(providerStatus: providerStatus), sessions),
        'claude',
      );

      expect(card, contains('API key'));
      expect(card, isNot(contains('Renewal')));
      expect(card, isNot(contains('unknown')));
      expect(card, isNot(contains('status-badge')));
      expect(card, isNot(contains('<code>')));
    });

    test('reauth-required is readable with its fix without any alert configuration', () async {
      final providerStatus = await _seededProviderStatus();
      providerStatus.recordCredentialHealth(
        providerId: 'codex',
        state: CredentialHealthState.reauthRequired,
        checkedAt: DateTime.now(),
        remediation: 'codex login',
      );
      // No AlertRouter, no channel and no alert config is wired into this page;
      // the rendering must not depend on one.
      final card = _credentialSection(
        await _renderHtml(SettingsPage(providerStatus: providerStatus), sessions),
        'codex',
      );

      expect(card, contains('Re-authentication required'));
      expect(card, contains('status-badge-error'));
      expect(card, contains('<code>codex login</code>'));
    });

    test('a transient refresh failure reads as a warning, not as a lost credential', () async {
      final providerStatus = await _seededProviderStatus();
      providerStatus.recordCredentialHealth(
        providerId: 'codex',
        state: CredentialHealthState.refreshFailure,
        checkedAt: DateTime.now(),
        mode: CredentialMode.subscription,
      );
      final card = _credentialSection(
        await _renderHtml(SettingsPage(providerStatus: providerStatus), sessions),
        'codex',
      );

      expect(card, contains('Refresh failed'));
      expect(card, contains('status-badge-warning'));
      expect(card, isNot(contains('status-badge-error')));
    });

    test('a renewal deadline already gone by reads as passed, never as time remaining', () async {
      final providerStatus = await _seededProviderStatus();
      providerStatus.recordCredentialHealth(
        providerId: 'codex',
        state: CredentialHealthState.reauthRequired,
        checkedAt: DateTime.now(),
        mode: CredentialMode.subscription,
        expiry: CredentialExpiry(
          issuedAt: DateTime.now().subtract(const Duration(days: 10)),
          expiresAt: DateTime.now().subtract(const Duration(days: 2)),
          derived: true,
        ),
        remediation: 'codex login',
      );
      final card = _credentialSection(
        await _renderHtml(SettingsPage(providerStatus: providerStatus), sessions),
        'codex',
      );

      expect(card, contains('Renewal deadline passed: 2d ago · derived'));
      expect(card, isNot(contains('Renewal in')));
    });

    test('a contract break reads as a broken contract, never as an expiry', () async {
      final providerStatus = await _seededProviderStatus();
      providerStatus.recordCredentialHealth(
        providerId: 'codex',
        state: CredentialHealthState.contractBreak,
        checkedAt: DateTime.now(),
        mode: CredentialMode.subscription,
      );
      final card = _credentialSection(
        await _renderHtml(SettingsPage(providerStatus: providerStatus), sessions),
        'codex',
      );

      expect(card, contains('Mediation contract broken'));
      expect(card, contains('status-badge-error'));
      expect(card, isNot(contains('expired')));
      expect(card, isNot(contains('Re-authentication')));
    });

    // The monitor emits `unknown` in exactly two shapes, and neither carries
    // both a mode and a remediation: the no-computable-deadline arm records a
    // subscription mode with no command, the vendor-login arm a command with no
    // mode. Each is seeded here as the monitor would record it.
    test('a subscription credential with no computable deadline renders unknown, not a fault', () async {
      final providerStatus = await _seededProviderStatus();
      providerStatus.recordCredentialHealth(
        providerId: 'claude',
        state: CredentialHealthState.unknown,
        checkedAt: DateTime.now(),
        mode: CredentialMode.subscription,
      );
      final response = await SettingsPage(providerStatus: providerStatus)
          .handler(Request('GET', Uri.parse('http://localhost/settings')), _pageContext(sessions));
      final html = await response.readAsString();
      final card = _credentialSection(html, 'claude');

      expect(response.statusCode, 200);
      expect(card, contains('Renewal deadline unknown'));
      expect(card, contains('value-absent'));
      expect(card, contains('status-badge-muted'));
      expect(card, isNot(contains('status-badge-warning')));
      expect(card, isNot(contains('status-badge-error')));
      expect(card, isNot(contains('<code>')));
      // Every other card still renders.
      expect(html, _hasMatchCount('data-provider-id="', 3));
    });

    test('an interactive vendor login reads as informational, not as a fault', () async {
      final providerStatus = await _seededProviderStatus();
      providerStatus.recordCredentialHealth(
        providerId: 'claude',
        state: CredentialHealthState.unknown,
        checkedAt: DateTime.now(),
        remediation: 'claude setup-token',
      );
      final card = _credentialSection(
        await _renderHtml(SettingsPage(providerStatus: providerStatus), sessions),
        'claude',
      );

      expect(card, contains('Lifetime not checkable'));
      expect(card, contains('status-badge-muted'));
      expect(card, isNot(contains('status-badge-warning')));
      expect(card, isNot(contains('status-badge-error')));
      // DartClaw holds no credential of its own here, so naming a mode or a
      // deadline would invent data the monitor never observed.
      expect(card, isNot(contains('Subscription')));
      expect(card, isNot(contains('Renewal')));
      // The credential works; its command is the route to DartClaw-managed auth
      // rather than a repair.
      expect(card, contains('DartClaw-managed auth:'));
      expect(card, contains('<code>claude setup-token</code>'));
      expect(card, isNot(contains('Fix:')));
    });

    test('a provider with no recorded credential health renders exactly as before', () async {
      final providerStatus = await _seededProviderStatus();
      providerStatus.recordCredentialHealth(
        providerId: 'claude',
        state: CredentialHealthState.nearingExpiry,
        checkedAt: DateTime.now(),
        mode: CredentialMode.subscription,
        expiry: CredentialExpiry(
          issuedAt: DateTime.now(),
          expiresAt: DateTime.now().add(const Duration(days: 3)),
          derived: true,
        ),
        remediation: 'claude setup-token',
      );
      final html = await _renderHtml(SettingsPage(providerStatus: providerStatus), sessions);

      // ghost_ai has no recorded health, so its credential section must carry
      // the pre-monitor markup and nothing else: the existing dot, status label
      // and env line, with no empty row left behind by a suppressed element.
      // Pinned against the rendered content — a suppressed element still leaves
      // its (inert) indentation behind, which is all this collapse discards.
      expect(
        _collapseWhitespace(_credentialSection(html, 'ghost_ai')),
        '<div class="detail-label">Credentials</div> '
        '<div class="credential-status"> '
        '<span class="credential-dot credential-dot-missing"></span> '
        '<span class="detail-value detail-value-error">Missing</span> '
        '</div> '
        '<div class="credential-env">Credential source not configured</div> '
        '</div>',
      );
      // The seeded secret never reaches the page.
      expect(html, isNot(contains('anthropic-key')));
    });
  });
}

Future<String> _renderHtml(SettingsPage page, SessionService sessions) async {
  final response = await page.handler(Request('GET', Uri.parse('http://localhost/settings')), _pageContext(sessions));

  return response.readAsString();
}

PageContext _pageContext(SessionService sessions) => PageContext(
  sessions: sessions,
  sidebarData: () async => _emptySidebarData,
  restartBannerHtml: () => '',
  buildNavItems: ({required String activePage}) => const [],
);

/// The System Health card, isolated so the badge assertion cannot be satisfied
/// by a provider card's health badge elsewhere on the page.
String _systemHealthCard(String html) {
  final start = html.indexOf('id="panel-server-health"');
  expect(start, greaterThan(-1), reason: 'no system-health card rendered');
  final header = html.indexOf('card-header', start);
  expect(header, greaterThan(-1), reason: 'the system-health card renders no header');
  return html.substring(start, html.indexOf('</div>', header));
}

String _capitalize(String value) => value[0].toUpperCase() + value.substring(1);

/// The rendered `<article>` body for one provider card.
String _providerCardHtml(String html, String providerId) {
  final start = html.indexOf('data-provider-id="$providerId"');
  expect(start, greaterThan(-1), reason: 'no card rendered for $providerId');
  return html.substring(start, html.indexOf('</article>', start));
}

/// Renders a markup run comparable across template edits that only change the
/// indentation of suppressed elements.
String _collapseWhitespace(String html) => html.replaceAll(RegExp(r'\s+'), ' ').trim();

/// The credential `provider-detail-item` of one provider card, isolated so a
/// parity assertion cannot be satisfied by unrelated markup elsewhere on the
/// card.
String _credentialSection(String html, String providerId) {
  final items = _providerCardHtml(html, providerId).split('<div class="provider-detail-item">');
  return items.firstWhere(
    (item) => item.contains('>Credentials<'),
    orElse: () => fail('no credential detail item rendered for $providerId'),
  );
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
