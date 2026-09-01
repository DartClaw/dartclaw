import 'dart:io';

import 'package:dartclaw_runtime/src/runtime/security_wiring.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

Never _unexpectedExit(int code) => throw StateError('Unexpected exit($code)');

const _storedSetupToken = 'sk-ant-oat01-WIRED-SENTINEL';

/// Pins resolution to the store so the assertions cannot be answered by an
/// `ANTHROPIC_API_KEY` the developer happens to have exported.
final _forcedSubscription = ProvidersConfig(
  entries: {'claude': ProviderEntry(executable: 'claude', auth: ProviderAuth.subscription)},
);

/// The same pin for Codex, so an exported `OPENAI_API_KEY` cannot answer.
final _forcedCodexSubscription = ProvidersConfig(
  entries: {'codex': ProviderEntry(executable: 'codex', auth: ProviderAuth.subscription)},
);

void main() {
  late Directory tempDir;
  late EventBus eventBus;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('security_wiring_adapters_');
    eventBus = EventBus();
  });

  tearDown(() async {
    await eventBus.dispose();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  SecurityWiring buildWiring({
    CredentialsConfig credentials = const CredentialsConfig(),
    ProvidersConfig providers = const ProvidersConfig.defaults(),
    Map<String, CredentialEntry> Function()? subscriptions,
  }) => SecurityWiring(
    config: DartclawConfig(
      server: ServerConfig(dataDir: tempDir.path),
      credentials: credentials,
      providers: providers,
    ),
    dataDir: tempDir.path,
    eventBus: eventBus,
    exitFn: _unexpectedExit,
    subscriptionCredentials: subscriptions,
  );

  Map<String, CredentialEntry> storedClaudeToken([String token = _storedSetupToken]) => {
    'claude': CredentialEntry.subscription(token: token),
  };

  test('a stored setup-token alone makes the claude adapter mediatable', () {
    // Pinned to `subscription` so the token is the only credential that can
    // answer: under `auto`, an `ANTHROPIC_API_KEY` the developer happens to
    // have exported would make this pass with the feature removed.
    final adapters = buildWiring(
      providers: _forcedSubscription,
      subscriptions: storedClaudeToken,
    ).buildProviderAdapters();

    // 0.24 refused this configuration at authority registration; a
    // subscription-mediated deployment must now be admitted without an API key.
    expect(adapters['claude']!.unavailableReason, isNull);
  });

  test('an unsatisfiable forced selection refuses the claude adapter, naming only its own remedy', () {
    final adapters = buildWiring(providers: _forcedSubscription).buildProviderAdapters();

    expect(
      adapters['claude']!.unavailableReason,
      allOf(
        contains('no host-held credential'),
        contains('auth: subscription'),
        contains('claude setup-token'),
        // The operator ruled the API key out, so naming it would read as a bug
        // report against a credential that is working exactly as configured.
        isNot(contains('ANTHROPIC_API_KEY')),
      ),
    );
  });

  test('a forced subscription selection is not satisfied by a configured API key', () {
    final adapters = buildWiring(
      credentials: const CredentialsConfig(entries: {'anthropic': CredentialEntry(apiKey: 'sk-ant-configured')}),
      providers: _forcedSubscription,
    ).buildProviderAdapters();

    expect(adapters['claude']!.unavailableReason, isNotNull);
  });

  test('a stored codex subscription credential alone makes the codex adapter mediatable', () {
    // 0.24 refused this configuration without OPENAI_API_KEY; a
    // subscription-mediated Codex deployment must now be admitted on the store.
    final adapters = buildWiring(
      providers: _forcedCodexSubscription,
      subscriptions: () => {'codex': CredentialEntry.subscription(token: 'chatgpt-access-token')},
    ).buildProviderAdapters();

    expect(adapters['codex']!.unavailableReason, isNull);
  });

  test('a stored-but-expired codex credential still passes admission, leaving freshness to the gate', () {
    final adapters = buildWiring(
      providers: _forcedCodexSubscription,
      subscriptions: () => {
        'codex': CredentialEntry.subscription(
          token: 'chatgpt-access-token',
          expiry: CredentialExpiry(issuedAt: DateTime.utc(2020), expiresAt: DateTime.utc(2020, 1, 2), derived: false),
        ),
      },
    ).buildProviderAdapters();

    // Admission answers configuredness. Refusing an expired-but-refreshable
    // store here would reject the container before the refresh could run.
    expect(adapters['codex']!.unavailableReason, isNull);
  });

  test('an unsatisfiable forced codex selection refuses the adapter, naming only its own remedy', () {
    final adapters = buildWiring(providers: _forcedCodexSubscription).buildProviderAdapters();

    expect(
      adapters['codex']!.unavailableReason,
      allOf(
        contains('no host-held credential'),
        contains('auth: subscription'),
        contains('codex login'),
        isNot(contains('OPENAI_API_KEY')),
      ),
    );
  });

  test('the codex adapter is unchanged by a stored claude token', () {
    final withToken = buildWiring(subscriptions: storedClaudeToken).buildProviderAdapters();
    final without = buildWiring().buildProviderAdapters();

    expect(withToken['codex']!.unavailableReason, without['codex']!.unavailableReason);
  });

  group('provider aliases', () {
    /// A claude-family alias that opts out of the subscription credential, the
    /// configuration the host spawn path already honors.
    final aliasOptingOut = ProvidersConfig(
      entries: {
        'claude': ProviderEntry(executable: 'claude', auth: ProviderAuth.subscription),
        'my_claude': ProviderEntry(executable: 'claude', auth: ProviderAuth.apiKey),
      },
    );

    test('an alias gets its own adapter, so a container execution can name it at all', () {
      final adapters = buildWiring(providers: aliasOptingOut, subscriptions: storedClaudeToken).buildProviderAdapters();

      // A family-keyed map has no entry here, and `HostGateway.register` refuses
      // an unknown provider id outright.
      expect(adapters.keys, containsAll(<String>['claude', 'my_claude']));
    });

    test("an alias's own auth: api_key is honored, not the family's subscription selection", () {
      final adapters = buildWiring(providers: aliasOptingOut, subscriptions: storedClaudeToken).buildProviderAdapters();

      // The same stored token satisfies the family entry; the alias ruled it
      // out, so mediating it there would present a credential the operator
      // explicitly opted out of on the boundary this milestone made default.
      expect(adapters['claude']!.unavailableReason, isNull);
      expect(
        adapters['my_claude']!.unavailableReason,
        allOf(contains('auth: api_key'), contains('ANTHROPIC_API_KEY'), isNot(contains('claude setup-token'))),
      );
    });

    test('an alias inherits its family selection when it sets none', () {
      final adapters = buildWiring(
        providers: ProvidersConfig(
          entries: {
            'claude': ProviderEntry(executable: 'claude', auth: ProviderAuth.subscription),
            'my_claude': ProviderEntry(executable: 'claude'),
          },
        ),
        subscriptions: storedClaudeToken,
      ).buildProviderAdapters();

      expect(adapters['my_claude']!.unavailableReason, isNull);
    });

    test('a codex-family alias resolves the codex store and names the codex remedy', () {
      final adapters = buildWiring(
        providers: ProvidersConfig(
          entries: {'my_codex': ProviderEntry(executable: 'codex', auth: ProviderAuth.subscription)},
        ),
      ).buildProviderAdapters();

      // The family comes from the executable, not the id: plain normalization
      // would read `my_codex` as its own family and name no vendor command.
      expect(adapters['my_codex']!.unavailableReason, contains('codex login'));
    });

    test('a provider family this build speaks no protocol for gets no adapter', () {
      final adapters = buildWiring(
        providers: ProvidersConfig(entries: {'gemini': ProviderEntry(executable: 'gemini')}),
      ).buildProviderAdapters();

      // Registration must keep refusing it rather than mediating a container on
      // a protocol nothing here implements.
      expect(adapters.containsKey('gemini'), isFalse);
    });
  });

  test('a refusal names the store the adapter actually searched', () {
    // `data_dir` selects the store, so a refusal that names no path cannot
    // distinguish "never stored" from "stored under a different --data-dir" and
    // sends the operator back to a command they already ran successfully.
    final adapters = buildWiring(providers: _forcedSubscription).buildProviderAdapters();

    expect(adapters['claude']!.unavailableReason, contains(p.join(tempDir.path, 'credentials')));
    expect(adapters['claude']!.credentialRemediation, contains(p.join(tempDir.path, 'credentials')));
  });

  test('the adapter re-reads the store, so a re-issued token needs no restart', () {
    var stored = storedClaudeToken();
    final adapters = buildWiring(providers: _forcedSubscription, subscriptions: () => stored).buildProviderAdapters();

    expect(adapters['claude']!.unavailableReason, isNull);
    stored = const {};
    expect(
      adapters['claude']!.unavailableReason,
      isNotNull,
      reason: 'the credential source is consulted per use, not snapshotted at wiring time',
    );
  });
}
