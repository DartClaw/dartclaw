import 'dart:io';

import 'package:dartclaw_cli/src/commands/wiring/harness_wiring.dart';
import 'package:dartclaw_cli/src/commands/wiring/security_wiring.dart';
import 'package:dartclaw_cli/src/commands/wiring/storage_wiring.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

Never _unexpectedExit(int code) {
  throw StateError('Unexpected exit($code) during harness wiring test');
}

void main() {
  late Directory tempDir;
  late Directory workspaceDir;
  late DartclawConfig config;
  late EventBus eventBus;
  late List<HarnessFactoryConfig> recordedConfigs;
  late List<FakeAgentHarness> createdHarnesses;
  StorageWiring? storage;
  SecurityWiring? security;
  HarnessWiring? harnessWiring;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_harness_wiring_');
    config = DartclawConfig(
      server: ServerConfig(dataDir: tempDir.path, claudeExecutable: Platform.resolvedExecutable),
      agent: const AgentConfig(provider: 'claude'),
      providers: ProvidersConfig(
        entries: {'claude': ProviderEntry(executable: Platform.resolvedExecutable, poolSize: 1)},
      ),
      credentials: const CredentialsConfig(entries: {'anthropic': CredentialEntry(apiKey: 'anthropic-key')}),
      gateway: const GatewayConfig(authMode: 'none'),
      tasks: const TaskConfig(maxConcurrent: 1),
    );

    workspaceDir = Directory(config.workspaceDir)..createSync(recursive: true);
    File(p.join(workspaceDir.path, 'SOUL.md')).writeAsStringSync('Soul prompt');
    File(p.join(workspaceDir.path, 'USER.md')).writeAsStringSync('User prompt');
    File(p.join(workspaceDir.path, 'TOOLS.md')).writeAsStringSync('Tool prompt');
    File(p.join(workspaceDir.path, 'AGENTS.md')).writeAsStringSync('## Agent prompt');
    File(p.join(workspaceDir.path, 'errors.md')).writeAsStringSync('## Recent error');
    File(p.join(workspaceDir.path, 'learnings.md')).writeAsStringSync('## Recent learning');

    eventBus = EventBus();
    recordedConfigs = <HarnessFactoryConfig>[];
    createdHarnesses = <FakeAgentHarness>[];
  });

  tearDown(() async {
    await harnessWiring?.pool.dispose();
    await storage?.dispose();
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  test('primary runner keeps interactive prompt while spawned task runner gets lean task prompt', () async {
    storage = StorageWiring(
      config: config,
      eventBus: eventBus,
      searchDbFactory: (_) => sqlite3.openInMemory(),
      taskDbFactory: (_) => sqlite3.openInMemory(),
      exitFn: _unexpectedExit,
    );
    await storage!.wire();

    security = SecurityWiring(config: config, dataDir: tempDir.path, eventBus: eventBus, exitFn: _unexpectedExit);
    await security!.wire(
      agentDefs: config.agent.definitions.isNotEmpty ? config.agent.definitions : [AgentDefinition.searchAgent()],
    );

    final factory = HarnessFactory();
    factory.register('claude', (factoryConfig) {
      recordedConfigs.add(factoryConfig);
      final harness = FakeAgentHarness(promptStrategy: PromptStrategy.append);
      createdHarnesses.add(harness);
      return harness;
    });

    harnessWiring = HarnessWiring(
      config: config,
      dataDir: tempDir.path,
      port: 3333,
      harnessFactory: factory,
      exitFn: _unexpectedExit,
      storage: storage!,
      security: security!,
      messageRedactor: MessageRedactor(),
      eventBus: eventBus,
    );
    await harnessWiring!.wire(serverRefGetter: () => throw UnimplementedError('serverRefGetter should not be called'));

    expect(harnessWiring!.pool.size, 1);
    expect(harnessWiring!.onSpawnNeeded, isNotNull);

    await harnessWiring!.onSpawnNeeded!();

    expect(harnessWiring!.pool.size, 2);
    expect(recordedConfigs, hasLength(2));
    expect(createdHarnesses, hasLength(2));

    final primaryPrompt = recordedConfigs.first.harnessConfig.appendSystemPrompt ?? '';
    final taskPrompt = recordedConfigs.last.harnessConfig.appendSystemPrompt ?? '';

    expect(primaryPrompt, contains('Soul prompt'));
    expect(primaryPrompt, contains('User prompt'));
    expect(primaryPrompt, contains('Tool prompt'));
    expect(primaryPrompt, contains('## Agent prompt'));
    expect(primaryPrompt, contains('## Recent error'));
    expect(primaryPrompt, contains('## Recent learning'));
    expect(primaryPrompt, contains('memory_read tool'));

    expect(taskPrompt, contains('Soul prompt'));
    expect(taskPrompt, contains('Tool prompt'));
    expect(taskPrompt, contains('## Agent prompt'));
    expect(taskPrompt, contains('memory_read tool'));
    expect(taskPrompt, isNot(contains('User prompt')));
    expect(taskPrompt, isNot(contains('## Recent error')));
    expect(taskPrompt, isNot(contains('## Recent learning')));
    expect(taskPrompt.length, lessThan(primaryPrompt.length));
  });
}
