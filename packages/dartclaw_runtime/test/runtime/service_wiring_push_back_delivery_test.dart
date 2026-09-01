import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:dartclaw_core/dartclaw_core.dart' hide GoogleJwtVerifier, TurnManager, TurnRunner;
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_testing/dartclaw_testing.dart' show FakeAgentHarness;
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

Future<String> _resolvePackageDir(String packageRelativeAnchor) async {
  final uri = await Isolate.resolvePackageUri(Uri.parse('package:dartclaw_runtime/$packageRelativeAnchor'));
  if (uri == null || !uri.isScheme('file')) {
    throw StateError('Could not resolve dartclaw_runtime $packageRelativeAnchor via package URI');
  }
  return p.dirname(uri.toFilePath());
}

void main() {
  late String staticDirPath;
  late String templatesDirPath;
  late Directory tempDir;
  late Directory dataDir;
  late FakeAgentHarness harness;

  setUpAll(() async {
    staticDirPath = await _resolvePackageDir('src/static/app.js');
    templatesDirPath = await _resolvePackageDir('src/templates/audit_table.dart');
  });

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_push_back_delivery_');
    dataDir = Directory(p.join(tempDir.path, 'data'))..createSync(recursive: true);
    harness = FakeAgentHarness();
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  test('task_review push-back starts one turn on the task session', () async {
    final config = DartclawConfig(
      agent: const AgentConfig(provider: 'claude'),
      credentials: const CredentialsConfig(entries: {'anthropic': CredentialEntry(apiKey: 'anthropic-key')}),
      providers: ProvidersConfig(entries: {'claude': ProviderEntry(executable: Platform.resolvedExecutable)}),
      gateway: const GatewayConfig(authMode: 'none'),
      // Left at its default: off. The delivery must not depend on it.
      channels: const ChannelConfig(
        channelConfigs: {
          'whatsapp': {'enabled': true},
        },
      ),
      server: ServerConfig(
        dataDir: dataDir.path,
        staticDir: staticDirPath,
        templatesDir: templatesDirPath,
        claudeExecutable: Platform.resolvedExecutable,
      ),
    );
    expect(config.features.threadBinding.enabled, isFalse);

    final factory = HarnessFactory();
    factory.register('claude', (_) => harness);

    final runtime = await DartclawRuntime.build(
      config,
      dataDir: dataDir.path,
      port: 3000,
      harnessFactory: factory,
      searchDbFactory: (_) => sqlite3.openInMemory(),
      taskDbFactory: (_) => sqlite3.openInMemory(),
      resolvedConfigPath: p.join(tempDir.path, 'dartclaw.yaml'),
      messageRedactor: MessageRedactor(),
      resolvedAssets: ResolvedAssets.fromSourceTree(
        templatesDir: config.server.templatesDir,
        staticDir: config.server.staticDir,
        source: AssetSource.sourceTreeDefault,
      ),
      runWorkflowSkillsBootstrap: false,
      stderrLine: (_) {},
      exitFn: (code) => fail('wiring exited with $code'),
      environment: {'HOME': tempDir.path},
    );
    addTearDown(runtime.shutdownExtras);

    const sessionKey = 'whatsapp:dm:push-back-origin';
    final task = await runtime.taskService.create(
      id: 'pushback-1',
      title: 'Task under review',
      description: 'A task pushed back through the tool',
      configJson: const {
        'needsWorktree': false,
        'origin': {'sessionKey': sessionKey},
      },
    );
    await runtime.taskService.transition(task.id, TaskStatus.queued);
    await runtime.taskService.transition(task.id, TaskStatus.running);
    await runtime.taskService.transition(task.id, TaskStatus.review);

    final call = runtime.server!.mcpHandler.handleRequest(
      jsonEncode({
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'tools/call',
        'params': {
          'name': 'task_review',
          'arguments': {'task_id': task.id, 'action': 'push_back', 'feedback': 'tighten the assertions'},
        },
      }),
    );

    await harness.turnInvoked.timeout(const Duration(seconds: 10));

    final session = await runtime.sessionService.getOrCreateByKey(sessionKey, type: SessionType.channel);
    expect(harness.lastSessionId, session.id);
    expect(harness.turnCallCount, 1);
    expect(harness.lastMessages!.map((message) => message['content']), contains(contains('tighten the assertions')));
    harness.completeSuccess();

    final response = jsonDecode((await call)!) as Map<String, dynamic>;
    final result = response['result'] as Map<String, dynamic>;
    expect(result['isError'], isNull);
    expect((await runtime.taskService.get(task.id))!.status, TaskStatus.running);
  });
}
