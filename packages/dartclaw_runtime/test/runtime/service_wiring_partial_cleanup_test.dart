import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_workflow/testing.dart' show FakeProviderAuthPreflight;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory dataDir;
  late File configFile;

  setUp(() {
    dataDir = Directory.systemTemp.createTempSync('partial_runtime_cleanup_');
    configFile = File(p.join(dataDir.path, 'dartclaw.yaml'))..writeAsStringSync('# fixture\n');
  });

  tearDown(() {
    if (dataDir.existsSync()) dataDir.deleteSync(recursive: true);
  });

  test('registry failure after storage wiring closes every opened backend and preserves the error', () async {
    final harnesses = HarnessFactory()
      ..register('claude', (_) => FakeAgentHarness())
      ..register('failing-registry-probe', (_) => throw StateError('registry failed after storage'));
    final opened = <DatabaseBackend>[];

    await expectLater(
      _build(dataDir, configFile, harnesses: harnesses, opened: opened),
      throwsA(isA<StateError>().having((error) => error.message, 'message', 'registry failed after storage')),
    );

    await _expectClosed(opened);
  });

  test('late pre-runtime assembly failure closes every opened backend and preserves the error', () async {
    final opened = <DatabaseBackend>[];

    await expectLater(
      _build(
        dataDir,
        configFile,
        harnesses: HarnessFactory()..register('claude', (_) => FakeAgentHarness()),
        opened: opened,
        failServerAssembly: true,
      ),
      throwsA(isA<StateError>().having((error) => error.message, 'message', 'server assembly failed')),
    );

    await _expectClosed(opened);
  });
}

Future<DartclawRuntime> _build(
  Directory dataDir,
  File configFile, {
  required HarnessFactory harnesses,
  required List<DatabaseBackend> opened,
  bool failServerAssembly = false,
}) {
  final config = DartclawConfig(
    agent: const AgentConfig(provider: 'claude'),
    credentials: const CredentialsConfig(entries: {'anthropic': CredentialEntry(apiKey: 'anthropic-key')}),
    providers: ProvidersConfig(
      entries: {'claude': ProviderEntry(executable: Platform.resolvedExecutable, poolSize: 0)},
    ),
    gateway: const GatewayConfig(authMode: 'none'),
    server: ServerConfig(dataDir: dataDir.path, claudeExecutable: Platform.resolvedExecutable),
  );
  Future<DatabaseBackend> openBackend() async {
    final backend = SqliteBackend.openInMemory();
    opened.add(backend);
    return backend;
  }

  return DartclawRuntime.build(
    config,
    dataDir: dataDir.path,
    port: 0,
    harnessFactory: harnesses,
    searchBackendFactory: (_) => openBackend(),
    taskBackendFactory: (_) => openBackend(),
    stderrLine: (_) {},
    exitFn: (code) => throw StateError('unexpected exit $code'),
    resolvedConfigPath: configFile.path,
    messageRedactor: MessageRedactor(),
    resolvedAssets: const ResolvedAssets.embedded(),
    serverFactory: failServerAssembly ? (_) => throw StateError('server assembly failed') : null,
    runWorkflowSkillsBootstrap: false,
    providerAuthPreflight: FakeProviderAuthPreflight(),
  );
}

Future<void> _expectClosed(List<DatabaseBackend> backends) async {
  expect(backends, isNotEmpty);
  for (final backend in backends) {
    await expectLater(() => backend.query('SELECT 1'), throwsStateError);
  }
}
