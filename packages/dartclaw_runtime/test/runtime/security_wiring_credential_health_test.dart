import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_runtime/src/runtime/security_wiring.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart';
import 'package:logging/logging.dart';
import 'package:test/test.dart';

Never _unexpectedExit(int code) => throw StateError('Unexpected exit($code)');

/// Stored credential material that must never reach an operator-facing string.
const _codexToken = 'chatgpt-access-token-SENTINEL';
const _claudeToken = 'sk-ant-oat01-SENTINEL';

final _mediatedProviders = ProvidersConfig(
  entries: {
    'claude': ProviderEntry(executable: 'claude', auth: ProviderAuth.subscription),
    'codex': ProviderEntry(executable: 'codex', auth: ProviderAuth.subscription),
  },
);

Map<String, CredentialEntry> _storedCredentials() => {
  'claude': CredentialEntry.subscription(token: _claudeToken),
  'codex': CredentialEntry.subscription(
    token: _codexToken,
    expiry: CredentialExpiry(
      issuedAt: DateTime.utc(2026, 8, 14),
      expiresAt: DateTime.utc(2026, 8, 14, 0, 30),
      derived: false,
    ),
  ),
};

void main() {
  late Directory tempDir;
  late EventBus eventBus;
  late List<CredentialHealthChangedEvent> events;
  late List<LogRecord> records;
  late ProviderStatusService providerStatus;
  late SecurityWiring wiring;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('security_wiring_credential_health_');
    eventBus = EventBus();
    events = <CredentialHealthChangedEvent>[];
    records = <LogRecord>[];
    final eventSubscription = eventBus.on<CredentialHealthChangedEvent>().listen(events.add);
    final logSubscription = Logger.root.onRecord.listen(records.add);
    addTearDown(eventSubscription.cancel);
    addTearDown(logSubscription.cancel);

    providerStatus = ProviderStatusService(
      providers: _mediatedProviders,
      registry: CredentialRegistry(credentials: const CredentialsConfig()),
      defaultProvider: 'claude',
    );
    wiring = SecurityWiring(
      config: DartclawConfig(
        server: ServerConfig(dataDir: tempDir.path),
        providers: _mediatedProviders,
      ),
      dataDir: tempDir.path,
      eventBus: eventBus,
      exitFn: _unexpectedExit,
      subscriptionCredentials: _storedCredentials,
    );
  });

  tearDown(() async {
    await eventBus.dispose();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  /// The real single writer, over the same [ProviderStatusService] the API
  /// reads — a fake here would prove only that a callback was invoked, not that
  /// the refusal reaches the provider cards and the alert path.
  CredentialHealthMonitor bindMonitor() {
    final monitor = CredentialHealthMonitor(
      eventBus: eventBus,
      providerStatus: providerStatus,
      resolveCredentials: () => {
        for (final entry in _storedCredentials().entries)
          entry.key: (family: entry.key, resolution: CredentialResolution.subscription(entry.value)),
      },
    );
    wiring.credentialHealth = monitor;
    return monitor;
  }

  void Function(CodexRejection) codexRejectionSink() =>
      (wiring.buildProviderAdapters()['codex']! as OpenAiResponsesAdapter).onRejection!;

  Map<String, Object?> statusFor(String providerId) =>
      providerStatus.all.firstWhere((status) => status.id == providerId).toJson();

  group('admission refusal', () {
    test('reports reauth-required through the monitor, not a bare log line', () async {
      bindMonitor();

      wiring.credentialRefusalSink(
        'claude',
        'no host-held credential can be presented (auth: subscription)',
        remediation: 'claude setup-token',
      );
      await pumpEventQueue();

      expect(events, hasLength(1));
      expect(events.single.providerId, 'claude');
      expect(events.single.state, CredentialHealthState.reauthRequired);
      expect(events.single.remediation, 'claude setup-token');
      // The provider card must move with the alert; a refusal between probe
      // runs that only alerted would leave /settings claiming healthy.
      expect(statusFor('claude')['credentialHealth'], 'reauth-required');
      expect(statusFor('claude')['credentialRemediation'], 'claude setup-token');
    });

    test('re-refusing the same provider does not page a second time', () async {
      bindMonitor();

      for (var attempt = 0; attempt < 3; attempt++) {
        wiring.credentialRefusalSink('claude', 'the host-held credential became unusable during a turn');
      }
      await pumpEventQueue();

      expect(events, hasLength(1), reason: 'the monitor is edge-triggered; every detecting path shares one alert');
    });

    test('degrades to a severe log line when no monitor is bound', () async {
      wiring.credentialRefusalSink(
        'claude',
        'no host-held credential can be presented',
        remediation: 'claude setup-token',
      );
      await pumpEventQueue();

      expect(events, isEmpty);
      final severe = records.where((record) => record.level >= Level.SEVERE).map((record) => record.message);
      expect(
        severe,
        contains(
          allOf(
            contains('claude'),
            contains('no host-held credential can be presented'),
            contains('claude setup-token'),
          ),
        ),
      );
    });
  });

  group('codex refresh outcomes', () {
    test('a transient refresh failure reports refresh-failure, and a rotation away pages nobody', () async {
      bindMonitor();

      wiring.codexRefreshOutcomeSink(
        CodexCredentialRotatedAway(
          CodexSubscriptionCredential(accessToken: _codexToken, expiresAt: DateTime.utc(2026, 8, 14, 1)),
        ),
      );
      await pumpEventQueue();
      expect(events, isEmpty, reason: 'losing a one-time-use rotation race is the designed outcome, not a fault');

      wiring.codexRefreshOutcomeSink(const CodexRefreshFailed('the token endpoint could not be reached'));
      await pumpEventQueue();

      expect(events, hasLength(1));
      expect(events.single.state, CredentialHealthState.refreshFailure);
      // Re-authenticating fixes nothing transient; the seam owns that wording.
      expect(events.single.remediation, isNull);
      expect(statusFor('codex')['credentialHealth'], 'refresh-failure');
    });

    test('a spent refresh token reports reauth-required with its remediation', () async {
      bindMonitor();

      wiring.codexRefreshOutcomeSink(
        const CodexReauthRequired(
          detail: 'the stored refresh token is spent',
          remediation: 'run `codex login` to store a new Codex sign-in',
        ),
      );
      await pumpEventQueue();

      expect(events.single.state, CredentialHealthState.reauthRequired);
      expect(events.single.remediation, 'run `codex login` to store a new Codex sign-in');
    });

    test('degrades to a warning log line when no monitor is bound', () async {
      wiring.codexRefreshOutcomeSink(const CodexRefreshFailed('the token endpoint could not be reached'));
      await pumpEventQueue();

      expect(events, isEmpty);
      expect(
        records.where((record) => record.level >= Level.WARNING).map((record) => record.message),
        contains(contains('the token endpoint could not be reached')),
      );
    });
  });

  group('codex backend classifications', () {
    test('a usage limit never reaches credential health, while an expiry in the same lane does', () async {
      bindMonitor();
      final report = codexRejectionSink();

      report(
        const CodexRejection(
          kind: CodexRejectionKind.usageLimit,
          detail: 'the ChatGPT plan behind this credential has reached its usage limit',
        ),
      );
      await pumpEventQueue();
      expect(events, isEmpty, reason: 'a plan limit resets on its own; paging for a re-login would be a false alarm');
      expect(statusFor('codex')['credentialHealth'], isNull);

      report(
        const CodexRejection(
          kind: CodexRejectionKind.authExpired,
          detail: 'the ChatGPT backend refused the stored subscription credential',
        ),
      );
      await pumpEventQueue();

      expect(events.single.state, CredentialHealthState.reauthRequired);
    });

    test('a contract break reports as a broken contract, never as an expiry', () async {
      bindMonitor();

      codexRejectionSink()(
        const CodexRejection(
          kind: CodexRejectionKind.contractBreak,
          detail: 'the ChatGPT backend no longer accepts the bearer mediation this build pins against',
        ),
      );
      await pumpEventQueue();

      expect(events.single.state, CredentialHealthState.contractBreak);
      // Re-authenticating cannot fix a backend auth-scheme change.
      expect(events.single.remediation, isNull);
      expect(statusFor('codex')['credentialHealth'], 'contract-break');
    });

    test('a rejected model is a configuration choice, not a credential condition', () async {
      bindMonitor();

      codexRejectionSink()(
        const CodexRejection(
          kind: CodexRejectionKind.modelUnsupported,
          detail: 'the ChatGPT backend does not support the configured model for this account',
          model: 'gpt-5-codex',
        ),
      );
      await pumpEventQueue();

      expect(events, isEmpty);
      expect(statusFor('codex')['credentialHealth'], isNull);
      expect(
        records.where((record) => record.level >= Level.WARNING).map((record) => record.message),
        contains(contains('gpt-5-codex')),
      );
    });
  });

  test('nothing this seam emits carries credential material', () async {
    final monitor = bindMonitor();
    // Probe first: the report seam inherits mode and expiry from the last
    // probe, so this is the state in which a leak would actually surface.
    monitor.probe();

    wiring.credentialRefusalSink('codex', 'the host-held credential became unusable during a turn');
    wiring.codexRefreshOutcomeSink(const CodexRefreshFailed('the token endpoint could not be reached'));
    codexRejectionSink()(
      const CodexRejection(
        kind: CodexRejectionKind.authExpired,
        detail: 'the ChatGPT backend refused the stored subscription credential',
      ),
    );
    await pumpEventQueue();

    final emitted = [
      jsonEncode([for (final status in providerStatus.all) status.toJson()]),
      for (final event in events) '${event.providerId} ${event.detail} ${event.remediation} ${event.state.jsonName}',
      for (final record in records) '${record.message} ${record.error}',
    ].join('\n');

    expect(emitted, isNot(contains(_codexToken)));
    expect(emitted, isNot(contains(_claudeToken)));
    expect(emitted, isNot(contains('SENTINEL')));
  });
}
