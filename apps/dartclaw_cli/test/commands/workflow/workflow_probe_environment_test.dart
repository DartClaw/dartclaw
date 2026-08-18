import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_cli/src/commands/workflow/workflow_provider_environment.dart';
import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:dartclaw_core/dartclaw_core.dart' show SubscriptionCredentialStore;
import 'package:dartclaw_server/dartclaw_server.dart' show CodexRefreshAuthority;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// What a workflow provider *probe* — skill introspection and the CLI auth
/// preflight — hands the vendor CLI.
///
/// A probe runs the vendor binary itself: there is no harness and no one-shot
/// provider driver behind it to point `CODEX_HOME` at the dedicated store. So
/// unlike an execution-lane environment, a probe environment that omits the
/// store is a probe that authenticates on whatever ambient login it finds — or,
/// on a deployment whose only credential is a stored ChatGPT subscription, one
/// that fails the turn and reports it as a skill-introspection error.
void main() {
  late Directory tempDir;
  late SubscriptionCredentialStore store;
  late String credentialsDir;
  late DateTime clock;
  late int vendorRefreshes;

  String jwt(DateTime exp) {
    String segment(Map<String, Object?> value) => base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
    return '${segment({'alg': 'RS256', 'typ': 'JWT'})}'
        '.${segment({'exp': exp.millisecondsSinceEpoch ~/ 1000, 'sub': 'chatgpt-account'})}'
        '.cHJvYmUtZW52aXJvbm1lbnQ';
  }

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_probe_environment_');
    clock = DateTime.utc(2026, 8, 16, 12);
    vendorRefreshes = 0;
    credentialsDir = p.join(tempDir.path, 'credentials');
    store = SubscriptionCredentialStore.open(
      credentialsDir: credentialsDir,
      environment: {'HOME': (Directory(p.join(tempDir.path, 'operator-home'))..createSync(recursive: true)).path},
    );
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  /// Writes `auth.json` the way the vendor CLI does, far outside the freshness
  /// gate's near-expiry window so the stored token is presented as-is.
  void storeCodexSubscription() {
    File(store.codexAuthPath).writeAsStringSync(
      jsonEncode({
        'tokens': {
          'access_token': jwt(clock.add(const Duration(hours: 12))),
          'refresh_token': 'rt-must-never-be-read',
          'account_id': 'acct-probe',
        },
        'last_refresh': clock.toIso8601String(),
      }),
    );
  }

  CodexRefreshAuthority authority() =>
      CodexRefreshAuthority(store: store, vendorRefresh: (_) async => vendorRefreshes++, now: () => clock);

  CredentialRegistry registry({
    Map<String, String> env = const {},
    ProvidersConfig providers = const ProvidersConfig.defaults(),
  }) => CredentialRegistry(
    credentials: const CredentialsConfig(),
    env: env,
    providers: providers,
    subscriptions: store.readAll(),
  );

  final forcedCodexSubscription = ProvidersConfig(
    entries: {'codex': ProviderEntry(executable: 'codex', auth: ProviderAuth.subscription)},
  );

  Future<Map<String, String>> probeEnvironment({
    String providerId = 'codex',
    String providerFamily = ProviderIdentity.codex,
    required CredentialRegistry credentials,
  }) => buildWorkflowProbeEnvironment(
    providerId: providerId,
    providerFamily: providerFamily,
    registry: credentials,
    baseEnvironment: const {'PATH': '/usr/bin', 'USER': 'tobias'},
    codexRefresh: authority(),
    credentialsDir: credentialsDir,
  );

  test('a stored Codex subscription points the probe at the dedicated store', () async {
    storeCodexSubscription();

    final environment = await probeEnvironment(credentials: registry(providers: forcedCodexSubscription));

    expect(
      environment['CODEX_HOME'],
      store.codexHome,
      reason: 'the probe would have run the vendor CLI against its own ambient login',
    );
    // The subscription is presented by the home alone: also overlaying the key
    // would authenticate the probe on the credential the resolution ruled out.
    expect(environment.containsKey('OPENAI_API_KEY'), isFalse);
    expect(vendorRefreshes, 0, reason: 'a token far from expiry must not be rotated to run a probe');
  });

  test('a stored subscription reaches the probe with no forced auth selection', () async {
    // The headline deployment: `dartclaw auth codex`, no API key, no
    // `providers.codex.auth` written by hand. The stored token still decides.
    storeCodexSubscription();

    final environment = await probeEnvironment(credentials: registry());

    expect(environment['CODEX_HOME'], store.codexHome);
  });

  test('an API-key Codex deployment overlays no dedicated home', () async {
    final environment = await probeEnvironment(credentials: registry(env: const {'OPENAI_API_KEY': 'sk-openai-test'}));

    expect(environment.containsKey('CODEX_HOME'), isFalse);
    expect(environment['OPENAI_API_KEY'], 'sk-openai-test');
  });

  test('a forced Codex subscription with nothing stored refuses and names the store', () async {
    // Never a probe on the ruled-out credential, and never one on the
    // operator's own login: the refusal has to carry the searched directory or
    // the operator re-runs an auth command that already succeeded.
    await expectLater(
      probeEnvironment(
        credentials: registry(env: const {'OPENAI_API_KEY': 'sk-openai-test'}, providers: forcedCodexSubscription),
      ),
      throwsA(
        isA<StateError>().having(
          (error) => '$error',
          'message',
          allOf(contains(credentialsDir), contains('dartclaw auth')),
        ),
      ),
    );
  });

  test('a Claude probe is untouched by the Codex subscription lane', () async {
    storeCodexSubscription();

    final environment = await probeEnvironment(
      providerId: 'claude',
      providerFamily: ProviderIdentity.claude,
      credentials: registry(env: const {'ANTHROPIC_API_KEY': 'sk-ant-test'}),
    );

    expect(environment.containsKey('CODEX_HOME'), isFalse);
    expect(environment['ANTHROPIC_API_KEY'], 'sk-ant-test');
    expect(environment['USER'], 'tobias', reason: 'the keychain-OAuth invariant must survive the probe overlay');
  });
}
