import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:dartclaw_core/dartclaw_core.dart' hide GoogleJwtVerifier, TurnManager, TurnRunner;
import 'package:dartclaw_runtime/dartclaw_runtime.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_testing/dartclaw_testing.dart' show FakeAgentHarness;
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

/// The provider-auth gate the in-`serve` workflow one-shot lane installs, and
/// the credential-health signal its probe lane raises.
///
/// The in-engine preflight is skipped outright when no lane installs one, so a
/// `serve` that omits it runs workflow steps by spawning the step's provider CLI
/// with no credential gate and no remediation — while the standalone
/// `dartclaw workflow` lane refuses the same step. The two lanes must agree.
late String _staticDirPath;
late String _templatesDirPath;

Future<String> _resolvePackageDir(String packageRelativeAnchor) async {
  final uri = await Isolate.resolvePackageUri(Uri.parse('package:dartclaw_runtime/$packageRelativeAnchor'));
  if (uri == null || !uri.isScheme('file')) {
    throw StateError('Could not resolve dartclaw_runtime $packageRelativeAnchor via package URI');
  }
  return p.dirname(uri.toFilePath());
}

HarnessFactory _harnessFactory() {
  final factory = HarnessFactory();
  factory.register('claude', (_) => FakeAgentHarness());
  factory.register('codex', (_) => FakeAgentHarness());
  return factory;
}

Never _unexpectedExit(int code) => throw StateError('Unexpected exit($code)');

