import 'dart:async';

import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:dartclaw_core/dartclaw_core.dart' show CredentialHealthChangedEvent, CredentialHealthState;
import 'package:dartclaw_server/src/alerts/alert_router.dart';
import 'package:dartclaw_server/src/alerts/credential_health_monitor.dart';
import 'package:dartclaw_server/src/provider_status_service.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' show TestEventBus;
import 'package:logging/logging.dart';
import 'package:test/test.dart';

import '../helpers/probe_helpers.dart';
import 'alert_test_support.dart';

const _target = AlertTarget(channel: 'whatsapp', recipient: '+1000');

const _claudeToken = 'sk-ant-oat01-not-a-real-token';
const _codexToken = 'header.payload.signature';

/// The store this deployment resolves — deliberately not the default one, so an
/// assertion that it is named cannot pass on a hardcoded `~/.dartclaw` path.
const _credentialsDir = '/srv/dartclaw-instance/credentials';

/// Every remediation must name both the command to run and the store it has to
/// reach: `data_dir` selects the store, so a command with no store sends an
/// operator to re-run something they may already have run against another
/// instance.
Matcher _remediationNaming(String command) => allOf(contains(command), contains(_credentialsDir));

/// A stored Claude `setup-token`: no expiry claim, so the expiry is derived
/// from the issue time plus the documented one-year lifetime.
ProviderCredential _claudeSubscription({required DateTime issuedAt}) => (
  family: 'claude',
  resolution: CredentialResolution.subscription(
    CredentialEntry.subscription(
      token: _claudeToken,
      expiry: CredentialExpiry(issuedAt: issuedAt, expiresAt: issuedAt.add(const Duration(days: 365)), derived: true),
    ),
  ),
);

/// A stored Codex credential: [issuedAt] is the dedicated store's last write
/// (what refresh staleness is measured from) and [accessTokenExpiresAt] is the
/// minutes-scale JWT `exp` that refresh replaces without operator action.
ProviderCredential _codexSubscription({required DateTime issuedAt, required DateTime accessTokenExpiresAt}) => (
  family: 'codex',
  resolution: CredentialResolution.subscription(
    CredentialEntry.subscription(
      token: _codexToken,
      expiry: CredentialExpiry(issuedAt: issuedAt, expiresAt: accessTokenExpiresAt, derived: false),
    ),
  ),
);

ProviderCredential _apiKey(String family, String key) => (family: family, resolution: CredentialResolution.apiKey(key));

ProviderCredential _unavailable(String family, CredentialUnavailableReason reason) =>
    (family: family, resolution: CredentialResolution.unavailable(reason));

ProviderStatusService _providerStatus() => ProviderStatusService(
  providers: const ProvidersConfig(
    entries: {
      'claude': ProviderEntry(executable: 'claude'),
      'codex': ProviderEntry(executable: 'codex'),
    },
  ),
  registry: CredentialRegistry(credentials: const CredentialsConfig()),
  defaultProvider: 'claude',
);

/// Mutable probe fixture: tests advance [now] and swap [resolutions] between
/// runs, so window boundaries are asserted at exact offsets with no waiting.
class _Fixture {
  final TestEventBus bus = TestEventBus();
  final FakeAlertDeliveryAdapter adapter = FakeAlertDeliveryAdapter();
  final ProviderStatusService providerStatus = _providerStatus();
  final List<LogRecord> warnings = [];

  late final AlertRouter router;
  late final CredentialHealthMonitor monitor;

  Map<String, ProviderCredential> resolutions = {};
  DateTime now = DateTime.utc(2026, 8, 15, 12);

  /// [AlertThrottle]'s cooldown is zeroed so a suppressed *duplicate* cannot be
  /// mistaken for the monitor's own edge-trigger; the throttle is a separate
  /// layer with its own suite.
  new({bool alertsEnabled = true, List<AlertTarget> targets = const [_target]}) {
    router = AlertRouter(
      bus: bus,
      adapter: adapter,
      config: AlertsConfig(enabled: alertsEnabled, targets: targets, cooldownSeconds: 0, burstThreshold: 5),
    );
    monitor = CredentialHealthMonitor(
      eventBus: bus,
      providerStatus: providerStatus,
      resolveCredentials: () => resolutions,
      credentialsDir: _credentialsDir,
      now: () => now,
    );
  }

