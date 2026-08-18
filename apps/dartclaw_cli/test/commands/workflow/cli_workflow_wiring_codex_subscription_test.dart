import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:dartclaw_core/dartclaw_core.dart' hide GoogleJwtVerifier, TurnManager, TurnRunner;
import 'package:dartclaw_testing/dartclaw_testing.dart' hide GoogleJwtVerifier, TurnManager, TurnRunner;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'cli_workflow_wiring_test_support.dart';

/// Which `CODEX_HOME` a standalone `dartclaw workflow` run hands the vendor CLI.
///
/// An operator who stores a credential with `dartclaw auth codex` and then runs
/// a workflow from the CLI must reach that credential — the same dedicated store
/// the `serve` lanes point their spawns at, never the operator's own `~/.codex`.
///
/// The spawn environment is asserted at the process seam, where the composed
/// value is final. `extraEnvironment` stands in for an operator-exported
/// `CODEX_HOME`: it is merged *after* the host-passthrough layer that carries a
/// real export (`SafeProcess.sanitize` does not strip `CODEX_HOME`), so a
/// dedicated home that wins here wins over the export too.
void main() {
  late Directory tempDir;
  late CliWorkflowWiringFixture fixture;
  late Map<String, String> environment;
  late SubscriptionCredentialStore store;
  late String operatorCodexHome;

  String jwt(DateTime exp) {
    String segment(Map<String, Object?> value) => base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
    return '${segment({'alg': 'RS256', 'typ': 'JWT'})}'
        '.${segment({'exp': exp.millisecondsSinceEpoch ~/ 1000, 'sub': 'chatgpt-account'})}'
        '.c3Vic2NyaXB0aW9uLXdvcmtmbG93';
  }

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_cli_workflow_codex_subscription_');
    fixture = CliWorkflowWiringFixture(tempDir);
    environment = {'HOME': (Directory(p.join(tempDir.path, 'operator-home'))..createSync(recursive: true)).path};
    operatorCodexHome = p.join(environment['HOME']!, '.codex');
    store = SubscriptionCredentialStore.open(
      credentialsDir: p.join(tempDir.path, 'credentials'),
      environment: environment,
    );
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  /// Writes `auth.json` the way the vendor CLI does. The expiry is far outside
  /// the freshness gate's near-expiry window, so the gate presents the stored
  /// token without driving a vendor refresh.
  void storeCodexSubscription() {
    File(store.codexAuthPath).writeAsStringSync(
      jsonEncode({
        'tokens': {
          'access_token': jwt(DateTime.now().toUtc().add(const Duration(hours: 12))),
          'refresh_token': 'rt-must-never-be-read',
          'account_id': 'acct-workflow',
        },
        'last_refresh': DateTime.now().toUtc().toIso8601String(),
      }),
    );
  }

  /// Runs one standalone workflow turn for [provider] and returns the
  /// environment the provider CLI was spawned with.
  Future<Map<String, String>> spawnEnvironmentFor(
    DartclawConfig config, {
    required String provider,
    required List<String> stdoutLines,
  }) async {
    Map<String, String>? captured;
    final process = FakeProcess();
    final wired = fixture.wiring(
      config,
      environment: environment,
      workflowCliProcessStarter: (executable, arguments, {workingDirectory, environment}) async {
        captured = Map<String, String>.from(environment ?? const {});
        Timer.run(() {
          for (final line in stdoutLines) {
            process.emitStdout(line);
          }
          process.exit(0);
        });
        return process;
      },
    );
    await wired.wire();

    await wired.workflowCliRunner.executeTurn(
      provider: provider,
      prompt: 'Say OK',
      workingDirectory: tempDir.path,
      policy: const ExecutionPolicy.host(),
      // Stands in for an operator-exported CODEX_HOME, from a layer that is
      // merged even later than the host passthrough a real export arrives on.
      extraEnvironment: {'CODEX_HOME': operatorCodexHome},
    );

    return captured ?? (throw StateError('no provider process was started'));
  }

  DartclawConfig codexConfig({ProviderAuth? auth, CredentialsConfig credentials = const CredentialsConfig()}) {
    return fixture.config(
      agent: const AgentConfig(provider: 'codex'),
      // The Dart VM stands in for the vendor binary: a bare `codex` resolves on
      // a developer machine and on no CI runner, and every spawn is intercepted
      // by the injected process starter anyway.
      providers: ProvidersConfig(
        entries: {'codex': ProviderEntry(executable: Platform.resolvedExecutable, poolSize: 1, auth: auth)},
      ),
      credentials: credentials,
    );
  }

  test('a stored Codex subscription points the standalone spawn at the dedicated store', () async {
    storeCodexSubscription();

    final spawnEnvironment = await spawnEnvironmentFor(
      codexConfig(auth: ProviderAuth.subscription),
      provider: 'codex',
      stdoutLines: const [],
    );

    expect(
      spawnEnvironment['CODEX_HOME'],
      store.codexHome,
      reason: 'the standalone workflow lane spawned Codex against a home other than the dedicated store',
    );
    expect(spawnEnvironment['CODEX_HOME'], isNot(operatorCodexHome));
  });

  test('an API-key Codex deployment spawns with no dedicated home overlay', () async {
    final spawnEnvironment = await spawnEnvironmentFor(
      codexConfig(
        auth: ProviderAuth.apiKey,
        credentials: const CredentialsConfig(entries: {'openai': CredentialEntry(apiKey: 'openai-key')}),
      ),
      provider: 'codex',
      stdoutLines: const [],
    );

    // Nothing overlays CODEX_HOME, so the value the operator supplied survives —
    // the behavior an API-key deployment had before the dedicated store existed.
    expect(spawnEnvironment['CODEX_HOME'], operatorCodexHome);
    expect(spawnEnvironment['OPENAI_API_KEY'], 'openai-key');
  });

  test('a refused standalone spawn names the store it searched', () async {
    // Nothing stored against a forced subscription. `dartclaw auth codex` writes
    // to the store `data_dir` selects, so a refusal that only says
    // "re-authenticate" lets the operator renew into a directory this run never
    // reads — and re-run a command that already succeeded.
    var started = false;
    final config = codexConfig(auth: ProviderAuth.subscription);
    final wired = fixture.wiring(
      config,
      environment: environment,
      workflowCliProcessStarter: (executable, arguments, {workingDirectory, environment}) async {
        started = true;
        return FakeProcess();
      },
    );
    await wired.wire();

    await expectLater(
      wired.workflowCliRunner.executeTurn(
        provider: 'codex',
        prompt: 'Say OK',
        workingDirectory: tempDir.path,
        policy: const ExecutionPolicy.host(),
      ),
      throwsA(
        isA<StateError>().having(
          (error) => '$error',
          'message',
          allOf(contains(config.credentialsDir), contains('dartclaw auth')),
        ),
      ),
    );
    expect(started, isFalse, reason: 'the vendor CLI was spawned on a credential this lane cannot present');
  });

  test('the skill-introspection probe reaches the dedicated store too', () async {
    // The probe runs the vendor CLI outside the runner, so nothing downstream
    // hands it the dedicated home. Every shipped workflow references a
    // `dartclaw-*` skill, so a probe that spawns uncredentialed fails the run
    // at skill introspection — after the auth preflight declared the provider
    // authenticated, and under an error naming the wrong subsystem.
    storeCodexSubscription();
    final wired = fixture.wiring(codexConfig(auth: ProviderAuth.subscription), environment: environment);
    await wired.wireBaseServices();

    final probeEnvironment = await wired.providerProbeEnvironment('codex');

    expect(probeEnvironment['CODEX_HOME'], store.codexHome);
  });

  test('a Claude workflow spawn is untouched by the Codex subscription lane', () async {
    // A Claude-family spawn must not acquire a CODEX_HOME, and must not be
    // gated on a Codex credential the deployment may not have.
    storeCodexSubscription();

    final spawnEnvironment = await spawnEnvironmentFor(
      fixture.config(
        credentials: const CredentialsConfig(entries: {'anthropic': CredentialEntry(apiKey: 'anthropic-key')}),
      ),
      provider: 'claude',
      stdoutLines: [
        jsonEncode({'type': 'system', 'subtype': 'init', 'session_id': 'codex-subscription-test'}),
        jsonEncode({'type': 'result', 'session_id': 'codex-subscription-test', 'result': 'ok'}),
      ],
    );

    expect(spawnEnvironment['CODEX_HOME'], operatorCodexHome);
    expect(spawnEnvironment['ANTHROPIC_API_KEY'], 'anthropic-key');
  });
}