void main() {
  late Directory tempDir;
  late Directory dataDir;
  late LogService logService;

  setUpAll(() async {
    _templatesDirPath = await _resolvePackageDir('src/templates/layout.html');
    _staticDirPath = await _resolvePackageDir('src/static/app.css');
    initTemplates(_templatesDirPath);
  });

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('service_wiring_workflow_preflight_');
    dataDir = Directory(p.join(tempDir.path, 'data'))..createSync(recursive: true);
    logService = LogService.fromConfig(format: 'human', level: 'WARNING', redactor: LogRedactor());
    logService.install();
  });

  tearDown(() async {
    await logService.dispose();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  // `codex` is forced to `auth: subscription` with nothing stored, so its
  // refusal is decided by the resolved credential alone — no vendor CLI is
  // probed and the outcome does not depend on what is installed on the runner.
  // `claude` stays credentialed so it is the default provider startup admits.
  DartclawConfig configFor() => DartclawConfig(
    agent: const AgentConfig(provider: 'claude'),
    credentials: const CredentialsConfig(entries: {'anthropic': CredentialEntry(apiKey: 'anthropic-key')}),
    providers: ProvidersConfig(
      entries: {
        'claude': ProviderEntry(executable: Platform.resolvedExecutable, poolSize: 0),
        'codex': ProviderEntry(executable: Platform.resolvedExecutable, poolSize: 0, auth: ProviderAuth.subscription),
      },
    ),
    gateway: const GatewayConfig(authMode: 'none'),
    server: ServerConfig(
      dataDir: dataDir.path,
      staticDir: _staticDirPath,
      templatesDir: _templatesDirPath,
      claudeExecutable: Platform.resolvedExecutable,
    ),
  );

  /// The dedicated Codex store as `dartclaw auth codex` leaves it: a live
  /// access token whose `exp` the store reads exactly.
  void storeCodexSubscription(DartclawConfig config) {
    String segment(Map<String, Object?> value) => base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
    final expiresAt = DateTime.now().toUtc().add(const Duration(hours: 1));
    final accessToken =
        '${segment({'alg': 'RS256', 'typ': 'JWT'})}'
        '.${segment({'exp': expiresAt.millisecondsSinceEpoch ~/ 1000, 'sub': 'chatgpt-account'})}'
        '.c2VydmUtcHJlZmxpZ2h0';
    final store = SubscriptionCredentialStore.open(
      credentialsDir: config.credentialsDir,
      environment: {'HOME': p.join(tempDir.path, 'operator')},
    );
    File(store.codexAuthPath).writeAsStringSync(
      jsonEncode({
        'tokens': {'access_token': accessToken, 'refresh_token': 'refresh-token-0', 'account_id': 'acct-preflight'},
        'last_refresh': DateTime.now().toUtc().toIso8601String(),
      }),
    );
  }

  Future<DartclawRuntime> wire(DartclawConfig config) async {
    final runtime = await DartclawRuntime.build(
      config,
      dataDir: dataDir.path,
      port: 3000,
      harnessFactory: _harnessFactory(),
      searchDbFactory: (_) => sqlite3.openInMemory(),
      taskDbFactory: (_) => sqlite3.openInMemory(),
      stderrLine: (_) {},
      exitFn: _unexpectedExit,
      resolvedConfigPath: p.join(tempDir.path, 'dartclaw.yaml'),
      messageRedactor: MessageRedactor(),
      resolvedAssets: ResolvedAssets.fromSourceTree(
        templatesDir: config.server.templatesDir,
        staticDir: config.server.staticDir,
        source: AssetSource.sourceTreeDefault,
      ),
      runWorkflowSkillsBootstrap: false,
      environment: {'HOME': p.join(tempDir.path, 'operator')},
    );
    addTearDown(runtime.shutdownExtras);
    return runtime;
  }

  test('a workflow provider with no usable credential is refused, naming the store that was searched', () async {
    final config = configFor();

    final preflight = (await wire(config)).workflowService.providerAuthPreflight;

    expect(preflight, isNotNull, reason: 'without an installed preflight the in-engine backstop never runs');
    final outcome = await preflight!.evaluate(provider: 'codex');
    expect(outcome.authenticated, isFalse);
    expect(
      outcome.remediationMessage,
      allOf(
        contains('codex'),
        // The searched store, so an operator who ran `dartclaw auth codex`
        // against a different `data_dir` can see which one this server reads.
        contains(config.credentialsDir),
      ),
    );
  });

  test('a credentialed workflow provider still passes, so the gate is not refusing unconditionally', () async {
    final config = configFor();

    final preflight = (await wire(config)).workflowService.providerAuthPreflight;

    final outcome = await preflight!.evaluate(provider: 'claude');
    expect(outcome.authenticated, isTrue);
    expect(outcome.remediationMessage, isNull);
  });

  test('a credential stored after wiring authenticates, so the gate is never stricter than the executor', () async {
    final config = configFor();
    final preflight = (await wire(config)).workflowService.providerAuthPreflight!;

    // The refusal the operator meets first — and the state a wiring-time
    // snapshot would keep answering with for the rest of the process.
    expect(
      (await preflight.evaluate(provider: 'codex')).authenticated,
      isFalse,
      reason: 'the fixture must start refused, or the retry below proves nothing',
    );

    // The operator runs the remediation the refusal named, while `serve` keeps
    // running: `TaskWiring` rebuilds its registry per spawn and would run the
    // step from here on, so a gate still refusing sends them back to a command
    // they already ran successfully.
    storeCodexSubscription(config);

    final outcome = await preflight.evaluate(provider: 'codex');
    expect(outcome.authenticated, isTrue, reason: 'the preflight resolved a boot-time credential snapshot');
    expect(outcome.remediationMessage, isNull);
  });

  test('a probe-lane credential refusal reaches the credential-health monitor', () async {
    final config = configFor();
    storeCodexSubscription(config);
    final wired = await wire(config);

    final transitions = <CredentialHealthChangedEvent>[];
    final subscription = wired.eventBus.on<CredentialHealthChangedEvent>().listen(transitions.add);
    addTearDown(subscription.cancel);

    // The store the deployment wired against is gone by the time the probe
    // resolves it — a credential rotated away under a running `serve`. The
    // probe runs the vendor CLI on the host, so its refusal reaches no gateway,
    // and the hourly probe drives no refresh: without the sink this condition
    // is announced nowhere.
    File(p.join(config.credentialsDir, 'codex', 'auth.json')).deleteSync();

    await expectLater(wired.providerProbeEnvironment('codex'), throwsA(isA<StateError>()));
    await pumpEventQueue();

    expect(transitions, hasLength(1), reason: 'the probe lane announced no credential-health transition');
    expect(transitions.single.providerId, 'codex');
    expect(transitions.single.state, CredentialHealthState.reauthRequired);
    expect(transitions.single.remediation, contains(config.credentialsDir));
  });
}
