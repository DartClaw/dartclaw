import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_cli/src/commands/codex_subscription_home.dart';
import 'package:dartclaw_config/dartclaw_config.dart'
    show CredentialRegistry, CredentialsConfig, ProviderAuth, ProviderEntry, ProvidersConfig;
import 'package:dartclaw_core/dartclaw_core.dart' show CredentialHealthState, SubscriptionCredentialStore;
import 'package:dartclaw_server/dartclaw_server.dart' show CodexRefreshAuthority;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// A JWT expiring far enough out that the freshness gate presents it untouched.
String _jwt(DateTime exp) {
  String segment(Map<String, Object?> value) => base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  return '${segment({'alg': 'RS256'})}.${segment({'exp': exp.millisecondsSinceEpoch ~/ 1000})}.c2ln';
}

final _forcedSubscription = ProvidersConfig(
  entries: {'codex': ProviderEntry(executable: 'codex', auth: ProviderAuth.subscription)},
);

void main() {
  late Directory root;
  late String credentialsDir;
  late SubscriptionCredentialStore store;

  setUp(() {
    root = Directory.systemTemp.createTempSync('codex_subscription_home_');
    final home = p.join(root.path, 'home');
    // The operator's own login lives under this HOME; no path here may reach it.
    Directory(p.join(home, '.codex')).createSync(recursive: true);
    File(p.join(home, '.codex', 'auth.json')).writeAsStringSync('{"token":"OPERATOR-LOGIN"}');
    credentialsDir = p.join(root.path, 'data', 'credentials');
    store = SubscriptionCredentialStore.open(credentialsDir: credentialsDir, environment: {'HOME': home});
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  CredentialRegistry registry({
    Map<String, String> env = const {},
    ProvidersConfig providers = const ProvidersConfig.defaults(),
  }) => CredentialRegistry(
    credentials: const CredentialsConfig(),
    env: env,
    providers: providers,
    subscriptions: store.readAll(),
  );

  CodexRefreshAuthority authority() =>
      CodexRefreshAuthority(store: store, vendorRefresh: (_) async => fail('no refresh is expected'));

  void storeCredential() {
    File(store.codexAuthPath).writeAsStringSync(
      jsonEncode({
        'tokens': {'access_token': _jwt(DateTime.now().toUtc().add(const Duration(hours: 1)))},
      }),
    );
  }

  test('a stored subscription answers the dedicated store path', () async {
    storeCredential();

    final home = await prepareCodexSubscriptionHome(
      registry: registry(providers: _forcedSubscription),
      authority: authority(),
    );

    expect(home, store.codexHome);
  });

  test('a forced subscription with nothing stored refuses instead of falling back to the operator login', () async {
    // The day-one state: `auth: subscription` set, `codex login` not yet run.
    // Answering null here would spawn against the operator's own `~/.codex`.
    await expectLater(
      prepareCodexSubscriptionHome(
        registry: registry(providers: _forcedSubscription),
        authority: authority(),
      ),
      throwsA(
        isA<StateError>().having(
          (error) => '$error',
          'message',
          allOf(contains('codex login'), contains('providers.codex.auth')),
        ),
      ),
    );
  });

  test('an unreadable stored credential refuses rather than falling back', () async {
    File(store.codexAuthPath).writeAsStringSync('{"tokens":{"access_token":"not-a-jwt"}}');

    await expectLater(
      prepareCodexSubscriptionHome(
        registry: registry(providers: _forcedSubscription),
        authority: authority(),
      ),
      throwsA(isA<StateError>()),
    );
  });

  test('an unrecognized auth setting refuses rather than falling back', () async {
    final unrecognized = ProvidersConfig(
      entries: {'codex': ProviderEntry(executable: 'codex', auth: ProviderAuth.unrecognized)},
    );

    await expectLater(
      prepareCodexSubscriptionHome(
        registry: registry(providers: unrecognized),
        authority: authority(),
      ),
      throwsA(isA<StateError>().having((error) => '$error', 'message', contains('unrecognized providers.codex.auth'))),
    );
  });

  test('a forced api_key with no key refuses instead of spawning against the operator login', () async {
    // The mirror of the forced-subscription case, and the one that reads worst:
    // `api_key` is the setting an operator picks to keep a turn *off* their
    // subscription, and answering null lands the spawn on exactly that login.
    final forcedApiKey = ProvidersConfig(
      entries: {'codex': ProviderEntry(executable: 'codex', auth: ProviderAuth.apiKey)},
    );

    await expectLater(
      prepareCodexSubscriptionHome(
        registry: registry(providers: forcedApiKey),
        authority: authority(),
      ),
      throwsA(
        isA<StateError>().having(
          (error) => '$error',
          'message',
          allOf(contains('auth: api_key'), contains('CODEX_API_KEY'), contains('providers.codex.auth')),
        ),
      ),
    );
  });

  test('a refusal announces credential health for the host boundary', () async {
    final reports = <({String providerId, CredentialHealthState state, String? remediation})>[];

    await expectLater(
      prepareCodexSubscriptionHome(
        registry: registry(providers: _forcedSubscription),
        authority: authority(),
        credentialsDir: credentialsDir,
        onCredentialHealth: ({required providerId, required state, required detail, remediation}) =>
            reports.add((providerId: providerId, state: state, remediation: remediation)),
      ),
      throwsA(isA<StateError>()),
    );

    expect(reports, hasLength(1));
    expect(reports.single.state, CredentialHealthState.reauthRequired);
    // The searched store travels with the fix: `data_dir` selects it, and an
    // operator told only to re-run `dartclaw auth codex` can renew into a
    // directory this instance never reads.
    expect(reports.single.remediation, contains(credentialsDir));
  });

  test('an api-key deployment answers null so the existing home behavior is kept', () async {
    final home = await prepareCodexSubscriptionHome(
      registry: registry(env: const {'OPENAI_API_KEY': 'sk-configured'}),
      authority: authority(),
    );

    expect(home, isNull);
  });

  test('nothing selected and nothing stored keeps the vendor login admissible', () async {
    // `auth: auto` with no credential at all is not a forced selection: DartClaw
    // presents nothing, so answering null leaves 0.24's behavior intact.
    final home = await prepareCodexSubscriptionHome(registry: registry(), authority: authority());

    expect(home, isNull);
  });
}
