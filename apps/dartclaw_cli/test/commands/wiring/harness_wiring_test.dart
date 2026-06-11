import 'dart:io';

import 'package:dartclaw_cli/src/commands/wiring/harness_wiring.dart';
import 'package:dartclaw_cli/src/commands/wiring/security_wiring.dart';
import 'package:dartclaw_cli/src/commands/wiring/storage_wiring.dart';
import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:dartclaw_core/dartclaw_core.dart' hide HarnessConfig;
import 'package:dartclaw_server/dartclaw_server.dart' show TurnRunnerCancellation;
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

  Future<void> wireStorageAndSecurity() async {
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
  }

  Future<void> wireHarness(HarnessFactory factory) async {
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
  }

  HarnessFactory fakeFactory(
    Iterable<String> providerIds, {
    void Function(String providerId, HarnessFactoryConfig)? onCreate,
  }) {
    final factory = HarnessFactory();
    for (final providerId in providerIds) {
      factory.register(providerId, (factoryConfig) {
        onCreate?.call(providerId, factoryConfig);
        final harness = FakeAgentHarness(promptStrategy: PromptStrategy.append);
        createdHarnesses.add(harness);
        return harness;
      });
    }
    return factory;
  }

  test('primary runner keeps interactive prompt while spawned task runner gets lean task prompt', () async {
    await wireStorageAndSecurity();

    final factory = fakeFactory(['claude'], onCreate: (_, factoryConfig) => recordedConfigs.add(factoryConfig));
    await wireHarness(factory);

    expect(harnessWiring!.pool.size, 1);
    expect(harnessWiring!.onSpawnNeeded, isNotNull);

    await harnessWiring!.onSpawnNeeded!(null);

    expect(harnessWiring!.pool.size, 2);
    expect(recordedConfigs, hasLength(2));
    expect(createdHarnesses, hasLength(2));
    expect(recordedConfigs.first.guardChain, same(security!.guardChain));
    expect(recordedConfigs.first.acpPermissionDecision, isNotNull);
    expect(recordedConfigs.first.acpReverseCallAudit, isNotNull);

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

  test('provider-specific lazy spawn consumes the requested provider entry', () async {
    config = DartclawConfig(
      server: ServerConfig(dataDir: tempDir.path, claudeExecutable: Platform.resolvedExecutable),
      agent: const AgentConfig(provider: 'claude'),
      providers: ProvidersConfig(
        entries: {
          'claude': ProviderEntry(executable: Platform.resolvedExecutable, poolSize: 1),
          'codex': ProviderEntry(executable: Platform.resolvedExecutable, poolSize: 1),
        },
      ),
      credentials: const CredentialsConfig(
        entries: {
          'anthropic': CredentialEntry(apiKey: 'anthropic-key'),
          'openai': CredentialEntry(apiKey: 'openai-key'),
        },
      ),
      gateway: const GatewayConfig(authMode: 'none'),
      tasks: const TaskConfig(maxConcurrent: 2),
    );

    await wireStorageAndSecurity();
    final createdProviderIds = <String>[];
    final factory = fakeFactory(
      ['claude', 'codex'],
      onCreate: (providerId, factoryConfig) {
        createdProviderIds.add(providerId);
        recordedConfigs.add(factoryConfig);
      },
    );
    await wireHarness(factory);

    await harnessWiring!.onSpawnNeeded!('codex');

    expect(createdProviderIds, ['claude', 'codex']);
    expect(harnessWiring!.pool.hasTaskRunnerForProvider('codex'), isTrue);
    expect(harnessWiring!.pool.hasTaskRunnerForProvider('claude'), isFalse);

    await harnessWiring!.onSpawnNeeded!('missing');
    expect(createdProviderIds, ['claude', 'codex']);
  });

  test('configured ACP agents register provider identity and default pool capacity', () async {
    config = DartclawConfig(
      server: ServerConfig(dataDir: tempDir.path, claudeExecutable: Platform.resolvedExecutable),
      agent: const AgentConfig(provider: 'claude'),
      harness: HarnessConfig(
        acp: AcpConfig(
          agents: {
            'goose': AcpAgentConfig(
              binary: Platform.resolvedExecutable,
              args: const ['acp'],
              topology: AcpAgentTopology.direct,
              modelProvider: 'anthropic',
              verification: 'a0_1_goose_direct',
              requiresGuardMediation: false,
              requiredBuiltins: const ['developer'],
            ),
          },
        ),
      ),
      providers: ProvidersConfig(
        entries: {'claude': ProviderEntry(executable: Platform.resolvedExecutable, poolSize: 1)},
      ),
      credentials: const CredentialsConfig(entries: {'anthropic': CredentialEntry(apiKey: 'anthropic-key')}),
      gateway: const GatewayConfig(authMode: 'none'),
      tasks: const TaskConfig(maxConcurrent: 10),
    );

    await wireStorageAndSecurity();

    final factory = fakeFactory(['claude']);
    await wireHarness(factory);

    expect(factory.supports('goose'), isTrue);
    expect(harnessWiring!.pool.maxConcurrentTasks, 2);
    expect(harnessWiring!.onSpawnNeeded, isNotNull);
  });

  test('configured Goose and Vibe ACP agents register without unknown-provider fallback', () async {
    config = DartclawConfig(
      server: ServerConfig(dataDir: tempDir.path, claudeExecutable: Platform.resolvedExecutable),
      agent: const AgentConfig(provider: 'claude'),
      harness: HarnessConfig(
        acp: AcpConfig(
          agents: {
            'goose': AcpAgentConfig(
              binary: Platform.resolvedExecutable,
              args: const ['acp', '--with-builtin', 'developer'],
              topology: AcpAgentTopology.direct,
              modelProvider: 'anthropic',
              verification: 'a0_1_goose_direct',
              requiresGuardMediation: false,
              requiredBuiltins: const ['developer'],
            ),
            'vibe': AcpAgentConfig(
              binary: Platform.resolvedExecutable,
              topology: AcpAgentTopology.direct,
              modelProvider: 'mistral',
              verification: 'vibe_acp_direct_probe',
              requiresGuardMediation: false,
            ),
          },
        ),
      ),
      providers: ProvidersConfig(
        entries: {'claude': ProviderEntry(executable: Platform.resolvedExecutable, poolSize: 1)},
      ),
      credentials: const CredentialsConfig(
        entries: {
          'anthropic': CredentialEntry(apiKey: 'anthropic-key'),
          'mistral': CredentialEntry(apiKey: 'mistral-key'),
        },
      ),
      gateway: const GatewayConfig(authMode: 'none'),
      tasks: const TaskConfig(maxConcurrent: 10),
    );

    await wireStorageAndSecurity();

    final factory = fakeFactory(['claude']);
    await wireHarness(factory);

    expect(factory.supports('goose'), isTrue);
    expect(factory.supports('vibe'), isTrue);
    expect(factory.supports('missing_acp_agent'), isFalse);
    expect(
      harnessWiring!.providerStatusEntries['goose']!.options['acp_validation_result'],
      containsPair('securityClassification', 'container_isolation_only'),
    );
    expect(harnessWiring!.providerStatusEntries['goose']!.options['acp_validation_owned'], isTrue);
    expect(
      harnessWiring!.providerStatusEntries['vibe']!.options['acp_validation_result'],
      containsPair('securityClassification', 'container_isolation_only'),
    );
  });

  test('guarded ACP agent without runtime probe evidence fails before registration', () async {
    config = DartclawConfig(
      server: ServerConfig(dataDir: tempDir.path, claudeExecutable: Platform.resolvedExecutable),
      agent: const AgentConfig(provider: 'claude'),
      harness: HarnessConfig(
        acp: AcpConfig(
          agents: {
            'goose': AcpAgentConfig(
              binary: Platform.resolvedExecutable,
              args: const ['acp', '--with-builtin', 'developer'],
              topology: AcpAgentTopology.direct,
              modelProvider: 'anthropic',
              verification: 'a0_1_goose_direct',
              requiresGuardMediation: true,
              requiredBuiltins: const ['developer'],
            ),
          },
        ),
      ),
      providers: ProvidersConfig(
        entries: {'claude': ProviderEntry(executable: Platform.resolvedExecutable, poolSize: 1)},
      ),
      credentials: const CredentialsConfig(entries: {'anthropic': CredentialEntry(apiKey: 'anthropic-key')}),
      gateway: const GatewayConfig(authMode: 'none'),
      tasks: const TaskConfig(maxConcurrent: 10),
    );

    await wireStorageAndSecurity();

    final factory = fakeFactory(['claude']);
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

    await expectLater(
      harnessWiring!.wire(serverRefGetter: () => throw UnimplementedError('serverRefGetter should not be called')),
      throwsA(isA<StateError>().having((error) => error.message, 'message', contains('operation probe evidence'))),
    );
    expect(factory.supports('goose'), isFalse);
    harnessWiring = null;
  });

  test('ACP model_provider credentials are passed to the ACP process environment', () async {
    final envFile = File(p.join(tempDir.path, 'acp-env.txt'));
    final shimFile = File(p.join(tempDir.path, 'fake_acp.dart'));
    shimFile.writeAsStringSync('''
import 'dart:convert';
import 'dart:io';

void main(List<String> args) async {
  File(args.single).writeAsStringSync(Platform.environment['ANTHROPIC_API_KEY'] ?? '');
  await for (final line in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    final message = jsonDecode(line) as Map<String, dynamic>;
    if (message['method'] == 'initialize') {
      stdout.writeln(jsonEncode({
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': {
          'protocolVersion': 1,
          'auth': {'status': 'authenticated'},
        },
      }));
    }
  }
}
''');
    config = DartclawConfig(
      server: ServerConfig(dataDir: tempDir.path, claudeExecutable: Platform.resolvedExecutable),
      agent: const AgentConfig(provider: 'goose'),
      harness: HarnessConfig(
        acp: AcpConfig(
          agents: {
            'goose': AcpAgentConfig(
              binary: Platform.resolvedExecutable,
              args: [shimFile.path, envFile.path],
              topology: AcpAgentTopology.direct,
              modelProvider: 'anthropic',
              verification: 'a0_1_goose_direct',
              requiresGuardMediation: false,
              requiredBuiltins: const ['developer'],
            ),
          },
        ),
      ),
      credentials: const CredentialsConfig(entries: {'anthropic': CredentialEntry(apiKey: 'anthropic-key')}),
      gateway: const GatewayConfig(authMode: 'none'),
      tasks: const TaskConfig(maxConcurrent: 0),
    );

    await wireStorageAndSecurity();
    await wireHarness(HarnessFactory());

    expect(envFile.readAsStringSync(), 'anthropic-key');
  });

  test('ACP agents are included in task capacity when providers section is absent', () async {
    config = DartclawConfig(
      server: ServerConfig(dataDir: tempDir.path, claudeExecutable: Platform.resolvedExecutable),
      agent: const AgentConfig(provider: 'claude'),
      harness: HarnessConfig(
        acp: AcpConfig(
          agents: {
            'goose': AcpAgentConfig(
              binary: Platform.resolvedExecutable,
              args: const ['acp'],
              topology: AcpAgentTopology.direct,
              modelProvider: 'anthropic',
              verification: 'a0_1_goose_direct',
              requiresGuardMediation: false,
              requiredBuiltins: const ['developer'],
            ),
          },
        ),
      ),
      credentials: const CredentialsConfig(entries: {'anthropic': CredentialEntry(apiKey: 'anthropic-key')}),
      gateway: const GatewayConfig(authMode: 'none'),
      tasks: const TaskConfig(maxConcurrent: 10),
    );

    await wireStorageAndSecurity();

    final factory = fakeFactory(['claude']);
    await wireHarness(factory);

    expect(factory.supports('goose'), isTrue);
    expect(harnessWiring!.pool.maxConcurrentTasks, 2);
  });

  test('providers pool_size overrides configured ACP agent default capacity', () async {
    config = DartclawConfig(
      server: ServerConfig(dataDir: tempDir.path, claudeExecutable: Platform.resolvedExecutable),
      agent: const AgentConfig(provider: 'claude'),
      harness: HarnessConfig(
        acp: AcpConfig(
          agents: {
            'goose': AcpAgentConfig(
              binary: Platform.resolvedExecutable,
              args: const ['acp'],
              topology: AcpAgentTopology.direct,
              modelProvider: 'anthropic',
              verification: 'a0_1_goose_direct',
              requiresGuardMediation: false,
              requiredBuiltins: const ['developer'],
            ),
          },
        ),
      ),
      providers: ProvidersConfig(
        entries: {
          'claude': ProviderEntry(executable: Platform.resolvedExecutable, poolSize: 1),
          'goose': ProviderEntry(executable: Platform.resolvedExecutable, poolSize: 2),
        },
      ),
      credentials: const CredentialsConfig(entries: {'anthropic': CredentialEntry(apiKey: 'anthropic-key')}),
      gateway: const GatewayConfig(authMode: 'none'),
      tasks: const TaskConfig(maxConcurrent: 10),
    );

    await wireStorageAndSecurity();

    final factory = fakeFactory(['claude']);
    await wireHarness(factory);

    expect(factory.supports('goose'), isTrue);
    expect(harnessWiring!.pool.maxConcurrentTasks, 3);
    final gooseHarness = factory.create(
      'goose',
      const HarnessFactoryConfig(cwd: '/', executable: '/wrong/provider/executable'),
    );
    addTearDown(gooseHarness.dispose);
    expect(
      gooseHarness,
      isA<AcpHarness>().having((harness) => harness.executable, 'executable', Platform.resolvedExecutable),
    );
  });

  test('container-required ACP spawn fails closed when the configured profile is unavailable', () async {
    config = DartclawConfig(
      server: ServerConfig(dataDir: tempDir.path, claudeExecutable: Platform.resolvedExecutable),
      agent: const AgentConfig(provider: 'claude'),
      harness: HarnessConfig(
        acp: AcpConfig(
          agents: {
            'goose': AcpAgentConfig(
              binary: Platform.resolvedExecutable,
              topology: AcpAgentTopology.relay,
              containerIsolationRequired: true,
              containerProfile: AcpContainerProfile.restricted,
            ),
          },
        ),
      ),
      credentials: const CredentialsConfig(entries: {'anthropic': CredentialEntry(apiKey: 'anthropic-key')}),
      gateway: const GatewayConfig(authMode: 'none'),
      tasks: const TaskConfig(maxConcurrent: 10),
    );

    await wireStorageAndSecurity();

    final factory = fakeFactory(['claude']);
    await wireHarness(factory);

    expect(await harnessWiring!.onSpawnNeeded!('goose'), isFalse);
    expect(harnessWiring!.pool.hasTaskRunnerForProvider('goose'), isFalse);
  });

  test('configured providers use effective pool_size with independent capacity', () async {
    config = DartclawConfig(
      server: ServerConfig(dataDir: tempDir.path, claudeExecutable: Platform.resolvedExecutable),
      agent: const AgentConfig(provider: 'claude'),
      providers: ProvidersConfig(
        entries: {
          'claude': ProviderEntry(executable: Platform.resolvedExecutable, poolSize: 0),
          'codex': ProviderEntry(executable: Platform.resolvedExecutable, poolSize: 1),
        },
      ),
      credentials: const CredentialsConfig(
        entries: {
          'anthropic': CredentialEntry(apiKey: 'anthropic-key'),
          'openai': CredentialEntry(apiKey: 'openai-key'),
        },
      ),
      gateway: const GatewayConfig(authMode: 'none'),
      tasks: const TaskConfig(maxConcurrent: 10),
    );

    await wireStorageAndSecurity();

    final factory = fakeFactory(['claude', 'codex']);
    await wireHarness(factory);

    expect(harnessWiring!.pool.maxConcurrentTasks, 2);

    await harnessWiring!.onSpawnNeeded!('claude');
    await harnessWiring!.onSpawnNeeded!('codex');

    final claudeRunner = harnessWiring!.pool.tryAcquireForProvider('claude');
    final codexRunner = harnessWiring!.pool.tryAcquireForProvider('codex');

    expect(claudeRunner, isNotNull);
    expect(codexRunner, isNotNull);
    expect(harnessWiring!.pool.tryAcquireForProvider('claude'), isNull);
    expect(harnessWiring!.pool.tryAcquireForProvider('codex'), isNull);
  });

  test('non-empty provider config missing default still reserves default capacity', () async {
    config = DartclawConfig(
      server: ServerConfig(dataDir: tempDir.path, claudeExecutable: Platform.resolvedExecutable),
      agent: const AgentConfig(provider: 'claude'),
      providers: ProvidersConfig(
        entries: {'codex': ProviderEntry(executable: Platform.resolvedExecutable, poolSize: 1)},
      ),
      credentials: const CredentialsConfig(
        entries: {
          'anthropic': CredentialEntry(apiKey: 'anthropic-key'),
          'openai': CredentialEntry(apiKey: 'openai-key'),
        },
      ),
      gateway: const GatewayConfig(authMode: 'none'),
      tasks: const TaskConfig(maxConcurrent: 10),
    );

    await wireStorageAndSecurity();

    final factory = fakeFactory(['claude', 'codex']);
    await wireHarness(factory);

    expect(harnessWiring!.pool.maxConcurrentTasks, 2);
    await harnessWiring!.onSpawnNeeded!('claude');
    await harnessWiring!.onSpawnNeeded!('codex');

    expect(harnessWiring!.pool.hasTaskRunnerForProvider('claude'), isTrue);
    expect(harnessWiring!.pool.hasTaskRunnerForProvider('codex'), isTrue);
  });

  test('wired runners use configured turn monitor thresholds and worker timeout', () async {
    config = DartclawConfig(
      server: ServerConfig(dataDir: tempDir.path, claudeExecutable: Platform.resolvedExecutable, workerTimeout: 3),
      agent: const AgentConfig(provider: 'claude'),
      providers: ProvidersConfig(
        entries: {'claude': ProviderEntry(executable: Platform.resolvedExecutable, poolSize: 1)},
      ),
      credentials: const CredentialsConfig(entries: {'anthropic': CredentialEntry(apiKey: 'anthropic-key')}),
      gateway: const GatewayConfig(authMode: 'none'),
      harness: const HarnessConfig(
        turnMonitor: TurnMonitorConfig(
          waitWarningAfter: Duration(milliseconds: 10),
          stuckAfter: Duration(milliseconds: 25),
        ),
      ),
      tasks: const TaskConfig(maxConcurrent: 1),
    );

    await wireStorageAndSecurity();

    final factory = fakeFactory(['claude'], onCreate: (_, factoryConfig) => recordedConfigs.add(factoryConfig));
    await wireHarness(factory);

    final session = await storage!.sessions.createSession();
    final firstTurnId = await harnessWiring!.pool.primary.reserveTurn(session.id);
    final firstOutcome = harnessWiring!.pool.primary.waitForOutcome(session.id, firstTurnId).catchError((_) {
      return TurnOutcome(
        turnId: firstTurnId,
        sessionId: session.id,
        status: TurnStatus.cancelled,
        completedAt: DateTime.now(),
      );
    });
    final queuedReserve = harnessWiring!.pool.primary.reserveTurn(session.id);

    await Future<void>.delayed(const Duration(milliseconds: 35));
    final primaryStatus = harnessWiring!.pool.primary.turnStatus(session.id);
    expect(primaryStatus.state.name, 'stuck');
    expect(primaryStatus.globalTimeoutAt, isNotNull);

    harnessWiring!.pool.primary.releaseTurn(session.id, firstTurnId);
    await firstOutcome;
    final secondTurnId = await queuedReserve.timeout(const Duration(seconds: 1));
    final secondOutcome = harnessWiring!.pool.primary.waitForOutcome(session.id, secondTurnId).catchError((_) {
      return TurnOutcome(
        turnId: secondTurnId,
        sessionId: session.id,
        status: TurnStatus.cancelled,
        completedAt: DateTime.now(),
      );
    });
    harnessWiring!.pool.primary.releaseTurn(session.id, secondTurnId);
    await secondOutcome;

    await harnessWiring!.onSpawnNeeded!(null);
    final taskRunner = harnessWiring!.pool.runners.last;
    final taskSession = await storage!.sessions.createSession();
    final taskFirstTurnId = await taskRunner.reserveTurn(taskSession.id);
    final taskFirstOutcome = taskRunner.waitForOutcome(taskSession.id, taskFirstTurnId).catchError((_) {
      return TurnOutcome(
        turnId: taskFirstTurnId,
        sessionId: taskSession.id,
        status: TurnStatus.cancelled,
        completedAt: DateTime.now(),
      );
    });
    final taskQueuedReserve = taskRunner.reserveTurn(taskSession.id);

    await Future<void>.delayed(const Duration(milliseconds: 35));
    final taskStatus = taskRunner.turnStatus(taskSession.id);
    expect(taskStatus.state.name, 'stuck');
    expect(taskStatus.globalTimeoutAt, isNotNull);

    taskRunner.releaseTurn(taskSession.id, taskFirstTurnId);
    await taskFirstOutcome;
    final taskSecondTurnId = await taskQueuedReserve.timeout(const Duration(seconds: 1));
    final taskSecondOutcome = taskRunner.waitForOutcome(taskSession.id, taskSecondTurnId).catchError((_) {
      return TurnOutcome(
        turnId: taskSecondTurnId,
        sessionId: taskSession.id,
        status: TurnStatus.cancelled,
        completedAt: DateTime.now(),
      );
    });
    taskRunner.releaseTurn(taskSession.id, taskSecondTurnId);
    await taskSecondOutcome;
  });
}
