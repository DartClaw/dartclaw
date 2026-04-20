import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dartclaw_cli/src/commands/workflow/cli_workflow_wiring.dart';
import 'package:dartclaw_cli/src/commands/workflow/workflow_run_command.dart';
import 'package:dartclaw_cli/src/dartclaw_api_client.dart';
import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

class _FakeExit implements Exception {
  final int code;
  const _FakeExit(this.code);
}

Never _fakeExit(int code) => throw _FakeExit(code);

HarnessFactory _harnessFactoryFor(AgentHarness Function() builder) {
  final factory = HarnessFactory();
  factory.register('claude', (_) => builder());
  return factory;
}

void main() {
  group('WorkflowRunCommand standalone mode', () {
    late Directory tempDir;
    late DartclawConfig config;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('dartclaw_workflow_run_standalone_test_');
      config = DartclawConfig(
        agent: const AgentConfig(provider: 'claude'),
        server: ServerConfig(dataDir: tempDir.path, claudeExecutable: Platform.resolvedExecutable),
      );

      final workflowsDir = Directory(p.join(config.workspaceDir, 'workflows'))..createSync(recursive: true);
      File(p.join(workflowsDir.path, 'ci-demo.yaml')).writeAsStringSync('''
name: ci-demo
description: Demo standalone workflow
steps:
  - id: shell-check
    name: Shell Check
    type: bash
    prompt: |
      printf 'standalone-ok\\n'
''');
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('standalone json mode emits structured events and exits 0', () async {
      final output = <String>[];
      final command = WorkflowRunCommand(
        config: config,
        harnessFactory: _harnessFactoryFor(() => FakeAgentHarness()),
        searchDbFactory: (_) => sqlite3.openInMemory(),
        taskDbFactory: (_) => sqlite3.openInMemory(),
        stdoutLine: output.add,
        stderrLine: output.add,
        exitFn: _fakeExit,
      );
      final runner = CommandRunner<void>('dartclaw', 'test')..addCommand(command);

      await expectLater(
        () => runner.run(['run', 'ci-demo', '--standalone', '--json']),
        throwsA(isA<_FakeExit>().having((e) => e.code, 'code', 0)),
      );

      expect(output.first, contains('"type":"run_started"'));
      expect(output.any((line) => line.contains('"type":"workflow_step_completed"')), isTrue);
      expect(output.last, contains('"type":"workflow_status_changed"'));
      expect(output.last, contains('"newStatus":"completed"'));
    });

    test('standalone run aborts early when a referenced credential resolves empty', () async {
      config = DartclawConfig(
        agent: const AgentConfig(provider: 'claude'),
        server: ServerConfig(dataDir: tempDir.path, claudeExecutable: Platform.resolvedExecutable),
        credentials: const CredentialsConfig(
          entries: {
            'github-main': CredentialEntry.githubToken(token: ''),
          },
        ),
        projects: const ProjectConfig(
          definitions: {
            'workflow-testing': ProjectDefinition(
              id: 'workflow-testing',
              remote: 'git@github.com:tolo/dartclaw-workflow-testing.git',
              credentials: 'github-main',
            ),
          },
        ),
      );
      final output = <String>[];
      final command = WorkflowRunCommand(
        config: config,
        apiClient: DartclawApiClient(
          baseUri: Uri.parse('http://localhost:3333'),
          transport: _FakeTransport(sendResponses: [_response(503)]),
        ),
        environment: const {},
        harnessFactory: _harnessFactoryFor(() => FakeAgentHarness()),
        searchDbFactory: (_) => sqlite3.openInMemory(),
        taskDbFactory: (_) => sqlite3.openInMemory(),
        stderrLine: output.add,
        exitFn: _fakeExit,
      );
      final runner = CommandRunner<void>('dartclaw', 'test')..addCommand(command);

      await expectLater(
        () => runner.run(['run', 'ci-demo', '--standalone']),
        throwsA(isA<_FakeExit>().having((e) => e.code, 'code', 1)),
      );

      expect(output, [
        'Credential preflight failed: project "workflow-testing" references credential "github-main" '
            'but env var GITHUB_TOKEN is unset or empty',
      ]);
    });

    test('standalone run provisions explicit provider runners and CLI configs before starting the workflow', () async {
      config = DartclawConfig(
        agent: const AgentConfig(provider: 'codex'),
        providers: const ProvidersConfig(entries: {'codex': ProviderEntry(executable: 'codex', poolSize: 0)}),
        server: ServerConfig(dataDir: tempDir.path, claudeExecutable: Platform.resolvedExecutable),
      );
      final workflowsDir = Directory(p.join(config.workspaceDir, 'workflows'))..createSync(recursive: true);
      File(p.join(workflowsDir.path, 'agent-demo.yaml')).writeAsStringSync('''
name: agent-demo
description: Demo standalone agent workflow
steps:
  - id: review
    name: Review
    type: analysis
    provider: claude
    prompt: |
      Inspect the repo and say ok.
''');

      final createdHarnesses = <String, List<FakeAgentHarness>>{};
      final factory = HarnessFactory()
        ..register('claude', (_) {
          final harness = FakeAgentHarness();
          createdHarnesses.putIfAbsent('claude', () => <FakeAgentHarness>[]).add(harness);
          return harness;
        })
        ..register('codex', (_) {
          final harness = FakeAgentHarness();
          createdHarnesses.putIfAbsent('codex', () => <FakeAgentHarness>[]).add(harness);
          return harness;
        });
      final wiring = CliWorkflowWiring(
        config: config,
        dataDir: config.server.dataDir,
        harnessFactory: factory,
        searchDbFactory: (_) => sqlite3.openInMemory(),
        taskDbFactory: (_) => sqlite3.openInMemory(),
      );
      await wiring.wire();
      addTearDown(wiring.dispose);

      expect(wiring.pool.hasTaskRunnerForProvider('claude'), isFalse);
      expect(wiring.workflowCliRunner.providers.containsKey('claude'), isFalse);

      await wiring.ensureTaskRunnersForProviders({'claude'});

      expect(wiring.pool.hasTaskRunnerForProvider('claude'), isTrue);
      expect(wiring.workflowCliRunner.providers.containsKey('claude'), isTrue);
      expect(createdHarnesses['claude'], isNotEmpty);
    });
  });
}

class _FakeTransport implements ApiTransport {
  final List<ApiResponse> _sendResponses;

  _FakeTransport({List<ApiResponse> sendResponses = const []}) : _sendResponses = List<ApiResponse>.from(sendResponses);

  @override
  Future<ApiResponse> send(ApiRequest request) async => _sendResponses.removeAt(0);

  @override
  Future<ApiResponse> openStream(ApiRequest request) {
    throw UnimplementedError();
  }
}

ApiResponse _response(int statusCode, [Object? body]) {
  return ApiResponse(
    statusCode: statusCode,
    headers: const {'content-type': 'application/json; charset=utf-8'},
    body: Stream.value(utf8.encode(body == null ? '{}' : jsonEncode(body))),
  );
}
