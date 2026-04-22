import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dartclaw_cli/src/commands/workflow/workflow_show_command.dart';
import 'package:dartclaw_cli/src/dartclaw_api_client.dart';
import 'package:dartclaw_config/dartclaw_config.dart';
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
      config = DartclawConfig(server: ServerConfig(dataDir: tempDir.path, claudeExecutable: Platform.resolvedExecutable));
      stdoutBuffer = StringBuffer();
    });

    tearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    test('connected raw mode prints authored YAML', () async {
      final transport = FakeApiTransport(
        sendResponses: [yamlResponse(200, 'name: spec-and-implement\ndescription: Demo\n')],
      );
      final apiClient = DartclawApiClient(
        baseUri: Uri.parse('http://localhost:3333'),
        transport: transport,
      );

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
          WorkflowShowCommand(
            config: config,
            write: stdoutBuffer.write,
            writeLine: (_) {},
            exitFn: _fakeExit,
          ),
        );

      await runner.run(['show', 'show-demo', '--standalone']);

      final output = stdoutBuffer.toString();
      expect(output, startsWith('name: show-demo'));
      expect(output, contains('description: Demo workflow'));
      expect(output, contains('steps:'));
    });
  });
}
