import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:dartclaw_cli/src/commands/service_wiring.dart';
import 'package:dartclaw_core/dartclaw_core.dart' hide GoogleJwtVerifier, TurnManager, TurnRunner;
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' hide GoogleJwtVerifier, TurnManager, TurnRunner;
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

// Resolved via package URI in setUpAll. Avoids depending on Directory.current
// (mutated concurrently by sibling test files), which previously caused the
// relative-path versions of these helpers to misresolve under default-
// concurrency runs.
late String _staticDirPath;
late String _templatesDirPath;

Future<String> _resolvePackageDir(String packageRelativeAnchor) async {
  final uri = await Isolate.resolvePackageUri(Uri.parse('package:dartclaw_server/$packageRelativeAnchor'));
  if (uri == null || !uri.isScheme('file')) {
    throw StateError('Could not resolve dartclaw_server $packageRelativeAnchor via package URI');
  }
  return p.dirname(uri.toFilePath());
}

HarnessFactory _harnessFactoryFor(AgentHarness harness, {void Function(HarnessFactoryConfig config)? onCreate}) {
  final factory = HarnessFactory();
  factory.register('claude', (config) {
    onCreate?.call(config);
    return harness;
  });
  return factory;
}

void _runGit(String workingDirectory, List<String> args) {
  final result = Process.runSync('git', args, workingDirectory: workingDirectory);
  if (result.exitCode != 0) {
    fail('git ${args.join(' ')} failed in $workingDirectory: ${result.stderr}');
  }
}

