import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dartclaw_cli/src/commands/workflow/workflow_show_command.dart';
import 'package:dartclaw_cli/src/dartclaw_api_client.dart';
import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../helpers/fake_api_transport.dart';

class _FakeExit implements Exception {
  final int code;
  const _FakeExit(this.code);
}

Never _fakeExit(int code) => throw _FakeExit(code);

ApiResponse yamlResponse(int statusCode, String body) {
  return ApiResponse(
    statusCode: statusCode,
    headers: const {'content-type': 'application/yaml; charset=utf-8'},
    body: Stream.value(utf8.encode(body)),
  );
}

void main() {
  group('WorkflowShowCommand', () {
    late Directory tempDir;
    late DartclawConfig config;
    late StringBuffer stdoutBuffer;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('workflow_show_test_');
      config = DartclawConfig(
        server: ServerConfig(dataDir: tempDir.path, claudeExecutable: Platform.resolvedExecutable),
      );
      stdoutBuffer = StringBuffer();
    });

    tearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    test('connected raw mode prints authored YAML', () async {
      final transport = FakeApiTransport(
        sendResponses: [yamlResponse(200, 'name: spec-and-implement\ndescription: Demo\n')],
      );
      final apiClient = DartclawApiClient(baseUri: Uri.parse('http://localhost:3333'), transport: transport);

      final runner = CommandRunner<void>('dartclaw', 'test')
        ..addCommand(
          WorkflowShowCommand(
            config: config,
            apiClient: apiClient,
            write: stdoutBuffer.write,
            writeLine: (_) {},
            exitFn: _fakeExit,
          ),
        );

      await runner.run(['show', 'spec-and-implement']);

      expect(stdoutBuffer.toString(), startsWith('name: spec-and-implement'));
      expect(transport.requests.single.uri.path, '/api/workflows/definitions/spec-and-implement');
    });

    test('standalone raw mode prints authored YAML from the local workspace registry', () async {
      final workflowsDir = Directory('${config.server.dataDir}/workflows/definitions')..createSync(recursive: true);
      File('${workflowsDir.path}/show-demo.yaml').writeAsStringSync('''
name: show-demo
description: Demo workflow
steps:
  - id: demo
    name: Demo
    prompt: hi
''');

      final runner = CommandRunner<void>('dartclaw', 'test')
        ..addCommand(
          WorkflowShowCommand(config: config, write: stdoutBuffer.write, writeLine: (_) {}, exitFn: _fakeExit),
        );

      await runner.run(['show', 'show-demo', '--standalone']);

      final output = stdoutBuffer.toString();
      expect(output, startsWith('name: show-demo'));
      expect(output, contains('description: Demo workflow'));
      expect(output, contains('steps:'));
    });

    test('standalone resolved mode injects defaults from native user-tier skill roots', () async {
      final workflowsDir = Directory(p.join(config.server.dataDir, 'workflows', 'definitions'))
        ..createSync(recursive: true);
      File(p.join(workflowsDir.path, 'resolved-skill-demo.yaml')).writeAsStringSync('''
name: resolved-skill-demo
description: Demo workflow
steps:
  - id: demo
    name: Demo
    skill: dartclaw-default-demo
''');

      final fakeHome = Directory(p.join(tempDir.path, 'native-home'))..createSync(recursive: true);
      final skillDir = Directory(p.join(fakeHome.path, '.agents', 'skills', 'dartclaw-default-demo'))
        ..createSync(recursive: true);
      File(p.join(skillDir.path, 'SKILL.md')).writeAsStringSync('''
---
name: dartclaw-default-demo
description: Default demo
workflow:
  default_prompt: default prompt from native user-tier skill
  default_outputs:
    result:
      format: text
      description: Result from default skill.
---

# Demo
''');

      final runner = CommandRunner<void>('dartclaw', 'test')
        ..addCommand(
          WorkflowShowCommand(
            config: config,
            environment: {'HOME': fakeHome.path},
            write: stdoutBuffer.write,
            writeLine: (_) {},
            exitFn: _fakeExit,
          ),
        );

      await runner.run(['show', 'resolved-skill-demo', '--standalone', '--resolved']);

      final output = stdoutBuffer.toString();
      expect(output, contains('prompt: default prompt from native user-tier skill'));
      expect(output, contains('outputs:'));
      expect(output, contains('result:'));
      expect(output, contains('description: Result from default skill.'));
    });

    test('standalone resolved mode uses the current project skill roots when no projects are configured', () async {
      final projectDir = Directory(p.join(tempDir.path, 'project'))..createSync();

      final workflowsDir = Directory(p.join(config.server.dataDir, 'workflows', 'definitions'))
        ..createSync(recursive: true);
      File(p.join(workflowsDir.path, 'project-skill-demo.yaml')).writeAsStringSync('''
name: project-skill-demo
description: Demo workflow
steps:
  - id: demo
    name: Demo
    skill: dartclaw-project-default-demo
''');

      final skillDir = Directory(p.join(projectDir.path, '.agents', 'skills', 'dartclaw-project-default-demo'))
        ..createSync(recursive: true);
      File(p.join(skillDir.path, 'SKILL.md')).writeAsStringSync('''
---
name: dartclaw-project-default-demo
description: Project default demo
workflow:
  default_prompt: default prompt from project skill
---

# Demo
''');

      final runner = CommandRunner<void>('dartclaw', 'test')
        ..addCommand(
          WorkflowShowCommand(
            config: config,
            projectFallbackCwd: projectDir.path,
            write: stdoutBuffer.write,
            writeLine: (_) {},
            exitFn: _fakeExit,
          ),
        );

      await runner.run(['show', 'project-skill-demo', '--standalone', '--resolved']);

      expect(stdoutBuffer.toString(), contains('prompt: default prompt from project skill'));
    });
  });
}
