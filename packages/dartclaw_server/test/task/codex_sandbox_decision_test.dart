import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:test/test.dart';

void main() {
  group('Codex sandbox decision', () {
    test('prefers the stricter explicit sandbox and drops --full-auto', () async {
      late List<String> arguments;
      final runner = WorkflowCliRunner(
        providers: const {
          'codex': WorkflowCliProviderConfig(executable: 'codex', options: {'sandbox': 'workspace-write'}),
        },
        processStarter: (exe, args, {workingDirectory, environment}) async {
          arguments = List<String>.from(args);
          final stdout = [
            jsonEncode({'type': 'thread.started', 'thread_id': 'codex-thread-sandbox'}),
            jsonEncode({
              'type': 'item.completed',
              'item': {'type': 'agent_message', 'text': 'done'},
            }),
            jsonEncode({
              'type': 'turn.completed',
              'usage': {'input_tokens': 1, 'output_tokens': 1},
            }),
          ].join('\n').replaceAll("'", "'\\''");
          return Process.start('/bin/sh', ['-lc', "printf '%s' '$stdout'"]);
        },
      );

      await runner.executeTurn(
        provider: 'codex',
        prompt: 'Inspect the repo',
        workingDirectory: Directory.systemTemp.path,
        profileId: 'workspace',
        sandboxOverride: 'read-only',
      );

      expect(arguments, containsAll(['--sandbox', 'read-only']));
      expect(arguments, isNot(contains('--full-auto')));
    });
  });
}