Future<void> _waitFor(bool Function() predicate, {Duration timeout = const Duration(seconds: 5)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Condition not met within $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

ResolvedAssets _resolvedAssetsForConfig(DartclawConfig config) => ResolvedAssets.fromSourceTree(
  templatesDir: config.server.templatesDir,
  staticDir: config.server.staticDir,
  source: AssetSource.sourceTreeDefault,
);

Never _unexpectedExit(int code) {
  throw StateError('Unexpected exit($code) during service wiring test');
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

DartclawConfig _schedulingConfig(
  Directory dataDir, {
  MemoryConfig memory = const MemoryConfig.defaults(),
  SchedulingConfig scheduling = const SchedulingConfig(),
}) => DartclawConfig(
  agent: const AgentConfig(provider: 'claude'),
  credentials: const CredentialsConfig(entries: {'anthropic': CredentialEntry(apiKey: 'anthropic-key')}),
  providers: ProvidersConfig(entries: {'claude': ProviderEntry(executable: Platform.resolvedExecutable, poolSize: 0)}),
  gateway: const GatewayConfig(authMode: 'none'),
  memory: memory,
  scheduling: scheduling,
  server: ServerConfig(
    dataDir: dataDir.path,
    staticDir: _staticDirPath,
    templatesDir: _templatesDirPath,
    claudeExecutable: Platform.resolvedExecutable,
  ),
);

void main() {
  late Directory tempDir;
  late File configFile;
  late FakeAgentHarness worker;
  late MessageRedactor messageRedactor;
  late LogService logService;

  ServiceWiring wiringFor(DartclawConfig config, {void Function(HarnessFactoryConfig)? onHarnessCreate}) =>
      ServiceWiring(
        config: config,
        dataDir: tempDir.path,
        port: 3000,
        harnessFactory: _harnessFactoryFor(worker, onCreate: onHarnessCreate),
        serverFactory: (builder) => builder.build(),
        searchDbFactory: (_) => sqlite3.openInMemory(),
        taskDbFactory: (_) => sqlite3.openInMemory(),
        stderrLine: (_) {},
        exitFn: _unexpectedExit,
        resolvedConfigPath: configFile.path,
        logService: logService,
        messageRedactor: messageRedactor,
        resolvedAssets: _resolvedAssetsForConfig(config),
        runWorkflowSkillsBootstrap: false,
      );

  setUpAll(() async {
    _staticDirPath = await _resolvePackageDir('src/static/app.js');
    _templatesDirPath = await _resolvePackageDir('src/templates/audit_table.dart');
    initTemplates(_templatesDirPath);
  });

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_service_wiring_local_path_');
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

  test('workflow API bootstraps local-path projects from the current HEAD without origin/', () async {
    final projectDir = Directory(p.join(tempDir.path, 'live-project'))..createSync(recursive: true);
    final workflowsDir = Directory(p.join(projectDir.path, 'workflows'))..createSync(recursive: true);
    File(p.join(workflowsDir.path, 'bootstrap-localpath.yaml')).writeAsStringSync('''
name: bootstrap-localpath
description: Pause immediately after bootstrap.
variables:
  PROJECT:
    required: true
    description: Target project
  BRANCH:
    required: false
    description: Base ref used for bootstrap
    default: ""
project: "{{PROJECT}}"
gitStrategy:
  bootstrap: true
  worktree: shared
steps:
  - id: gate
    name: Gate
    type: approval
    prompt: Approve bootstrap.
''');

    _runGit(projectDir.path, ['init', '-b', 'main']);
    _runGit(projectDir.path, ['config', 'user.name', 'Workflow Test']);
    _runGit(projectDir.path, ['config', 'user.email', 'workflow@test.local']);
    File(p.join(projectDir.path, 'README.md')).writeAsStringSync('base\n');
    _runGit(projectDir.path, ['add', 'README.md', 'workflows/bootstrap-localpath.yaml']);
    _runGit(projectDir.path, ['commit', '-m', 'initial']);
    _runGit(projectDir.path, ['checkout', '-b', 'feature/local']);
    File(p.join(projectDir.path, 'local.txt')).writeAsStringSync('unpushed local commit\n');
    _runGit(projectDir.path, ['add', 'local.txt']);
    _runGit(projectDir.path, ['commit', '-m', 'local change']);

    final headCommit =
        (Process.runSync('git', ['rev-parse', 'HEAD'], workingDirectory: projectDir.path).stdout as String).trim();

    final config = DartclawConfig(
      agent: const AgentConfig(provider: 'claude'),
      credentials: const CredentialsConfig(entries: {'anthropic': CredentialEntry(apiKey: 'anthropic-key')}),
      providers: ProvidersConfig(
        entries: {'claude': ProviderEntry(executable: Platform.resolvedExecutable, poolSize: 0)},
      ),
      gateway: const GatewayConfig(authMode: 'none'),
      knowledge: const KnowledgeConfig(
        inbox: KnowledgeInboxConfig(
          enabled: true,
          intervalMinutes: 5,
          maxBytes: 1024 * 1024,
          retryAttempts: 2,
          processedRetentionDays: 30,
          deliveryMode: 'announce',
          effort: 'medium',
        ),
        wikiLint: KnowledgeWikiLintConfig(enabled: true, intervalMinutes: 60, deliveryMode: 'announce'),
      ),
      server: ServerConfig(
        dataDir: tempDir.path,
        staticDir: _staticDirPath,
        templatesDir: _templatesDirPath,
        claudeExecutable: Platform.resolvedExecutable,
      ),
      projects: ProjectConfig(
        definitions: {'alpha': ProjectDefinition(id: 'alpha', localPath: projectDir.path, branch: '')},
      ),
    );

    final wiring = wiringFor(config);

    final result = await wiring.wire();
    addTearDown(() => _disposeWiringResult(result, logService));

    final response = await result.server.handler(
      Request(
        'POST',
        Uri.parse('http://localhost/api/workflows/run'),
        headers: {'host': 'localhost', 'content-type': 'application/json'},
        body: jsonEncode({
          'definition': 'bootstrap-localpath',
          'variables': {'PROJECT': 'alpha'},
        }),
      ),
    );

    final responseBody = await response.readAsString();
    expect(response.statusCode, 201, reason: responseBody);

    final runJson = jsonDecode(responseBody) as Map<String, dynamic>;
    expect(runJson['id'], isA<String>());

    await _waitFor(() {
      final result = Process.runSync('git', [
        'branch',
        '--format=%(refname:short)',
        '--list',
        'dartclaw/workflow/*',
      ], workingDirectory: projectDir.path);
      final stdout = result.stdout as String;
      return result.exitCode == 0 && stdout.trim().isNotEmpty;
    });

    final branchList = Process.runSync('git', [
      'branch',
      '--format=%(refname:short) %(objectname)',
      '--list',
      'dartclaw/workflow/*',
    ], workingDirectory: projectDir.path);
    expect(branchList.exitCode, 0, reason: branchList.stderr.toString());
    final refs = (branchList.stdout as String)
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();
    expect(refs, hasLength(1), reason: 'unexpected workflow refs: ${branchList.stdout}');

    final parts = refs.single.split(' ');
    expect(parts.first, startsWith('dartclaw/workflow/'));
    expect(parts.last, headCommit);
  }, tags: ['slow']);

  test('service wiring registers knowledge inbox and wiki lint scheduled jobs', () async {
    final config = DartclawConfig(
      agent: const AgentConfig(provider: 'claude'),
      credentials: const CredentialsConfig(entries: {'anthropic': CredentialEntry(apiKey: 'anthropic-key')}),
      providers: ProvidersConfig(
        entries: {'claude': ProviderEntry(executable: Platform.resolvedExecutable, poolSize: 0)},
      ),
      gateway: const GatewayConfig(authMode: 'none'),
      knowledge: const KnowledgeConfig(
        inbox: KnowledgeInboxConfig(
          enabled: true,
          intervalMinutes: 5,
          maxBytes: 1024 * 1024,
          retryAttempts: 2,
          processedRetentionDays: 30,
          deliveryMode: 'announce',
          effort: 'medium',
        ),
        wikiLint: KnowledgeWikiLintConfig(enabled: true, intervalMinutes: 60, deliveryMode: 'announce'),
      ),
      server: ServerConfig(
        dataDir: tempDir.path,
        staticDir: _staticDirPath,
        templatesDir: _templatesDirPath,
        claudeExecutable: Platform.resolvedExecutable,
      ),
    );
    final workspace = Directory(config.workspaceDir)..createSync(recursive: true);
    Directory(p.join(workspace.path, 'inbox')).createSync(recursive: true);
    File(p.join(workspace.path, 'inbox', 'release-notes.md')).writeAsStringSync('DartClaw release notes.');

    final wiring = wiringFor(config);

    final result = await wiring.wire();
    addTearDown(() => _disposeWiringResult(result, logService));

    final jobs = result.scheduleService!.jobsForTesting;
    expect(jobs.map((job) => job.id), containsAll(['knowledge-inbox', 'knowledge-wiki-lint']));
    final run = result.scheduleService!.executeJobForTesting(jobs.singleWhere((job) => job.id == 'knowledge-inbox'));
    await worker.turnInvoked;
    worker.emit(
      DeltaEvent('''
<workflow-context>{
  "memory_findings": [{"text": "DartClaw release notes synthesized into durable knowledge."}],
  "wiki_page": {
    "slug": "release-notes",
    "title": "Release Notes",
    "body": "Release notes summarize DartClaw changes.",
    "confidence": "medium"
  },
  "facts": [
    {
      "entity": "DartClaw",
      "predicate": "release-notes",
      "value": "available",
      "valid_from": "2026-05-01T00:00:00Z",
      "valid_to": null
    }
  ]
}</workflow-context>
'''),
    );
    worker.completeSuccess({'stop_reason': 'end_turn', 'input_tokens': 1, 'output_tokens': 1, 'model': 'test'});
    await run;

    final observationFiles = Directory(p.join(config.workspaceDir, 'memory'))
        .listSync(followLinks: false)
        .whereType<File>()
        .where((file) => RegExp(r'\d{4}-\d{2}-\d{2}\.md$').hasMatch(file.path));
    expect(
      observationFiles.map((file) => file.readAsStringSync()).join('\n'),
      contains('DartClaw release notes synthesized into durable knowledge'),
    );
    expect(File(p.join(config.workspaceDir, 'wiki', 'release-notes.md')).existsSync(), isTrue);
    expect(File(p.join(config.workspaceDir, 'processed', 'release-notes.md')).existsSync(), isTrue);
  }, tags: ['slow']);

  test('service wiring registers the runnable memory journal system job', () async {
    final config = DartclawConfig(
      agent: const AgentConfig(provider: 'claude'),
      credentials: const CredentialsConfig(entries: {'anthropic': CredentialEntry(apiKey: 'anthropic-key')}),
      providers: ProvidersConfig(
        entries: {'claude': ProviderEntry(executable: Platform.resolvedExecutable, poolSize: 0)},
      ),
      gateway: const GatewayConfig(authMode: 'none'),
      memory: MemoryConfig(journalEnabled: true, journalSchedule: '0 6 * * *'),
      server: ServerConfig(
        dataDir: tempDir.path,
        staticDir: _staticDirPath,
        templatesDir: _templatesDirPath,
        claudeExecutable: Platform.resolvedExecutable,
      ),
    );
    final wiring = wiringFor(config);

    final result = await wiring.wire();
    addTearDown(() => _disposeWiringResult(result, logService));

    final journal = result.scheduleService!.jobsForTesting.singleWhere((job) => job.id == 'memory-journal');
    expect(journal.scheduleType, ScheduleType.cron);
    expect(journal.cronExpression!.minutes, {0});
    expect(journal.cronExpression!.hours, {6});
    expect(journal.prompt, MemoryJournal.prompt);
    expect(journal.deliveryMode, DeliveryMode.none);
    expect(journal.allowedTools, ['file_read', 'memory_observe']);

    final response = await result.server.handler(Request('GET', Uri.parse('http://localhost/scheduling')));
    final html = await response.readAsString();
    expect(response.statusCode, 200);
    expect(html, contains('memory-journal'));
    expect(html, contains('data-job-name="memory-journal"'));
    expect(html, contains('SYSTEM'));
  }, tags: ['slow']);

  test('service wiring always registers memory curation as a run-only immutable action', () async {
    final result = await wiringFor(_schedulingConfig(tempDir)).wire();
    addTearDown(() => _disposeWiringResult(result, logService));

    final action = result.scheduleService!.entries.singleWhere((entry) => entry.id == memoryCurationActionId);
    expect(action.kind, SchedulingEntryKind.systemAction);
    expect(action.runnable, isTrue);
    expect(action.mutable, isFalse);
    expect(result.scheduleService!.jobsForTesting.map((job) => job.id), isNot(contains(memoryCurationActionId)));

    final list = await result.server.handler(Request('GET', Uri.parse('http://localhost/api/scheduling/jobs')));
    final entries = jsonDecode(await list.readAsString()) as List<dynamic>;
    expect(
      entries.whereType<Map<String, dynamic>>().singleWhere((entry) => entry['name'] == memoryCurationActionId)['type'],
      'system_action',
    );

    final page = await result.server.handler(Request('GET', Uri.parse('http://localhost/scheduling')));
    final html = await page.readAsString();
    expect(html, contains('data-job-name="$memoryCurationActionId"'));

    await ConfigWriter(configPath: configFile.path).updateFields({
      'scheduling.jobs': [
        {'name': memoryCurationActionId, 'schedule': '0 1 * * *', 'prompt': 'external collision'},
      ],
    });
    final before = configFile.readAsBytesSync();
    final conflictedPage = await result.server.handler(Request('GET', Uri.parse('http://localhost/scheduling')));
    expect(conflictedPage.statusCode, 409);
    expect(configFile.readAsBytesSync(), before);
  }, tags: ['slow']);

  for (final searchEnabled in [true, false]) {
    test('service wiring aligns semantic MCP mapping and registration with search enabled=$searchEnabled', () async {
      final config = _schedulingConfig(tempDir).copyWith(
        gateway: const GatewayConfig(authMode: 'token', token: 'test-token'),
        search: SearchConfig(
          providers: {'brave': SearchProviderEntry(enabled: searchEnabled, apiKey: 'brave-key')},
        ),
      );
      final factoryConfigs = <HarnessFactoryConfig>[];
      final wiring = wiringFor(config, onHarnessCreate: factoryConfigs.add);

      final result = await wiring.wire();
      addTearDown(() => _disposeWiringResult(result, logService));

      final expected = {
        'sessions_spawn',
        'sessions_send',
        'web_fetch',
        'memory_apply',
        'memory_observe',
        'memory_search',
        'memory_read',
        if (searchEnabled) 'brave_search',
      };
      final runtimeConfigs = factoryConfigs.where((config) => config.guardChain != null);
      expect(runtimeConfigs, isNotEmpty);
      expect(runtimeConfigs.map((config) => config.ownMcpToolCanonicals.keys.toSet()), everyElement(expected));
      expect(result.server.mcpHandler.toolNames.toSet().intersection(expected), expected);
      expect(result.server.mcpHandler.toolNames.contains('brave_search'), searchEnabled);
    }, tags: ['slow']);
  }

  test('authenticated run-now executes the production memory journal with its exact tool policy', () async {
    final config = _schedulingConfig(tempDir, memory: MemoryConfig(journalEnabled: true, journalSchedule: '0 6 * * *'))
        .copyWith(
          gateway: const GatewayConfig(authMode: 'token', token: 'test-token'),
        );
    final factoryConfigs = <HarnessFactoryConfig>[];
    final wiring = wiringFor(config, onHarnessCreate: factoryConfigs.add);

    final result = await wiring.wire();
    addTearDown(() => _disposeWiringResult(result, logService));

    final response = await result.server.handler(
      Request(
        'POST',
        Uri.parse('http://localhost/api/scheduling/jobs/memory-journal/run'),
        headers: {'authorization': 'Bearer test-token'},
      ),
    );
    final body = jsonDecode(await response.readAsString()) as Map<String, dynamic>;
    expect(response.statusCode, 202, reason: body.toString());
    expect(body, {'name': 'memory-journal', 'status': 'started'});

    await worker.turnInvoked;
    expect(worker.lastAgentId, 'cron:memory-journal');
    expect(worker.lastMessages, [
      {'role': 'user', 'content': MemoryJournal.prompt},
    ]);
    expect(result.server.mcpHandler.toolNames, contains('memory_apply'));
    expect(result.server.mcpHandler.toolNames, contains('memory_observe'));

    final sessionId = worker.lastSessionId!;
    final guardChains = factoryConfigs.map((config) => config.guardChain).nonNulls.toList();
    final shellVerdicts = await Future.wait(
      guardChains.map((guardChain) => guardChain.evaluateBeforeToolCall('shell', {}, sessionId: sessionId)),
    );
    expect(shellVerdicts.where((verdict) => verdict.isBlock), hasLength(1));
    final guardChain = guardChains[shellVerdicts.indexWhere((verdict) => verdict.isBlock)];
    expect((await guardChain.evaluateBeforeToolCall('file_read', {}, sessionId: sessionId)).isBlock, isFalse);
    expect((await guardChain.evaluateBeforeToolCall('memory_observe', {}, sessionId: sessionId)).isBlock, isFalse);
    expect((await guardChain.evaluateBeforeToolCall('memory_apply', {}, sessionId: sessionId)).isBlock, isTrue);

    worker.emit(DeltaEvent('Journal complete'));
    worker.completeSuccess({'stop_reason': 'end_turn'});
    await _waitFor(() => !worker.hasPendingTurn);
  }, tags: ['slow']);

  test('service wiring leaves the memory journal absent by default', () async {
    final config = _schedulingConfig(tempDir);
    final wiring = wiringFor(config);

    final result = await wiring.wire();
    addTearDown(() => _disposeWiringResult(result, logService));

    expect(result.scheduleService!.jobsForTesting.map((job) => job.id), isNot(contains('memory-journal')));
    final response = await result.server.handler(Request('GET', Uri.parse('http://localhost/scheduling')));
    expect(await response.readAsString(), isNot(contains('data-job-name="memory-journal"')));
    final runResponse = await result.server.handler(
      Request(
        'POST',
        Uri.parse('http://localhost/api/scheduling/jobs/memory-journal/run'),
        headers: {'host': 'localhost'},
      ),
    );
    expect(runResponse.statusCode, 404);
  }, tags: ['slow']);

  for (final identityKey in ['id', 'name']) {
    test('service wiring rejects a memory journal $identityKey collision', () async {
      final config = _schedulingConfig(
        tempDir,
        memory: MemoryConfig(journalEnabled: true),
        scheduling: SchedulingConfig(
          jobs: [
            {
              identityKey: 'memory-journal',
              'prompt': 'Custom journal',
              'schedule': {'type': 'cron', 'expression': '0 8 * * *'},
            },
          ],
        ),
      );
      final wiring = wiringFor(config);
      addTearDown(logService.dispose);

      await expectLater(
        wiring.wire(),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            allOf(contains('memory-journal'), contains('memory.journal'), contains('scheduling.jobs')),
          ),
        ),
      );
    }, tags: ['slow']);
  }
}
