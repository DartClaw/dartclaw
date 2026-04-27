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

/// Stages skeletal `andthen-*` skills directly into the SkillRegistry's P1/P2
/// scan locations under [searchRoot]. Used by tests that rely on built-in
/// workflow definitions (which reference `andthen-*` skills) but don't
/// exercise the SkillProvisioner bootstrap end-to-end. Without these,
/// [WorkflowDefinitionValidator] excludes the workflows from the registry and
/// route handlers return DEFINITION_NOT_FOUND.
void _stageAndthenSkillStubs(String searchRoot) {
  const skills = [
    'andthen-prd',
    'andthen-plan',
    'andthen-spec',
    'andthen-exec-spec',
    'andthen-review',
    'andthen-remediate-findings',
    'andthen-quick-review',
    'andthen-ops',
  ];
  for (final tier in const ['.claude/skills', '.agents/skills']) {
    for (final name in skills) {
      File(p.join(searchRoot, tier, name, 'SKILL.md'))
        ..createSync(recursive: true)
        ..writeAsStringSync('---\nname: $name\n---\nbody\n');
    }
  }
}

/// Pre-stages `<dataDir>/andthen-src/` as a real git repo with a fake
/// `install-skills.sh` script so the SkillProvisioner can run end-to-end with
/// `andthen.network: disabled` and produce installed `andthen-prd` / DC-native
/// skills under `<dataDir>/.{agents,claude}/skills/`. Required for tests that
/// rely on built-in workflow definitions (which reference `andthen-*` skills);
/// without bootstrap, the workflow validator excludes them from the registry.
void _stageFakeAndthenSrc(String dataDir) {
  final srcDir = Directory(p.join(dataDir, 'andthen-src'))..createSync(recursive: true);
  Directory(p.join(srcDir.path, 'scripts')).createSync(recursive: true);
  File(p.join(srcDir.path, 'scripts', 'install-skills.sh')).writeAsStringSync('''
#!/bin/sh
set -eu
SKILLS_DIR=""
CLAUDE_SKILLS_DIR=""
CLAUDE_AGENTS_DIR=""
USER_DEFAULTS=0
while [ \$# -gt 0 ]; do
  case "\$1" in
    --skills-dir) SKILLS_DIR="\$2"; shift 2 ;;
    --claude-skills-dir) CLAUDE_SKILLS_DIR="\$2"; shift 2 ;;
    --claude-agents-dir) CLAUDE_AGENTS_DIR="\$2"; shift 2 ;;
    --claude-user) USER_DEFAULTS=1; shift ;;
    *) shift ;;
  esac
done
if [ "\$USER_DEFAULTS" = "1" ]; then
  : "\${HOME:?HOME required for --claude-user}"
  SKILLS_DIR="\$HOME/.agents/skills"
  CLAUDE_SKILLS_DIR="\$HOME/.claude/skills"
  CLAUDE_AGENTS_DIR="\$HOME/.claude/agents"
fi
mkdir -p "\$SKILLS_DIR" "\$CLAUDE_SKILLS_DIR" "\$CLAUDE_AGENTS_DIR"
for name in andthen-prd andthen-plan andthen-spec andthen-exec-spec andthen-review andthen-remediate-findings andthen-quick-review andthen-ops; do
  mkdir -p "\$SKILLS_DIR/\$name" "\$CLAUDE_SKILLS_DIR/\$name"
  printf 'fake %s' "\$name" > "\$SKILLS_DIR/\$name/SKILL.md"
  printf 'fake %s' "\$name" > "\$CLAUDE_SKILLS_DIR/\$name/SKILL.md"
done
''');
  Process.runSync('chmod', ['+x', p.join(srcDir.path, 'scripts', 'install-skills.sh')]);
  _runGit(srcDir.path, ['init', '-b', 'main']);
  _runGit(srcDir.path, ['config', 'user.email', 'test@example.com']);
  _runGit(srcDir.path, ['config', 'user.name', 'Test']);
  _runGit(srcDir.path, ['add', '-A']);
  _runGit(srcDir.path, ['commit', '-m', 'init']);
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
    final skillsHomeDir = Directory(p.join(tempDir.path, 'home'))..createSync(recursive: true);
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
      skillsHomeDir: skillsHomeDir.path,
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
    final skillsHomeDir = Directory(p.join(tempDir.path, 'home'))..createSync(recursive: true);
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
      skillsHomeDir: skillsHomeDir.path,
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

  test('ServiceWiring materializes built-in skills for every configured project clone', () async {
    final skillsHomeDir = Directory(p.join(tempDir.path, 'home'))..createSync(recursive: true);
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
      skillsHomeDir: skillsHomeDir.path,
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

    final skillDir = p.join(skillsHomeDir.path, '.claude', 'skills', 'dartclaw-discover-project');
    expect(File(p.join(skillDir, 'SKILL.md')).existsSync(), isTrue);
    expect(File(p.join(skillDir, '.dartclaw-managed')).existsSync(), isTrue);

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
    final skillsHomeDir = Directory(p.join(tempDir.path, 'home'))..createSync(recursive: true);
    final projectDir = Directory(p.join(tempDir.path, 'live-project'))..createSync(recursive: true);
    _runGit(projectDir.path, ['init', '-b', 'main']);
    _runGit(projectDir.path, ['config', 'user.name', 'Test User']);
    _runGit(projectDir.path, ['config', 'user.email', 'test@example.com']);
    File(p.join(projectDir.path, 'README.md')).writeAsStringSync('hello\n');
    _runGit(projectDir.path, ['add', 'README.md']);
    _runGit(projectDir.path, ['commit', '-m', 'initial']);

    // Built-in workflow definitions (e.g. spec-and-implement) reference
    // andthen-* skills. The SkillRegistry scans `<projectDir>/.claude/skills/`
    // and `<projectDir>/.agents/skills/` (P1/P2). Without those references
    // resolving, the validator excludes the workflow and the route returns
    // DEFINITION_NOT_FOUND instead of the ref-validation error under test.
    // Bootstrap is disabled here to keep the test focused on workflow ref
    // validation; staging stubs in P1/P2 is sufficient.
    _stageAndthenSkillStubs(projectDir.path);

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
      skillsHomeDir: skillsHomeDir.path,
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

    expect(response.statusCode, 400);
    final body = jsonDecode(await response.readAsString()) as Map<String, dynamic>;
    expect(((body['error'] as Map<String, dynamic>)['message'] as String), contains('Ref "missing/ref" not found'));
  });

  test('ServiceWiring drops legacy session_cost entries at boot and logs the cleanup count', () async {
    final skillsHomeDir = Directory(p.join(tempDir.path, 'home'))..createSync(recursive: true);
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
      skillsHomeDir: skillsHomeDir.path,
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
    final skillsHomeDir = Directory(p.join(tempDir.path, 'home'))..createSync(recursive: true);
    _stageFakeAndthenSrc(tempDir.path);
    // Fake HOME for the user-tier leg. Both the provisioner (path resolution)
    // and the fake installer (--claude-user expansion) read this HOME, so the
    // test cannot leak fake skills into the developer's real home.
    final fakeHome = Directory(p.join(tempDir.path, 'fake-home'))..createSync(recursive: true);

    final config = DartclawConfig(
      agent: const AgentConfig(provider: 'claude'),
      credentials: const CredentialsConfig(entries: {'anthropic': CredentialEntry(apiKey: 'anthropic-key')}),
      providers: ProvidersConfig(
        entries: {'claude': ProviderEntry(executable: Platform.resolvedExecutable, poolSize: 0)},
      ),
      gateway: const GatewayConfig(authMode: 'none'),
      andthen: const AndthenConfig(installScope: AndthenInstallScope.both, network: AndthenNetworkPolicy.disabled),
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
      skillsHomeDir: skillsHomeDir.path,
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
      skillProvisionerEnvironment: {'HOME': fakeHome.path},
    );

    final result = await wiring.wire();
    addTearDown(() => _disposeWiringResult(result, logService));

    // AndThen-derived skill installed by the fake installer in both data-dir trees.
    expect(File(p.join(tempDir.path, '.agents', 'skills', 'andthen-prd', 'SKILL.md')).existsSync(), isTrue);
    expect(File(p.join(tempDir.path, '.claude', 'skills', 'andthen-prd', 'SKILL.md')).existsSync(), isTrue);
    // DC-native skills copied into both data-dir trees by SkillProvisioner.
    for (final name in const ['dartclaw-discover-project', 'dartclaw-validate-workflow', 'dartclaw-merge-resolve']) {
      expect(
        File(p.join(tempDir.path, '.agents', 'skills', name, 'SKILL.md')).existsSync(),
        isTrue,
        reason: '$name in data-dir Codex tree',
      );
      expect(
        File(p.join(tempDir.path, '.claude', 'skills', name, 'SKILL.md')).existsSync(),
        isTrue,
        reason: '$name in data-dir Claude tree',
      );
    }
    // Marker written for the data-dir destination.
    expect(File(p.join(tempDir.path, '.agents', 'skills', '.dartclaw-andthen-sha')).existsSync(), isTrue);

    // User-tier leg landed under the fake HOME, never the developer's real home.
    expect(File(p.join(fakeHome.path, '.agents', 'skills', 'andthen-prd', 'SKILL.md')).existsSync(), isTrue);
    expect(File(p.join(fakeHome.path, '.claude', 'skills', 'andthen-prd', 'SKILL.md')).existsSync(), isTrue);
    expect(File(p.join(fakeHome.path, '.agents', 'skills', '.dartclaw-andthen-sha')).existsSync(), isTrue);
  });
}
