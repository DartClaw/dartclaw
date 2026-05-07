@Tags(['integration'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_cli/src/commands/service_wiring.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

String _staticDir() {
  const fromPkg = 'packages/dartclaw_server/lib/src/static';
  if (Directory(fromPkg).existsSync()) return fromPkg;
  return p.join('..', '..', 'packages', 'dartclaw_server', 'lib', 'src', 'static');
}

String _templatesDir() {
  const fromWorkspace = 'packages/dartclaw_server/lib/src/templates';
  if (Directory(fromWorkspace).existsSync()) return fromWorkspace;
  return p.join('..', '..', 'packages', 'dartclaw_server', 'lib', 'src', 'templates');
}

HarnessFactory _harnessFactoryFor(AgentHarness harness) {
  final factory = HarnessFactory();
  factory.register('claude', (_) => harness);
  return factory;
}

void _runGit(String workingDirectory, List<String> args) {
  final result = Process.runSync('git', args, workingDirectory: workingDirectory);
  if (result.exitCode != 0) {
    fail('git ${args.join(' ')} failed in $workingDirectory: ${result.stderr}');
  }
}

/// Stages skeletal provider-owned AndThen skills directly into SkillRegistry
/// scan locations under [searchRoot]. Tests that rely on shipped workflow
/// definitions need these references resolvable while keeping skill bootstrap
/// out of the specific behavior under test.
void _stageProviderAndThenSkillStubs(String searchRoot) {
  const refs = [
    'andthen:prd',
    'andthen:plan',
    'andthen:spec',
    'andthen:exec-spec',
    'andthen:review',
    'andthen:remediate-findings',
    'andthen:quick-review',
    'andthen:ops',
    'andthen:architecture',
    'andthen:refactor',
  ];
  for (final ref in refs) {
    final codexAlias = ref.replaceFirst('andthen:', 'andthen-');
    for (final entry in [(tier: '.claude/skills', name: ref), (tier: '.agents/skills', name: codexAlias)]) {
      File(p.join(searchRoot, entry.tier, entry.name, 'SKILL.md'))
        ..createSync(recursive: true)
        ..writeAsStringSync('---\nname: "${entry.name}"\n---\nbody\n');
    }
  }
}

Never _unexpectedExit(int code) {
  throw StateError('Unexpected exit($code) during server builder integration test');
}

class _RecordingChannel extends Channel {
  final List<(String, ChannelResponse)> sent = [];

  @override
  String get name => 'recording-googlechat';

  @override
  ChannelType get type => ChannelType.googlechat;

  @override
  Future<void> connect() async {}

  @override
  Future<void> disconnect() async {}

  @override
  bool ownsJid(String jid) => true;

  @override
  Future<void> sendMessage(String recipientJid, ChannelResponse response) async {
    sent.add((recipientJid, response));
  }
}

Future<void> _disposeWiringResult(WiringResult result, LogService logService) async {
  await result.server.shutdown();
  await result.shutdownExtras();
  result.heartbeat?.stop();
  result.scheduleService?.stop();
  result.resetService.dispose();
  await result.kvService.dispose();
  await result.selfImprovement.dispose();
  await result.taskService.dispose();
  await result.eventBus.dispose();
  await result.qmdManager?.stop();
  result.searchDb.close();
  await logService.dispose();
}

void main() {
  late Directory tempDir;
  late File configFile;
  late FakeAgentHarness worker;
  late MessageRedactor messageRedactor;
  late LogService logService;

  setUpAll(() => initTemplates(_templatesDir()));

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_server_builder_integration_');
    configFile = File(p.join(tempDir.path, 'dartclaw.yaml'))..writeAsStringSync('# test config\n');
    worker = FakeAgentHarness();

    messageRedactor = MessageRedactor();
    logService = LogService.fromConfig(
      format: 'human',
      level: 'INFO',
      redactor: LogRedactor(redactor: messageRedactor),
    );
  });

  tearDown(() async {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  test('ServiceWiring builds a server that serves / and /health', () async {
    final config = DartclawConfig(
      agent: const AgentConfig(provider: 'claude'),
      credentials: const CredentialsConfig(entries: {'anthropic': CredentialEntry(apiKey: 'anthropic-key')}),
      providers: ProvidersConfig(
        entries: {'claude': ProviderEntry(executable: Platform.resolvedExecutable, poolSize: 0)},
      ),
      gateway: const GatewayConfig(authMode: 'none'),
      server: ServerConfig(
        dataDir: tempDir.path,
        staticDir: _staticDir(),
        templatesDir: _templatesDir(),
        claudeExecutable: Platform.resolvedExecutable,
      ),
    );

    final wiring = ServiceWiring(
      config: config,
      dataDir: tempDir.path,
      port: 3000,
      harnessFactory: _harnessFactoryFor(worker),
      serverFactory: (builder) => builder.build(),
      searchDbFactory: (_) => sqlite3.openInMemory(),
      taskDbFactory: (_) => sqlite3.openInMemory(),
      stderrLine: (_) {},
      exitFn: _unexpectedExit,
      resolvedConfigPath: configFile.path,
      logService: logService,
      messageRedactor: messageRedactor,
      runAndthenSkillsBootstrap: false,
    );

    final result = await wiring.wire();
    addTearDown(() => _disposeWiringResult(result, logService));
    await result.agentExecutionRepository.create(
      AgentExecution(
        id: 'ae-1',
        provider: 'claude',
        sessionId: 'sess-1',
        startedAt: DateTime.parse('2026-04-19T00:00:00Z'),
      ),
    );
    expect(await result.agentExecutionRepository.get('ae-1'), isNotNull);

    final handler = result.server.handler;

    final rootResponse = await handler(Request('GET', Uri.parse('http://localhost/')));
    expect(rootResponse.statusCode, equals(302));
    expect(rootResponse.headers['location'], startsWith('/sessions/'));

    final healthResponse = await handler(Request('GET', Uri.parse('http://localhost/health')));
    expect(healthResponse.statusCode, equals(200));

    final healthBody = jsonDecode(await healthResponse.readAsString()) as Map<String, dynamic>;
    expect(healthBody['status'], equals('healthy'));
  });

  test('ServiceWiring wires AlertRouter into the production EventBus', () async {
    final config = DartclawConfig(
      agent: const AgentConfig(provider: 'claude'),
      credentials: const CredentialsConfig(entries: {'anthropic': CredentialEntry(apiKey: 'anthropic-key')}),
      providers: ProvidersConfig(
        entries: {'claude': ProviderEntry(executable: Platform.resolvedExecutable, poolSize: 0)},
      ),
      gateway: const GatewayConfig(authMode: 'none'),
      alerts: const AlertsConfig(
        enabled: true,
        targets: [AlertTarget(channel: 'googlechat', recipient: 'spaces/abc')],
      ),
      channels: const ChannelConfig(
        channelConfigs: {
          'google_chat': {'enabled': true},
        },
      ),
      server: ServerConfig(
        dataDir: tempDir.path,
        staticDir: _staticDir(),
        templatesDir: _templatesDir(),
        claudeExecutable: Platform.resolvedExecutable,
      ),
    );

    final wiring = ServiceWiring(
      config: config,
      dataDir: tempDir.path,
      port: 3000,
      harnessFactory: _harnessFactoryFor(worker),
      serverFactory: (builder) => builder.build(),
      searchDbFactory: (_) => sqlite3.openInMemory(),
      taskDbFactory: (_) => sqlite3.openInMemory(),
      stderrLine: (_) {},
      exitFn: _unexpectedExit,
      resolvedConfigPath: configFile.path,
      logService: logService,
      messageRedactor: messageRedactor,
      runAndthenSkillsBootstrap: false,
    );

    final result = await wiring.wire();
    addTearDown(() => _disposeWiringResult(result, logService));

    final channel = _RecordingChannel();
    result.channelManager!.registerChannel(channel);

    result.eventBus.fire(
      GuardBlockEvent(
        guardName: 'bash-guard',
        guardCategory: 'file',
        verdict: 'block',
        hookPoint: 'PreToolUse',
        timestamp: DateTime.now(),
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(channel.sent, hasLength(1));
    expect(channel.sent.single.$1, equals('spaces/abc'));
    expect(channel.sent.single.$2.text, contains('Guard Block'));
  });

  test('ServiceWiring loads built-in skills from source tree without materializing project copies', () async {
    for (final projectId in ['alpha', 'beta']) {
      Directory(p.join(tempDir.path, 'projects', projectId)).createSync(recursive: true);
    }

    final config = DartclawConfig(
      agent: const AgentConfig(provider: 'claude'),
      credentials: const CredentialsConfig(entries: {'anthropic': CredentialEntry(apiKey: 'anthropic-key')}),
      providers: ProvidersConfig(
        entries: {'claude': ProviderEntry(executable: Platform.resolvedExecutable, poolSize: 0)},
      ),
      gateway: const GatewayConfig(authMode: 'none'),
      projects: const ProjectConfig(
        definitions: {
          'alpha': ProjectDefinition(id: 'alpha', remote: 'file:///tmp/alpha.git'),
          'beta': ProjectDefinition(id: 'beta', remote: 'file:///tmp/beta.git'),
        },
      ),
      server: ServerConfig(
        dataDir: tempDir.path,
        staticDir: _staticDir(),
        templatesDir: _templatesDir(),
        claudeExecutable: Platform.resolvedExecutable,
      ),
    );

    final wiring = ServiceWiring(
      config: config,
      dataDir: tempDir.path,
      port: 3000,
      harnessFactory: _harnessFactoryFor(worker),
      serverFactory: (builder) => builder.build(),
      searchDbFactory: (_) => sqlite3.openInMemory(),
      taskDbFactory: (_) => sqlite3.openInMemory(),
      stderrLine: (_) {},
      exitFn: _unexpectedExit,
      resolvedConfigPath: configFile.path,
      logService: logService,
      messageRedactor: messageRedactor,
      runAndthenSkillsBootstrap: false,
    );

    final result = await wiring.wire();
    addTearDown(() => _disposeWiringResult(result, logService));

    expect(result.skillRegistry.getByName('dartclaw-discover-project'), isNotNull);

    for (final projectId in ['alpha', 'beta']) {
      final projectSkillDir = p.join(
        tempDir.path,
        'projects',
        projectId,
        '.claude',
        'skills',
        'dartclaw-discover-project',
      );
      expect(Directory(projectSkillDir).existsSync(), isFalse);
    }
  });

  test('ServiceWiring rejects missing local refs for local-path workflow starts', () async {
    final projectDir = Directory(p.join(tempDir.path, 'live-project'))..createSync(recursive: true);
    _runGit(projectDir.path, ['init', '-b', 'main']);
    _runGit(projectDir.path, ['config', 'user.name', 'Test User']);
    _runGit(projectDir.path, ['config', 'user.email', 'test@example.com']);
    File(p.join(projectDir.path, 'README.md')).writeAsStringSync('hello\n');
    _runGit(projectDir.path, ['add', 'README.md']);
    _runGit(projectDir.path, ['commit', '-m', 'initial']);

    _stageProviderAndThenSkillStubs(tempDir.path);
    _stageProviderAndThenSkillStubs(projectDir.path);

    final config = DartclawConfig(
      agent: const AgentConfig(provider: 'claude'),
      credentials: const CredentialsConfig(entries: {'anthropic': CredentialEntry(apiKey: 'anthropic-key')}),
      providers: ProvidersConfig(
        entries: {'claude': ProviderEntry(executable: Platform.resolvedExecutable, poolSize: 0)},
      ),
      gateway: const GatewayConfig(authMode: 'none'),
      projects: ProjectConfig(
        definitions: {'alpha': ProjectDefinition(id: 'alpha', localPath: projectDir.path, branch: 'main')},
      ),
      server: ServerConfig(
        dataDir: tempDir.path,
        staticDir: _staticDir(),
        templatesDir: _templatesDir(),
        claudeExecutable: Platform.resolvedExecutable,
      ),
    );

    final wiring = ServiceWiring(
      config: config,
      dataDir: tempDir.path,
      port: 3000,
      harnessFactory: _harnessFactoryFor(worker),
      serverFactory: (builder) => builder.build(),
      searchDbFactory: (_) => sqlite3.openInMemory(),
      taskDbFactory: (_) => sqlite3.openInMemory(),
      stderrLine: (_) {},
      exitFn: _unexpectedExit,
      resolvedConfigPath: configFile.path,
      logService: logService,
      messageRedactor: messageRedactor,
      runAndthenSkillsBootstrap: false,
    );

    final result = await wiring.wire();
    addTearDown(() => _disposeWiringResult(result, logService));

    final response = await result.server.handler(
      Request(
        'POST',
        Uri.parse('http://localhost/api/workflows/run'),
        body: jsonEncode({
          'definition': 'spec-and-implement',
          'variables': {'FEATURE': 'Missing ref regression', 'PROJECT': 'alpha', 'BRANCH': 'missing/ref'},
        }),
        headers: {'content-type': 'application/json'},
      ),
    );

    final responseBody = await response.readAsString();
    expect(response.statusCode, 400, reason: responseBody);
    final body = jsonDecode(responseBody) as Map<String, dynamic>;
    expect(((body['error'] as Map<String, dynamic>)['message'] as String), contains('Ref "missing/ref" not found'));
  });

  test('ServiceWiring drops legacy session_cost entries at boot and logs the cleanup count', () async {
    final seededKv = KvService(filePath: p.join(tempDir.path, 'kv.json'));
    await seededKv.set(
      'session_cost:legacy',
      jsonEncode({'input_tokens': 100, 'new_input_tokens': 20, 'output_tokens': 50, 'total_tokens': 150}),
    );
    await seededKv.set(
      'session_cost:current',
      jsonEncode({
        'input_tokens': 20,
        'output_tokens': 10,
        'cache_read_tokens': 5,
        'cache_write_tokens': 0,
        'total_tokens': 30,
        'effective_tokens': 30,
        'estimated_cost_usd': 0.0,
        'turn_count': 1,
        'provider': 'claude',
      }),
    );
    await seededKv.dispose();

    final config = DartclawConfig(
      agent: const AgentConfig(provider: 'claude'),
      credentials: const CredentialsConfig(entries: {'anthropic': CredentialEntry(apiKey: 'anthropic-key')}),
      providers: ProvidersConfig(
        entries: {'claude': ProviderEntry(executable: Platform.resolvedExecutable, poolSize: 0)},
      ),
      gateway: const GatewayConfig(authMode: 'none'),
      server: ServerConfig(
        dataDir: tempDir.path,
        staticDir: _staticDir(),
        templatesDir: _templatesDir(),
        claudeExecutable: Platform.resolvedExecutable,
      ),
    );

    final oldLevel = Logger.root.level;
    Logger.root.level = Level.ALL;
    final records = <LogRecord>[];
    final logSub = Logger.root.onRecord.listen(records.add);
    addTearDown(() async {
      await logSub.cancel();
      Logger.root.level = oldLevel;
    });

    final wiring = ServiceWiring(
      config: config,
      dataDir: tempDir.path,
      port: 3000,
      harnessFactory: _harnessFactoryFor(worker),
      serverFactory: (builder) => builder.build(),
      searchDbFactory: (_) => sqlite3.openInMemory(),
      taskDbFactory: (_) => sqlite3.openInMemory(),
      stderrLine: (_) {},
      exitFn: _unexpectedExit,
      resolvedConfigPath: configFile.path,
      logService: logService,
      messageRedactor: messageRedactor,
      runAndthenSkillsBootstrap: false,
    );

    final result = await wiring.wire();
    addTearDown(() => _disposeWiringResult(result, logService));

    expect(await result.kvService.get('session_cost:legacy'), isNull);
    expect(await result.kvService.get('session_cost:current'), isNotNull);
    expect(
      records.any(
        (record) =>
            record.loggerName == 'ServiceWiring' &&
            record.level == Level.INFO &&
            record.message == 'Dropped 1 legacy session_cost entries (pre-Tier-1b schema)',
      ),
      isTrue,
    );
  });

  test('ServiceWiring runs the AndThen skills bootstrap before wire() returns', () async {
    final provisionHome = Directory(p.join(tempDir.path, 'provision-home'))..createSync(recursive: true);
    _stageProviderAndThenSkillStubs(provisionHome.path);

    final config = DartclawConfig(
      agent: const AgentConfig(provider: 'claude'),
      credentials: const CredentialsConfig(entries: {'anthropic': CredentialEntry(apiKey: 'anthropic-key')}),
      providers: ProvidersConfig(
        entries: {'claude': ProviderEntry(executable: Platform.resolvedExecutable, poolSize: 0)},
      ),
      gateway: const GatewayConfig(authMode: 'none'),
      server: ServerConfig(
        dataDir: tempDir.path,
        staticDir: _staticDir(),
        templatesDir: _templatesDir(),
        claudeExecutable: Platform.resolvedExecutable,
      ),
    );

    final wiring = ServiceWiring(
      config: config,
      dataDir: tempDir.path,
      port: 3000,
      harnessFactory: _harnessFactoryFor(worker),
      serverFactory: (builder) => builder.build(),
      searchDbFactory: (_) => sqlite3.openInMemory(),
      taskDbFactory: (_) => sqlite3.openInMemory(),
      stderrLine: (_) {},
      exitFn: _unexpectedExit,
      resolvedConfigPath: configFile.path,
      logService: logService,
      messageRedactor: messageRedactor,
      // Default `runAndthenSkillsBootstrap: true` — we want the bootstrap to run.
      skillProvisionerEnvironment: {'HOME': provisionHome.path},
    );

    final result = await wiring.wire();
    addTearDown(() => _disposeWiringResult(result, logService));

    // DC-native skills copied into both data-dir native trees by SkillProvisioner.
    for (final name in const ['dartclaw-discover-project', 'dartclaw-validate-workflow', 'dartclaw-merge-resolve']) {
      expect(
        File(p.join(tempDir.path, '.agents', 'skills', name, 'SKILL.md')).existsSync(),
        isTrue,
        reason: '$name in data-dir native Codex tree',
      );
      expect(
        File(p.join(tempDir.path, '.claude', 'skills', name, 'SKILL.md')).existsSync(),
        isTrue,
        reason: '$name in data-dir native Claude tree',
      );
    }
    // Marker written for the data-dir native destination.
    expect(File(p.join(tempDir.path, '.dartclaw-native-skills')).existsSync(), isTrue);
    expect(_unexpectedDataDirSkillEntries(tempDir.path), isEmpty);
  });
}

List<String> _unexpectedDataDirSkillEntries(String dataDir) {
  final allowed = {'dartclaw-discover-project', 'dartclaw-validate-workflow', 'dartclaw-merge-resolve'};
  final roots = [Directory(p.join(dataDir, '.agents', 'skills')), Directory(p.join(dataDir, '.claude', 'skills'))];
  return [
    for (final root in roots)
      if (root.existsSync())
        for (final entity in root.listSync(followLinks: false))
          if (entity is Directory && !allowed.contains(p.basename(entity.path))) entity.path,
  ];
}