  Map<String, dynamic> json(String providerId) =>
      providerStatus.all.firstWhere((status) => status.id == providerId).toJson();

  /// Runs the provider probe with both collaborators injected — no process is
  /// spawned and nothing is read from `PATH`, so the outcome is identical on a
  /// developer machine and on a clean-PATH CI box.
  Future<void> probeBinaries({required bool authenticated}) => providerStatus.probe(
    commandProbe: probeResults({'claude': probeOk('Claude CLI 1.0.0'), 'codex': probeOk('Codex CLI 1.0.0')}),
    authProbe: (executable, {providerId}) async => authenticated,
  );

  List<String> get deliveredText => adapter.delivered.map((entry) => entry.$2.text).toList();

  Future<void> dispose() async {
    await router.cancel();
    await bus.dispose();
  }
}

/// Drains the broadcast bus so `AlertRouter` has seen everything fired.
Future<void> _settle() => pumpEventQueue();

void main() {
  late _Fixture fixture;
  late StreamSubscription<LogRecord> logSubscription;

  setUp(() {
    fixture = _Fixture();
    // LogService bridges records to stderr in serve; the monitor only emits the
    // record, so that is what the warning assertions capture.
    logSubscription = Logger.root.onRecord.listen((record) {
      if (record.loggerName == 'CredentialHealthMonitor' && record.level >= Level.WARNING) {
        fixture.warnings.add(record);
      }
    });
  });

  tearDown(() async {
    await logSubscription.cancel();
    await fixture.dispose();
  });

  group('classification against per-provider windows', () {
    test('Claude classifies healthy at 31 days from its derived expiry and nearing-expiry at 29', () async {
      // The derived expiry is issuedAt + 365 days, so issuing 334 days ago
      // leaves 31.
      fixture.resolutions = {'claude': _claudeSubscription(issuedAt: fixture.now.subtract(const Duration(days: 334)))};
      fixture.monitor.probe();
      expect(fixture.json('claude')['credentialHealth'], 'healthy');

      fixture.resolutions = {'claude': _claudeSubscription(issuedAt: fixture.now.subtract(const Duration(days: 336)))};
      fixture.monitor.probe();
      expect(fixture.json('claude')['credentialHealth'], 'nearing-expiry');
      expect(fixture.json('claude')['credentialRemediation'], _remediationNaming('dartclaw auth claude'));
    });

    test('Codex ages against refresh staleness, and a minutes-away JWT exp changes nothing', () async {
      // Both stores carry an access token 12 minutes from its own `exp`; only
      // the 8-day staleness deadline is operator-actionable.
      final soon = fixture.now.add(const Duration(minutes: 12));

      fixture.resolutions = {
        'codex': _codexSubscription(
          issuedAt: fixture.now.subtract(const Duration(days: 5)),
          accessTokenExpiresAt: soon,
        ),
      };
      fixture.monitor.probe();
      expect(fixture.json('codex')['credentialHealth'], 'healthy', reason: '72 hours of staleness headroom remains');

      fixture.resolutions = {
        'codex': _codexSubscription(
          issuedAt: fixture.now.subtract(const Duration(days: 6)),
          accessTokenExpiresAt: soon,
        ),
      };
      fixture.monitor.probe();
      expect(fixture.json('codex')['credentialHealth'], 'nearing-expiry', reason: 'exactly at the 48-hour window');

      fixture.resolutions = {
        'codex': _codexSubscription(
          issuedAt: fixture.now.subtract(const Duration(days: 7)),
          accessTokenExpiresAt: soon,
        ),
      };
      fixture.monitor.probe();
      expect(fixture.json('codex')['credentialHealth'], 'nearing-expiry', reason: '24 hours from the deadline');

      // A store written 20 minutes ago is healthy even though its access token
      // expires in 12 minutes — refresh replaces it without operator action.
      fixture.resolutions = {
        'codex': _codexSubscription(
          issuedAt: fixture.now.subtract(const Duration(minutes: 20)),
          accessTokenExpiresAt: soon,
        ),
      };
      fixture.monitor.probe();
      expect(fixture.json('codex')['credentialHealth'], 'healthy');
      expect(fixture.deliveredText.where((text) => text.contains('codex')), isEmpty);
    });

    test('the published Codex expiry is the staleness deadline, never the access token exp', () async {
      final issuedAt = fixture.now.subtract(const Duration(days: 7));
      final accessTokenExpiresAt = fixture.now.add(const Duration(minutes: 12));
      fixture.resolutions = {
        'codex': _codexSubscription(issuedAt: issuedAt, accessTokenExpiresAt: accessTokenExpiresAt),
      };
      fixture.monitor.probe();

      // Publishing the minutes-scale JWT exp would render a healthy Codex as
      // "expires in 12 minutes" on the provider card.
      expect(fixture.json('codex')['credentialExpiresAt'], issuedAt.add(const Duration(days: 8)).toIso8601String());
      expect(fixture.json('codex')['credentialExpiresAt'], isNot(accessTokenExpiresAt.toIso8601String()));
      expect(fixture.json('codex')['credentialExpiryDerived'], isTrue);
    });

    test('an alias resolves its vendor family, so it is windowed rather than reported unauthenticated', () async {
      final claude = _claudeSubscription(issuedAt: fixture.now.subtract(const Duration(days: 336)));
      fixture.resolutions = {'fast-claude': (family: 'claude', resolution: claude.resolution)};
      fixture.monitor.probe();
      await _settle();

      final event = fixture.bus.firedEvents.whereType<CredentialHealthChangedEvent>().single;
      expect(event.providerId, 'fast-claude');
      expect(event.state, CredentialHealthState.nearingExpiry);
      expect(event.remediation, _remediationNaming('dartclaw auth claude'));
    });

    test('a passed deadline is reauth-required for both providers', () async {
      fixture.resolutions = {
        'claude': _claudeSubscription(issuedAt: fixture.now.subtract(const Duration(days: 366))),
        'codex': _codexSubscription(
          issuedAt: fixture.now.subtract(const Duration(days: 9)),
          accessTokenExpiresAt: fixture.now.add(const Duration(minutes: 12)),
        ),
      };
      fixture.monitor.probe();

      expect(fixture.json('claude')['credentialHealth'], 'reauth-required');
      expect(fixture.json('claude')['credentialRemediation'], _remediationNaming('dartclaw auth claude'));
      expect(fixture.json('codex')['credentialHealth'], 'reauth-required');
      expect(fixture.json('codex')['credentialRemediation'], _remediationNaming('dartclaw auth codex'));
    });

    test('an API key is healthy and a subscription with no computable expiry is unknown — neither alerts', () async {
      fixture.resolutions = {
        'claude': _apiKey('claude', 'anthropic-key'),
        // A stored credential whose issuedAt could not be read resolves without
        // an expiry at all.
        'codex': (
          family: 'codex',
          resolution: CredentialResolution.subscription(CredentialEntry.subscription(token: _codexToken)),
        ),
      };
      fixture.monitor.probe();
      await _settle();

      expect(fixture.json('claude')['credentialHealth'], 'healthy');
      expect(fixture.json('claude')['credentialMode'], 'api_key');
      expect(fixture.json('claude')['credentialExpiresAt'], isNull);
      expect(fixture.json('codex')['credentialHealth'], 'unknown');
      expect(fixture.json('codex')['credentialExpiresAt'], isNull);
      expect(fixture.adapter.delivered, isEmpty);
      expect(fixture.warnings, isEmpty);
    });

    test('an unresolvable credential is reauth-required with that provider remediation', () async {
      // No API key, no DartClaw store, and the binary reports no login of its
      // own: nothing can authenticate this provider.
      await fixture.probeBinaries(authenticated: false);
      fixture.resolutions = {
        'claude': _unavailable('claude', CredentialUnavailableReason.noneConfigured),
        'codex': _unavailable('codex', CredentialUnavailableReason.subscriptionAbsent),
      };
      fixture.monitor.probe();
      await _settle();

      expect(fixture.json('claude')['credentialHealth'], 'reauth-required');
      expect(fixture.json('claude')['credentialRemediation'], _remediationNaming('dartclaw auth claude'));
      expect(fixture.json('codex')['credentialRemediation'], _remediationNaming('dartclaw auth codex'));
      expect(fixture.deliveredText, hasLength(2), reason: 'a genuinely dead credential must still alert');
      expect(fixture.warnings, hasLength(2));
    });

    test('a provider authenticated by its own vendor login is uncheckable, not unauthenticated', () async {
      // The binary carries an interactive login DartClaw neither holds nor
      // inspects, so the credential resolves absent while the provider works.
      await fixture.probeBinaries(authenticated: true);
      fixture.resolutions = {'claude': _unavailable('claude', CredentialUnavailableReason.noneConfigured)};
      fixture.monitor.probe();
      await _settle();

      expect(fixture.json('claude')['credentialHealth'], 'unknown');
      expect(fixture.json('claude')['credentialReauthRequired'], isFalse);
      expect(fixture.json('claude')['credentialRemediation'], _remediationNaming('dartclaw auth claude'));
      expect(
        fixture.adapter.delivered,
        isEmpty,
        reason: 'paging an operator whose provider authenticates fine is the false alarm this rules out',
      );
      expect(fixture.warnings, isEmpty, reason: 'unknown is not a degraded state');
    });

    test('the vendor-login exemption never masks a provider DartClaw can check', () async {
      // An API key is DartClaw-held, so it stays healthy rather than falling
      // into the uncheckable branch.
      await fixture.probeBinaries(authenticated: true);
      fixture.resolutions = {'claude': _apiKey('claude', 'anthropic-key')};
      fixture.monitor.probe();
      await _settle();

      expect(fixture.json('claude')['credentialHealth'], 'healthy');
      expect(fixture.json('claude')['credentialMode'], 'api_key');
      expect(fixture.adapter.delivered, isEmpty);
    });

    test('a forced api_key selection is not sent to a login that cannot help', () async {
      fixture.resolutions = {'claude': _unavailable('claude', CredentialUnavailableReason.apiKeyAbsent)};
      fixture.monitor.probe();

      expect(fixture.json('claude')['credentialHealth'], 'reauth-required');
      // The reason names its own credential's fix and nothing else: an
      // ambient login satisfies neither the selection nor the store, so
      // naming either would send the operator somewhere that cannot help.
      final remediation = fixture.json('claude')['credentialRemediation'] as String;
      expect(remediation, allOf(contains('ANTHROPIC_API_KEY'), contains('auth: api_key')));
      expect(remediation, isNot(contains('dartclaw auth')));
      expect(remediation, isNot(contains(_credentialsDir)));
    });

    test('a Codex auth file that only proves presence does not earn the exemption', () async {
      // The codex arm of the auth probe checks that ~/.codex/auth.json parses
      // with a non-empty access token — no expiry, no revocation — so a
      // sign-in that died months ago still reads authenticated. Exempting it
      // would trade a false alarm for a missed one.
      await fixture.probeBinaries(authenticated: true);
      fixture.resolutions = {'codex': _unavailable('codex', CredentialUnavailableReason.noneConfigured)};
      fixture.monitor.probe();
      await _settle();

      expect(fixture.json('codex')['credentialHealth'], 'reauth-required');
      expect(fixture.json('codex')['credentialRemediation'], _remediationNaming('dartclaw auth codex'));
      expect(fixture.deliveredText.single, contains('Re-authentication Required'));
      expect(fixture.warnings, hasLength(1));
    });

    test('a live vendor login does not excuse a misconfiguration the operator has to fix', () async {
      // Claude's login is verifiable, so only the reason gate stands between
      // these and the exemption: the operator asked for an API key that is not
      // configured, or mistyped `auth`. An ambient login satisfies neither
      // selection, so exempting them would hide a real config fault behind a
      // credential DartClaw does not even manage.
      await fixture.probeBinaries(authenticated: true);

      for (final reason in [
        CredentialUnavailableReason.apiKeyAbsent,
        CredentialUnavailableReason.unrecognizedAuthSetting,
      ]) {
        fixture.resolutions = {'claude': _unavailable('claude', reason)};
        fixture.monitor.probe();
        await _settle();

        expect(fixture.json('claude')['credentialHealth'], 'reauth-required', reason: reason.name);
        // Each names the config fault's own fix and never a login: sending the
        // operator to `dartclaw auth` here would hide the fault behind a
        // credential that does not satisfy their selection.
        expect(
          fixture.json('claude')['credentialRemediation'],
          isNot(anyOf(isNull, contains('dartclaw auth'), contains(_credentialsDir))),
          reason: reason.name,
        );
      }
      expect(fixture.json('claude')['credentialRemediation'], contains('auto, subscription, api_key'));
      expect(fixture.deliveredText.single, contains('Re-authentication Required'));
      expect(fixture.warnings, hasLength(1), reason: 'one transition into reauth-required, not one per probe');
    });
  });

  group('edge-triggered emission', () {
    test('a persisting degradation alerts once while last-checked keeps advancing', () async {
      fixture.resolutions = {'claude': _claudeSubscription(issuedAt: fixture.now.subtract(const Duration(days: 345)))};

      for (var run = 0; run < 3; run++) {
        fixture.now = fixture.now.add(const Duration(hours: 1));
        fixture.monitor.probe();
        await _settle();
      }

      expect(fixture.adapter.delivered, hasLength(1));
      expect(fixture.deliveredText.single, contains('Credential Nearing Expiry'));
      expect(fixture.bus.firedEvents.whereType<CredentialHealthChangedEvent>(), hasLength(1));
      expect(fixture.warnings, hasLength(1));
      expect(fixture.warnings.single.message, allOf(contains('claude'), contains('nearing-expiry')));
      // The check timestamp still advances on every run.
      expect(fixture.json('claude')['credentialLastChecked'], fixture.now.toIso8601String());
    });

    test('recovery is silent and a second degradation alerts again', () async {
      fixture.resolutions = {'claude': _claudeSubscription(issuedAt: fixture.now.subtract(const Duration(days: 345)))};
      fixture.monitor.probe();
      await _settle();
      expect(fixture.adapter.delivered, hasLength(1));

      // Renewed credential: back to healthy, no "all clear" message.
      fixture.resolutions = {'claude': _claudeSubscription(issuedAt: fixture.now)};
      fixture.monitor.probe();
      await _settle();
      expect(fixture.adapter.delivered, hasLength(1));
      expect(fixture.json('claude')['credentialHealth'], 'healthy');

      fixture.resolutions = {'claude': _claudeSubscription(issuedAt: fixture.now.subtract(const Duration(days: 345)))};
      fixture.monitor.probe();
      await _settle();
      expect(fixture.adapter.delivered, hasLength(2));
      expect(fixture.warnings, hasLength(2));
    });

    test('an unchanging healthy provider announces nothing at all', () async {
      fixture.resolutions = {'claude': _claudeSubscription(issuedAt: fixture.now)};
      fixture.monitor.probe();
      fixture.monitor.probe();
      await _settle();

      expect(fixture.bus.firedEvents, isEmpty);
      expect(fixture.adapter.delivered, isEmpty);
      expect(fixture.warnings, isEmpty);
    });

    test('probe returns a summary naming how many providers were checked', () {
      fixture.resolutions = {
        'claude': _claudeSubscription(issuedAt: fixture.now.subtract(const Duration(days: 366))),
        'codex': _apiKey('codex', 'openai-key'),
      };

      expect(fixture.monitor.probe(), 'checked 2 providers, 1 degraded');
    });
  });

  group('visibility with no alert target', () {
    test('a disabled alert path still records the state and writes the warning', () async {
      final degraded = _Fixture(alertsEnabled: false, targets: const []);
      final records = <LogRecord>[];
      final subscription = Logger.root.onRecord.listen((record) {
        if (record.loggerName == 'CredentialHealthMonitor' && record.level >= Level.WARNING) records.add(record);
      });
      addTearDown(() async {
        await subscription.cancel();
        await degraded.dispose();
      });

      degraded.resolutions = {
        'codex': _codexSubscription(
          issuedAt: degraded.now.subtract(const Duration(days: 9)),
          accessTokenExpiresAt: degraded.now.add(const Duration(minutes: 12)),
        ),
      };
      degraded.monitor.probe();
      await _settle();

      expect(degraded.adapter.delivered, isEmpty, reason: 'nothing to deliver to');
      expect(degraded.json('codex')['credentialHealth'], 'reauth-required');
      expect(degraded.json('codex')['credentialRemediation'], _remediationNaming('dartclaw auth codex'));
      expect(degraded.json('codex')['credentialLastChecked'], degraded.now.toIso8601String());
      expect(records, hasLength(1));
      expect(
        records.single.message,
        allOf(contains('codex'), contains('reauth-required'), _remediationNaming('dartclaw auth codex')),
      );
      expect(records.single.message, isNot(contains(_codexToken)));
    });
  });

  group('credential material', () {
    test('a real stored token reaches neither the JSON, the alert, the event nor the log line', () async {
      // Driven through the resolution the probe actually reads, so the
      // assertion fails if any sink ever starts carrying the secret.
      fixture.resolutions = {
        'claude': _claudeSubscription(issuedAt: fixture.now.subtract(const Duration(days: 366))),
        'codex': _codexSubscription(
          issuedAt: fixture.now.subtract(const Duration(days: 9)),
          accessTokenExpiresAt: fixture.now.add(const Duration(minutes: 12)),
        ),
      };
      fixture.monitor.probe();
      await _settle();

      expect(fixture.json('claude')['credentialHealth'], 'reauth-required');
      expect(fixture.json('codex')['credentialHealth'], 'reauth-required');
      final sinks = [
        fixture.json('claude').toString(),
        fixture.json('codex').toString(),
        ...fixture.deliveredText,
        ...fixture.bus.firedEvents.map((event) => event.toString()),
        ...fixture.warnings.map((record) => record.message),
      ];
      for (final sink in sinks) {
        expect(sink, isNot(contains(_claudeToken)));
        expect(sink, isNot(contains(_codexToken)));
        expect(sink, isNot(contains('sk-ant')));
      }
    });
  });

  group('remediation authorship', () {
    // The monitor must not author remediation text of its own: an operator who
    // meets one wording at startup, another at admission, and a third on the
    // provider card cannot tell whether they are three conditions or one — and
    // a locally-written string is free to name a store the deployment does not
    // read, which is exactly how a credential ends up written where the server
    // never looks.
    test('every degraded state names both a command and the store this deployment reads', () async {
      final expired = fixture.now.subtract(const Duration(days: 400));
      final cases = <String, Map<String, ProviderCredential>>{
        'nothing stored': {'claude': _unavailable('claude', CredentialUnavailableReason.subscriptionAbsent)},
        'nothing configured': {'claude': _unavailable('claude', CredentialUnavailableReason.noneConfigured)},
        'stored but past its deadline': {'claude': _claudeSubscription(issuedAt: expired)},
        'stored and nearing its deadline': {
          'claude': _claudeSubscription(issuedAt: fixture.now.subtract(const Duration(days: 340))),
        },
      };

      for (final entry in cases.entries) {
        fixture.resolutions = entry.value;
        fixture.monitor.probe();

        expect(
          fixture.json('claude')['credentialRemediation'],
          _remediationNaming('dartclaw auth claude'),
          reason: '"${entry.key}" emitted a remediation that does not name the store it has to reach',
        );
      }
    });

    test('a condition reported by a detecting path names the store too', () async {
      // The admission refusal and the upstream 401 arrive through `report`,
      // which supplies no remediation of its own — the default it falls back to
      // is as store-qualified as the probe's.
      fixture.monitor.report(
        providerId: 'codex',
        state: CredentialHealthState.reauthRequired,
        detail: 'Upstream rejected the mediated credential (HTTP 401).',
      );
      await _settle();

      expect(fixture.json('codex')['credentialRemediation'], _remediationNaming('dartclaw auth codex'));
    });

    test('a family with no DartClaw-managed subscription flow gets no invented command', () async {
      // There is nothing to name for an unknown vendor, and inventing one would
      // send the operator to a command that does not exist.
      fixture.monitor.report(
        providerId: 'goose',
        state: CredentialHealthState.reauthRequired,
        detail: 'Upstream rejected the credential.',
      );
      await _settle();

      final status = fixture.providerStatus.all.where((entry) => entry.id == 'goose');
      expect(status, isEmpty, reason: 'an unconfigured provider has no card; the event is the observable sink');
      final event = fixture.bus.firedEvents.whereType<CredentialHealthChangedEvent>().single;
      expect(event.remediation, isNull);
    });
  });

  group('the report seam', () {
    test('a reported reauth-required alerts once and the probe finding it again does not alert twice', () async {
      fixture.resolutions = {'claude': _unavailable('claude', CredentialUnavailableReason.subscriptionAbsent)};

      fixture.monitor.report(
        providerId: 'claude',
        state: CredentialHealthState.reauthRequired,
        detail: 'Execution admission refused: no Claude subscription credential is stored.',
      );
      await _settle();

      expect(fixture.json('claude')['credentialHealth'], 'reauth-required');
      expect(fixture.json('claude')['credentialRemediation'], _remediationNaming('dartclaw auth claude'));
      expect(fixture.adapter.delivered, hasLength(1));

      fixture.monitor.probe();
      await _settle();

      expect(fixture.json('claude')['credentialHealth'], 'reauth-required');
      expect(
        fixture.adapter.delivered,
        hasLength(1),
        reason: 'one alert for the condition, not one per detecting path',
      );
    });

    test('a reported contract break stays a contract break and instructs no re-authentication', () async {
      fixture.monitor.report(
        providerId: 'codex',
        state: CredentialHealthState.contractBreak,
        detail: 'Upstream rejected the mediated Bearer form itself (HTTP 403).',
        // Even an explicit remediation is dropped: the seam owns the wording
        // contract, so no caller can turn this into a login instruction.
        remediation: 'codex login',
      );
      await _settle();

      expect(fixture.json('codex')['credentialHealth'], 'contract-break');
      expect(fixture.json('codex')['credentialReauthRequired'], isFalse);
      expect(fixture.json('codex')['credentialRemediation'], isNull);
      expect(fixture.deliveredText.single, contains('Mediation Contract Broken'));
      expect(fixture.deliveredText.single.toLowerCase(), isNot(contains('login')));
    });

    test('a reported transient refresh failure is its own state, not a re-auth demand', () async {
      fixture.monitor.report(
        providerId: 'codex',
        state: CredentialHealthState.refreshFailure,
        detail: 'Refresh attempt failed: upstream returned 503.',
      );
      await _settle();

      expect(fixture.json('codex')['credentialHealth'], 'refresh-failure');
      expect(fixture.json('codex')['credentialReauthRequired'], isFalse);
      expect(fixture.json('codex')['credentialRemediation'], isNull);
      expect(fixture.deliveredText.single, contains('Credential Refresh Failed'));
    });

    test('a report preserves the expiry the last probe observed', () async {
      final issuedAt = fixture.now.subtract(const Duration(days: 340));
      fixture.resolutions = {'claude': _claudeSubscription(issuedAt: issuedAt)};
      fixture.monitor.probe();

      fixture.monitor.report(
        providerId: 'claude',
        state: CredentialHealthState.reauthRequired,
        detail: 'Upstream rejected the injected setup-token.',
      );

      expect(fixture.json('claude')['credentialMode'], 'subscription');
      expect(fixture.json('claude')['credentialExpiresAt'], issuedAt.add(const Duration(days: 365)).toIso8601String());
      expect(fixture.json('claude')['credentialExpiryDerived'], isTrue);
    });
  });
}
