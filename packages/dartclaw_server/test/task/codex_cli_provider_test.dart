import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:test/test.dart';

void main() {
  group('CodexCliProvider', () {
    test('sandbox override: read-only wins over workspace-write default', () async {
      late List<String> arguments;
      final runner = WorkflowCliRunner(
        providers: const {
          'codex': WorkflowCliProviderConfig(executable: 'codex', options: {'sandbox': 'workspace-write'}),
        },
        processStarter: (exe, args, {workingDirectory, environment}) async {
          arguments = List<String>.from(args);
          final payload = [
            jsonEncode({'type': 'thread.started', 'thread_id': 'codex-sandbox-test'}),
            jsonEncode({
              'type': 'turn.completed',
              'usage': {'input_tokens': 1, 'output_tokens': 1},
            }),
          ].join('\n').replaceAll("'", "'\\''");
          return Process.start('/bin/sh', ['-lc', "printf '%s' '$payload'"]);
        },
      );

      await runner.executeTurn(
        provider: 'codex',
        prompt: 'Test',
        workingDirectory: Directory.systemTemp.path,
        profileId: 'workspace',
        sandboxOverride: 'read-only',
      );

      expect(arguments, isNot(contains('--full-auto')));
      expect(arguments, containsAll(['--sandbox', 'read-only']));
    });

    test('temp schema file is created before spawn and deleted after success', () async {
      final workingDirectory = await Directory.systemTemp.createTemp('codex-provider-schema');
      addTearDown(() async {
        if (await workingDirectory.exists()) await workingDirectory.delete(recursive: true);
      });

      late String schemaPath;
      final payload = [
        jsonEncode({'type': 'thread.started', 'thread_id': 'codex-schema-lifecycle'}),
        jsonEncode({
          'type': 'item.completed',
          'item': {
            'type': 'agent_message',
            'text': jsonEncode({'result': 'done'}),
          },
        }),
        jsonEncode({
          'type': 'turn.completed',
          'usage': {'input_tokens': 2, 'output_tokens': 1},
        }),
      ].join('\n');

      final runner = WorkflowCliRunner(
        providers: const {'codex': WorkflowCliProviderConfig(executable: 'codex')},
        processStarter: (exe, args, {workingDirectory, environment}) async {
          final schemaFlagIndex = args.indexOf('--output-schema');
          schemaPath = args[schemaFlagIndex + 1];
          expect(await File(schemaPath).exists(), isTrue, reason: 'schema file must exist before process starts');
          final escaped = payload.replaceAll("'", "'\\''");
          return Process.start('/bin/sh', ['-lc', "printf '%s' '$escaped'"]);
        },
      );

      await runner.executeTurn(
        provider: 'codex',
        prompt: 'Test',
        workingDirectory: workingDirectory.path,
        profileId: 'workspace',
        jsonSchema: const {
          'type': 'object',
          'properties': {
            'result': {'type': 'string'},
          },
        },
      );

      expect(await File(schemaPath).exists(), isFalse, reason: 'schema file must be deleted after success');
    });

    test('temp schema file is deleted after failure', () async {
      final workingDirectory = await Directory.systemTemp.createTemp('codex-provider-schema-fail');
      addTearDown(() async {
        if (await workingDirectory.exists()) await workingDirectory.delete(recursive: true);
      });

      late String schemaPath;
      final runner = WorkflowCliRunner(
        providers: const {'codex': WorkflowCliProviderConfig(executable: 'codex')},
        processStarter: (exe, args, {workingDirectory, environment}) async {
          final schemaFlagIndex = args.indexOf('--output-schema');
          schemaPath = args[schemaFlagIndex + 1];
          return Process.start('/bin/sh', ['-lc', "printf 'error' >&2; exit 1"]);
        },
      );

      await expectLater(
        () => runner.executeTurn(
          provider: 'codex',
          prompt: 'Test',
          workingDirectory: workingDirectory.path,
          profileId: 'workspace',
          jsonSchema: const {'type': 'object'},
        ),
        throwsA(isA<StateError>()),
      );

      expect(await File(schemaPath).exists(), isFalse, reason: 'schema file must be deleted after failure');
    });

    test('readOnly requests force Codex read-only sandbox even with allowedTools', () async {
      late List<String> arguments;
      final runner = WorkflowCliRunner(
        providers: const {'codex': WorkflowCliProviderConfig(executable: 'codex')},
        processStarter: (exe, args, {workingDirectory, environment}) async {
          arguments = List<String>.from(args);
          final payload = [
            jsonEncode({'type': 'thread.started', 'thread_id': 'codex-read-only-policy'}),
            jsonEncode({
              'type': 'turn.completed',
              'usage': {'input_tokens': 1, 'output_tokens': 1},
            }),
          ].join('\n').replaceAll("'", "'\\''");
          return Process.start('/bin/sh', ['-lc', "printf '%s' '$payload'"]);
        },
      );

      await runner.executeTurn(
        provider: 'codex',
        prompt: 'Test',
        workingDirectory: Directory.systemTemp.path,
        profileId: 'workspace',
        allowedTools: const ['shell', 'file_read'],
        readOnly: true,
      );

      expect(arguments, containsAll(['--sandbox', 'read-only']));
      expect(arguments, isNot(contains('--full-auto')));
    });

    test('buildCodexCommandForTesting: returns correct command vector', () {
      final runner = WorkflowCliRunner(
        providers: const {
          'codex': WorkflowCliProviderConfig(executable: 'codex', options: {'sandbox': 'workspace-write'}),
        },
      );

      final (executable, arguments) = runner.buildCodexCommandForTesting(
        prompt: 'Hello',
        schemaDirectory: Directory.systemTemp.path,
        providerSessionId: 'thread-1',
        model: 'gpt-5',
      );

      expect(executable, 'codex');
      expect(arguments, containsAll(['exec', '--json', '--skip-git-repo-check']));
      expect(arguments, contains('resume'));
      expect(arguments, contains('thread-1'));
      expect(arguments, isNot(contains('--full-auto')));
    });
  });
}
