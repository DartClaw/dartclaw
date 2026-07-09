import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' show FakeProcess, NullIoSink;
import 'package:test/test.dart';

void main() {
  group('CodexCliProvider', () {
    test('cancelInflight converts a teardown-killed process to a cancelled result', () async {
      late FakeProcess process;
      final runner = WorkflowCliRunner(
        providers: const {'codex': WorkflowCliProviderConfig(executable: 'codex')},
        processStarter: (exe, args, {workingDirectory, environment}) async {
          process = FakeProcess(completeExitOnKill: true, killExitCode: 143);
          return process;
        },
      );

      final turn = runner.executeTurn(
        provider: 'codex',
        prompt: 'Test',
        workingDirectory: Directory.systemTemp.path,
        profileId: 'workspace',
      );
      await pumpEventQueue();

      await runner.cancelInflight();
      final result = await turn;

      expect(process.killCalled, isTrue);
      expect(result.cancelled, isTrue);
    });

    test('future-start cancellation maps stdin close failure to cancelled', () async {
      late _CloseFailsAfterKillProcess process;
      final runner = WorkflowCliRunner(
        providers: const {'codex': WorkflowCliProviderConfig(executable: 'codex')},
        processStarter: (exe, args, {workingDirectory, environment}) async {
          process = _CloseFailsAfterKillProcess();
          return process;
        },
      );

      await runner.cancelInflight(cancelFutureProcesses: true);
      final result = await runner.executeTurn(
        provider: 'codex',
        prompt: 'Test',
        workingDirectory: Directory.systemTemp.path,
        profileId: 'workspace',
      );

      expect(process.killCalled, isTrue);
      expect(result.cancelled, isTrue);
    });

    test('future-start cancellation preserves failure output emitted before stdin close fails', () async {
      late _CloseFailsAfterKillProcess process;
      final runner = WorkflowCliRunner(
        providers: const {'codex': WorkflowCliProviderConfig(executable: 'codex')},
        processStarter: (exe, args, {workingDirectory, environment}) async {
          process = _CloseFailsAfterKillProcess(stdoutOnKill: jsonEncode({'type': 'error', 'message': 'auth failed'}));
          return process;
        },
      );

      await runner.cancelInflight(cancelFutureProcesses: true);

      await expectLater(
        runner.executeTurn(
          provider: 'codex',
          prompt: 'Test',
          workingDirectory: Directory.systemTemp.path,
          profileId: 'workspace',
        ),
        throwsA(
          isA<StateError>()
              .having((error) => error.toString(), 'message', contains('Workflow one-shot codex command failed'))
              .having((error) => error.toString(), 'stdout', contains('auth failed')),
        ),
      );
      expect(process.killCalled, isTrue);
    });

    test('failure output emitted before teardown keeps the diagnostic StateError', () async {
      late FakeProcess process;
      final runner = WorkflowCliRunner(
        providers: const {'codex': WorkflowCliProviderConfig(executable: 'codex')},
        processStarter: (exe, args, {workingDirectory, environment}) async {
          process = FakeProcess(completeExitOnKill: true, killExitCode: 143);
          return process;
        },
      );

      final turn = runner.executeTurn(
        provider: 'codex',
        prompt: 'Test',
        workingDirectory: Directory.systemTemp.path,
        profileId: 'workspace',
      );
      await pumpEventQueue();
      process.emitStdout(jsonEncode({'type': 'error', 'message': 'auth failed'}));
      await pumpEventQueue();

      await runner.cancelInflight();

      await expectLater(
        turn,
        throwsA(
          isA<StateError>()
              .having((error) => error.toString(), 'message', contains('Workflow one-shot codex command failed'))
              .having((error) => error.toString(), 'stdout', contains('auth failed')),
        ),
      );
    });

    test('stderr-only failure output before teardown keeps the diagnostic StateError', () async {
      late FakeProcess process;
      final runner = WorkflowCliRunner(
        providers: const {'codex': WorkflowCliProviderConfig(executable: 'codex')},
        processStarter: (exe, args, {workingDirectory, environment}) async {
          process = FakeProcess(completeExitOnKill: true, killExitCode: 143);
          return process;
        },
      );

      final turn = runner.executeTurn(
        provider: 'codex',
        prompt: 'Test',
        workingDirectory: Directory.systemTemp.path,
        profileId: 'workspace',
      );
      await pumpEventQueue();
      process.emitStderr('Error: codex sandbox denied filesystem access');
      await pumpEventQueue();

      await runner.cancelInflight();

      await expectLater(
        turn,
        throwsA(
          isA<StateError>()
              .having((error) => error.toString(), 'message', contains('Workflow one-shot codex command failed'))
              .having((error) => error.toString(), 'stderr', contains('sandbox denied')),
        ),
      );
    });

    test('benign stderr before teardown still records a cancellation', () async {
      late FakeProcess process;
      final runner = WorkflowCliRunner(
        providers: const {'codex': WorkflowCliProviderConfig(executable: 'codex')},
        processStarter: (exe, args, {workingDirectory, environment}) async {
          process = FakeProcess(completeExitOnKill: true, killExitCode: 143);
          return process;
        },
      );

      final turn = runner.executeTurn(
        provider: 'codex',
        prompt: 'Test',
        workingDirectory: Directory.systemTemp.path,
        profileId: 'workspace',
      );
      await pumpEventQueue();
      process.emitStderr('Reading additional input from stdin...');
      await pumpEventQueue();

      await runner.cancelInflight();
      final result = await turn;

      expect(result.cancelled, isTrue);
    });

    test('cancelInflight after a terminal result preserves the parsed success', () async {
      late FakeProcess process;
      final runner = WorkflowCliRunner(
        providers: const {'codex': WorkflowCliProviderConfig(executable: 'codex')},
        processStarter: (exe, args, {workingDirectory, environment}) async {
          process = FakeProcess(completeExitOnKill: true, killExitCode: 143);
          return process;
        },
      );

      final turn = runner.executeTurn(
        provider: 'codex',
        prompt: 'Test',
        workingDirectory: Directory.systemTemp.path,
        profileId: 'workspace',
      );
      await pumpEventQueue();
      process.emitStdout(jsonEncode({'type': 'thread.started', 'thread_id': 'codex-after-terminal'}));
      process.emitStdout(
        jsonEncode({
          'type': 'item.completed',
          'item': {'type': 'agent_message', 'text': 'done'},
        }),
      );
      process.emitStdout(
        jsonEncode({
          'type': 'turn.completed',
          'usage': {'input_tokens': 1, 'output_tokens': 1},
        }),
      );
      await pumpEventQueue();

      await runner.cancelInflight();
      final result = await turn;

      expect(result.cancelled, isFalse);
      expect(result.providerSessionId, 'codex-after-terminal');
      expect(result.responseText, 'done');
    });

    test('subtracts resumed-session cumulative usage baseline', () async {
      final runner = WorkflowCliRunner(
        providers: const {'codex': WorkflowCliProviderConfig(executable: 'codex')},
        processStarter: (exe, args, {workingDirectory, environment}) {
          return _codexProcess(
            [
              jsonEncode({'type': 'thread.started', 'thread_id': 'codex-resumed'}),
              jsonEncode({
                'type': 'turn.completed',
                'usage': {'input_tokens': 170, 'output_tokens': 25, 'cache_read_tokens': 120, 'cache_write_tokens': 5},
              }),
            ].join('\n'),
          );
        },
      );

      final result = await runner.executeTurn(
        provider: 'codex',
        prompt: 'Test',
        workingDirectory: Directory.systemTemp.path,
        profileId: 'workspace',
        sessionId: 'session-1',
        providerSessionId: 'codex-resumed',
        usageBaseline: const WorkflowCliUsageBaseline(
          inputTokens: 20,
          outputTokens: 10,
          cacheReadTokens: 80,
          cacheWriteTokens: 1,
        ),
      );

      expect(result.inputTokens, 70);
      expect(result.newInputTokens, 30);
      expect(result.outputTokens, 15);
      expect(result.cacheReadTokens, 40);
      expect(result.cacheWriteTokens, 4);
    });

    test('normalizes consecutive cumulative Codex turns to per-turn deltas', () async {
      var call = 0;
      final payloads = [
        [
          jsonEncode({'type': 'thread.started', 'thread_id': 'codex-thread-delta'}),
          jsonEncode({
            'type': 'turn.completed',
            'usage': {'input_tokens': 100, 'output_tokens': 10, 'cache_read_tokens': 80},
          }),
        ].join('\n'),
        [
          jsonEncode({'type': 'thread.started', 'thread_id': 'codex-thread-delta'}),
          jsonEncode({
            'type': 'turn.completed',
            'usage': {'input_tokens': 140, 'output_tokens': 18, 'cache_read_tokens': 100},
          }),
        ].join('\n'),
      ];
      final runner = WorkflowCliRunner(
        providers: const {'codex': WorkflowCliProviderConfig(executable: 'codex')},
        processStarter: (exe, args, {workingDirectory, environment}) => _codexProcess(payloads[call++]),
      );

      final first = await runner.executeTurn(
        provider: 'codex',
        prompt: 'Test',
        workingDirectory: Directory.systemTemp.path,
        profileId: 'workspace',
        sessionId: 'session-1',
      );
      final second = await runner.executeTurn(
        provider: 'codex',
        prompt: 'Test again',
        workingDirectory: Directory.systemTemp.path,
        profileId: 'workspace',
        sessionId: 'session-1',
        providerSessionId: first.providerSessionId,
      );

      expect(first.inputTokens, 100);
      expect(first.newInputTokens, 20);
      expect(first.outputTokens, 10);
      expect(first.cacheReadTokens, 80);
      expect(second.inputTokens, 40);
      expect(second.newInputTokens, 20);
      expect(second.outputTokens, 8);
      expect(second.cacheReadTokens, 20);
    });

    test('resets cumulative normalization when Codex thread id changes', () async {
      var call = 0;
      final payloads = [
        [
          jsonEncode({'type': 'thread.started', 'thread_id': 'codex-thread-a'}),
          jsonEncode({
            'type': 'turn.completed',
            'usage': {'input_tokens': 100, 'output_tokens': 10, 'cache_read_tokens': 70},
          }),
        ].join('\n'),
        [
          jsonEncode({'type': 'thread.started', 'thread_id': 'codex-thread-b'}),
          jsonEncode({
            'type': 'turn.completed',
            'usage': {'input_tokens': 30, 'output_tokens': 4, 'cache_read_tokens': 20},
          }),
        ].join('\n'),
      ];
      final runner = WorkflowCliRunner(
        providers: const {'codex': WorkflowCliProviderConfig(executable: 'codex')},
        processStarter: (exe, args, {workingDirectory, environment}) => _codexProcess(payloads[call++]),
      );

      await runner.executeTurn(
        provider: 'codex',
        prompt: 'Test',
        workingDirectory: Directory.systemTemp.path,
        profileId: 'workspace',
        sessionId: 'session-1',
      );
      final second = await runner.executeTurn(
        provider: 'codex',
        prompt: 'Test again',
        workingDirectory: Directory.systemTemp.path,
        profileId: 'workspace',
        sessionId: 'session-1',
        providerSessionId: 'codex-thread-a',
      );

      expect(second.inputTokens, 30);
      expect(second.newInputTokens, 10);
      expect(second.outputTokens, 4);
      expect(second.cacheReadTokens, 20);
    });

    test('caps the usage-baseline map, evicting the least-recently-written session', () async {
      Future<Process> fakeCodexTurn({required String threadId, required int inputTokens}) {
        // Single-subscription controller buffers events emitted before the
        // provider subscribes (the default broadcast controller drops them).
        final process = FakeProcess(stdoutController: StreamController<List<int>>())
          ..emitStdout(jsonEncode({'type': 'thread.started', 'thread_id': threadId}))
          ..emitStdout(
            jsonEncode({
              'type': 'turn.completed',
              'usage': {'input_tokens': inputTokens, 'output_tokens': 1},
            }),
          )
          ..exit(0);
        return Future.value(process);
      }

      late Future<Process> Function() nextProcess;
      final runner = WorkflowCliRunner(
        providers: const {'codex': WorkflowCliProviderConfig(executable: 'codex')},
        processStarter: (exe, args, {workingDirectory, environment}) => nextProcess(),
      );

      Future<WorkflowCliTurnResult> turn(String sessionId, {String? providerSessionId, required int cumulative}) {
        nextProcess = () => fakeCodexTurn(threadId: 'thread-$sessionId', inputTokens: cumulative);
        return runner.executeTurn(
          provider: 'codex',
          prompt: 'Test',
          workingDirectory: Directory.systemTemp.path,
          profileId: 'workspace',
          sessionId: sessionId,
          providerSessionId: providerSessionId,
        );
      }

      final first = await turn('evicted', cumulative: 100);
      expect(first.inputTokens, 100);

      // 512 distinct sessions push the map past the cap; 'evicted' is oldest.
      for (var i = 0; i < 512; i++) {
        await turn('filler-$i', cumulative: 100);
      }

      // A recent session inside the cap keeps its baseline: delta, not cumulative.
      final recent = await turn('filler-511', providerSessionId: 'thread-filler-511', cumulative: 150);
      expect(recent.inputTokens, 50);

      // The evicted session lost its baseline: full cumulative is re-reported.
      final evicted = await turn('evicted', providerSessionId: 'thread-evicted', cumulative: 150);
      expect(evicted.inputTokens, 150);
    });

    test('non-zero exit without cancellation keeps the diagnostic StateError', () async {
      final runner = WorkflowCliRunner(
        providers: const {'codex': WorkflowCliProviderConfig(executable: 'codex')},
        processStarter: (exe, args, {workingDirectory, environment}) async {
          return Process.start('/bin/sh', ['-lc', "printf 'codex crashed' >&2; exit 17"]);
        },
      );

      await expectLater(
        runner.executeTurn(
          provider: 'codex',
          prompt: 'Test',
          workingDirectory: Directory.systemTemp.path,
          profileId: 'workspace',
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.toString(),
            'message',
            'Bad state: Workflow one-shot codex command failed with exit code 17: codex crashed',
          ),
        ),
      );
    });

    test('non-zero exit completed before cancelInflight keeps the diagnostic StateError', () async {
      late FakeProcess process;
      final runner = WorkflowCliRunner(
        providers: const {'codex': WorkflowCliProviderConfig(executable: 'codex')},
        processStarter: (exe, args, {workingDirectory, environment}) async {
          process = FakeProcess(killResult: false);
          return process;
        },
      );

      final turn = runner.executeTurn(
        provider: 'codex',
        prompt: 'Test',
        workingDirectory: Directory.systemTemp.path,
        profileId: 'workspace',
      );
      await pumpEventQueue();
      process.exit(17);

      await runner.cancelInflight();

      await expectLater(
        turn,
        throwsA(
          isA<StateError>().having(
            (error) => error.toString(),
            'message',
            'Bad state: Workflow one-shot codex command failed with exit code 17',
          ),
        ),
      );
    });

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

Future<Process> _codexProcess(String payload) {
  final escaped = payload.replaceAll("'", "'\\''");
  return Process.start('/bin/sh', ['-lc', "printf '%s' '$escaped'"]);
}

class _CloseFailsAfterKillProcess extends FakeProcess {
  _CloseFailsAfterKillProcess({this.stdoutOnKill}) : super(completeExitOnKill: true, killExitCode: 143);

  final String? stdoutOnKill;

  late final IOSink _stdin = _CloseFailsAfterKillSink(() => killCalled);

  @override
  IOSink get stdin => _stdin;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    final stdout = stdoutOnKill;
    if (stdout != null) {
      emitStdout(stdout);
    }
    return super.kill(signal);
  }
}

class _CloseFailsAfterKillSink extends NullIoSink {
  _CloseFailsAfterKillSink(this._killed);

  final bool Function() _killed;

  @override
  Future<void> close() async {
    if (_killed()) {
      throw StateError('stdin close failed after kill');
    }
    await super.close();
  }
}
