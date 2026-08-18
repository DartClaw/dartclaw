import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_cli/src/commands/wiring/harness_wiring.dart';
import 'package:dartclaw_cli/src/commands/wiring/security_wiring.dart';
import 'package:dartclaw_cli/src/commands/wiring/storage_wiring.dart';
import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:dartclaw_core/dartclaw_core.dart' hide HarnessConfig;
import 'package:dartclaw_server/dartclaw_server.dart' show CodexRefreshAuthority, CodexVendorRefresh;
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../helpers/harness_wiring_fixture.dart';

Never _unexpectedExit(int code) => throw StateError('Unexpected exit($code) during harness wiring test');

/// What the host boundary does when the dedicated Codex store cannot produce a
/// usable credential, and what it does when it still can.
///
/// The container arm refuses at gateway registration, which is a presence
/// check. This boundary is different: the credential *is* stored and reads back
/// fine, so nothing short of running the freshness gate can tell a live lineage
/// from a spent one. That is why the assertions here are about whether a
/// provider CLI was spawned rather than about whether a credential existed.
///
/// The harness under test is a real [CodexHarness] built from the wiring's own
/// factory config, so the gate's position relative to the spawn is the shipped
/// one. Only the process seams are injected — and they are injected on purpose:
/// a test that let the real `codex` binary be probed would pass on a developer
/// machine that has it on PATH and fail on CI, which has neither provider CLI.
void main() {
  late Directory tempDir;
  late DartclawConfig config;
  late EventBus eventBus;
  late SubscriptionCredentialStore store;
  late DateTime clock;
  late List<_RecordedSpawn> spawns;
  late List<String> probedExecutables;
  StorageWiring? storage;
  SecurityWiring? security;
  HarnessWiring? harnessWiring;

  String jwt(DateTime exp) {
    String segment(Map<String, Object?> value) => base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
    return '${segment({'alg': 'RS256', 'typ': 'JWT'})}'
        '.${segment({'exp': exp.millisecondsSinceEpoch ~/ 1000, 'sub': 'chatgpt-account'})}'
        '.c3Vic2NyaXB0aW9uLWdhdGU';
  }

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_codex_gate_');
    clock = DateTime.utc(2026, 8, 15, 12);
    spawns = <_RecordedSpawn>[];
    probedExecutables = <String>[];
    config = DartclawConfig(
      server: ServerConfig(dataDir: tempDir.path, claudeExecutable: Platform.resolvedExecutable),
      agent: const AgentConfig(provider: 'codex'),
      // The Dart VM stands in for the provider binary. `ProviderValidator`
      // probes `providers.<id>.executable` with a real `Process.run` that no
      // seam here can intercept, and a bare `codex` resolves on a developer
      // machine and on no CI runner — which would make the default provider's
      // binary "not found" and fail startup for a reason this suite is not
      // about. Every provider-CLI spawn is still recorded through the injected
      // process seams below.
      providers: ProvidersConfig(
        entries: {
          'codex': ProviderEntry(executable: Platform.resolvedExecutable, poolSize: 1, auth: ProviderAuth.subscription),
        },
      ),
      credentials: const CredentialsConfig.defaults(),
      gateway: const GatewayConfig(authMode: 'none'),
    );
    writeWorkspacePromptFiles(config.workspaceDir);
    eventBus = EventBus();
    store = SubscriptionCredentialStore.open(
      credentialsDir: config.credentialsDir,
      environment: {'HOME': (Directory(p.join(tempDir.path, 'operator-home'))..createSync(recursive: true)).path},
    );
  });

  tearDown(() async {
    await harnessWiring?.executions.dispose();
    await security?.dispose();
    await storage?.dispose();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  /// Writes `auth.json` the way the vendor CLI does.
  void writeStore({required Duration expiresIn, Duration lastRefreshAge = Duration.zero}) {
    File(store.codexAuthPath).writeAsStringSync(
      jsonEncode({
        'tokens': {
          'access_token': jwt(clock.add(expiresIn)),
          'refresh_token': 'rt-must-never-be-read',
          'account_id': 'acct-gate',
        },
        'last_refresh': clock.subtract(lastRefreshAge).toIso8601String(),
      }),
    );
  }

  /// A factory that builds the real Codex harness the shipped factory builds,
  /// with only the two process seams replaced so nothing reaches a real binary.
  HarnessFactory recordingCodexFactory() {
    final factory = HarnessFactory();
    factory.register('codex', (factoryConfig) {
      return CodexHarness(
        cwd: factoryConfig.cwd,
        executable: factoryConfig.executable,
        environment: factoryConfig.environment,
        harnessConfig: factoryConfig.harnessConfig,
        providerOptions: factoryConfig.providerOptions,
        guardChain: factoryConfig.guardChain,
        containerManager: factoryConfig.containerManager,
        prepareSubscriptionHome: factoryConfig.prepareSubscriptionHome,
        commandProbe: (executable, arguments) async {
          probedExecutables.add(executable);
          return ProcessResult(0, 0, 'codex-cli 1.0.0', '');
        },
        processFactory:
            (
              executable,
              arguments, {
              String? workingDirectory,
              Map<String, String>? environment,
              bool includeParentEnvironment = true,
            }) async {
              spawns.add(_RecordedSpawn(executable: executable, environment: environment ?? const {}));
              final fake = FakeCodexProcess(completeExitOnKill: true);
              // The wiring owns `start()`, so the handshake has to be answered
              // from here; without it every admitted run would fail on the
              // initialize timeout and read as a refusal.
              unawaited(() async {
                await waitForSentMessage(fake, 'initialize');
                fake.emitInitializeResponse(id: latestRequestId(fake, 'initialize'));
              }());
              return fake;
            },
        killGracePeriod: Duration.zero,
      );
    });
    return factory;
  }

  /// A refresh that drives nothing, standing in for a vendor CLI whose own
  /// token call was refused. The gate must decide from the store, not a throw.
  Future<void> refusingRefresh(String codexHome) async {}

  /// Wires the host boundary against the current store, recording exits and
  /// what startup logged on the way there.
  Future<({List<int> exits, List<String> logs})> wireHostBoundary({CodexVendorRefresh? vendorRefresh}) async {
    final exits = <int>[];
    final logs = <String>[];
    final subscription = Logger.root.onRecord.listen((record) => logs.add('${record.message} ${record.error ?? ''}'));
    storage = await wireTestStorage(config: config, eventBus: eventBus, exitFn: _unexpectedExit);
    security = await wireTestSecurity(
      config: config,
      dataDir: tempDir.path,
      eventBus: eventBus,
      exitFn: _unexpectedExit,
    );
    final wiring = HarnessWiring(
      config: config,
      dataDir: tempDir.path,
      port: 3333,
      harnessFactory: recordingCodexFactory(),
      exitFn: (code) {
        exits.add(code);
        throw const _StartupExit();
      },
      storage: storage!,
      security: security!,
      messageRedactor: MessageRedactor(),
      eventBus: eventBus,
      subscriptionCredentials: store.readAll,
      codexRefresh: CodexRefreshAuthority(
        store: store,
        vendorRefresh: vendorRefresh ?? refusingRefresh,
        now: () => clock,
      ),
      // No inherited process environment: an operator's own exported key must
      // not be what decides this test.
      environment: const {'PATH': '/nonexistent'},
    );
    try {
      await wiring.wire(serverRefGetter: () => throw UnimplementedError('serverRefGetter should not be called'));
      harnessWiring = wiring;
    } on _StartupExit {
      // The real exitFn never returns; the marker stands in for that.
    } finally {
      await subscription.cancel();
    }
    return (exits: exits, logs: logs);
  }

  test('a spent refresh lineage exits startup before any provider CLI is spawned', () async {
    // Past the vendor's 8-day rotation window: a refresh that produces nothing
    // here is spent rather than merely unreachable, which is the one signal
    // that separates a terminal credential from a retryable one.
    writeStore(expiresIn: const Duration(minutes: 1), lastRefreshAge: const Duration(days: 9));

    final outcome = await wireHostBoundary();

    expect(outcome.exits, [1], reason: 'an unusable subscription credential must fail startup closed');
    expect(spawns, isEmpty, reason: 'a provider CLI was spawned on a credential the host cannot make usable');
    // The credential was present and readable throughout, so this refusal came
    // from the freshness gate rather than from an admission presence check.
    expect(store.read('codex'), isNotNull);
    // And the exit is pinned to that cause: `wire()` exits 1 for several
    // unrelated startup failures, any of which would satisfy the two
    // assertions above while the gate itself had quietly stopped working.
    expect(
      outcome.logs.where((line) => line.contains('can no longer be refreshed') && line.contains('codex login')),
      isNotEmpty,
      reason: 'startup exited 1 without reporting the terminal credential: ${outcome.logs}',
    );
    // The refusal reaches the operator without the credential in it.
    expect(outcome.logs.where((line) => line.contains('rt-must-never-be-read')), isEmpty);
  });

  test('a credential nearing the end of its rotation window is still admitted and spawns', () async {
    // Inside the renewal warning the operator surfaces report on, but the
    // lineage is live and the access token is fresh: warn, never refuse.
    writeStore(expiresIn: const Duration(minutes: 60), lastRefreshAge: const Duration(days: 7));

    final outcome = await wireHostBoundary();

    expect(outcome.exits, isEmpty, reason: 'a usable-but-ageing credential was refused: ${outcome.logs}');
    expect(spawns, hasLength(1));
    expect(spawns.single.environment['CODEX_HOME'], store.codexHome);
  });

  test('a token past its JWT expiry with a live lineage is refreshed and spawns', () async {
    // The discriminating case: expired on its face, recoverable in fact. A gate
    // that keyed on the access token's expiry alone would refuse this.
    writeStore(expiresIn: const Duration(minutes: -30), lastRefreshAge: const Duration(hours: 2));

    final outcome = await wireHostBoundary(
      vendorRefresh: (_) async => writeStore(expiresIn: const Duration(minutes: 60)),
    );

    expect(
      outcome.exits,
      isEmpty,
      reason: 'a recoverable credential was refused instead of refreshed: ${outcome.logs}',
    );
    expect(spawns, hasLength(1));
    expect(store.readCodexAuth()!.expiresAt.isAfter(clock), isTrue, reason: 'the store was never rotated');
  });

  test('no provider CLI name is ever resolved against the real PATH', () async {
    writeStore(expiresIn: const Duration(minutes: 60), lastRefreshAge: const Duration(days: 7));

    await wireHostBoundary();

    // Both provider binaries exist on many developer machines and on no CI
    // runner. Pinning that every probe and spawn went to the configured, really
    // existing executable — never a bare `codex` that PATH would have to
    // resolve — is what keeps this suite's result the same in both places.
    final configured = config.providers['codex']!.executable;
    expect(File(configured).existsSync(), isTrue, reason: 'the fixture executable must exist wherever this runs');
    expect(probedExecutables, [configured]);
    expect(spawns.map((spawn) => spawn.executable), [configured]);
  });
}

/// One provider process the wiring asked to start.
final class _RecordedSpawn {
  const new({required this.executable, required this.environment});

  final String executable;
  final Map<String, String> environment;
}

/// Stands in for the process exit a real startup failure takes.
final class _StartupExit implements Exception {
  const new();
}
