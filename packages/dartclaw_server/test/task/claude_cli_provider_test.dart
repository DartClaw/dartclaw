import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide GoogleJwtVerifier, HarnessPool, TurnManager, TurnRunner;
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' show FakeProcess, NullIoSink;
import 'package:test/test.dart';

void main() {
  group('ClaudeCliProvider', () {
    test('cancelInflight converts a teardown-killed process to a cancelled result', () async {
      late FakeProcess process;
      final runner = WorkflowCliRunner(
        providers: const {'claude': WorkflowCliProviderConfig(executable: 'claude')},
        processStarter: (exe, args, {workingDirectory, environment}) async {
          process = FakeProcess(completeExitOnKill: true, killExitCode: 143);
          return process;
        },
      );

      final turn = runner.executeTurn(
        provider: 'claude',
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
        providers: const {'claude': WorkflowCliProviderConfig(executable: 'claude')},
        processStarter: (exe, args, {workingDirectory, environment}) async {
          process = _CloseFailsAfterKillProcess();
          return process;
        },
      );

      await runner.cancelInflight(cancelFutureProcesses: true);
      final result = await runner.executeTurn(
        provider: 'claude',
        prompt: 'Test',
        workingDirectory: Directory.systemTemp.path,
        profileId: 'workspace',
      );

      expect(process.killCalled, isTrue);
      expect(result.cancelled, isTrue);
    });

    test('future-start cancellation preserves failure result emitted before stdin close fails', () async {
      late _CloseFailsAfterKillProcess process;
      final runner = WorkflowCliRunner(
        providers: const {'claude': WorkflowCliProviderConfig(executable: 'claude')},
        processStarter: (exe, args, {workingDirectory, environment}) async {
          process = _CloseFailsAfterKillProcess(
            stdoutOnKill: jsonEncode({
              'type': 'result',
              'session_id': 'claude-error-before-close',
              'subtype': 'error_during_execution',
              'is_error': true,
              'result': 'auth failed',
            }),
          );
          return process;
        },
      );

      await runner.cancelInflight(cancelFutureProcesses: true);

      await expectLater(
        runner.executeTurn(
          provider: 'claude',
          prompt: 'Test',
          workingDirectory: Directory.systemTemp.path,
          profileId: 'workspace',
        ),
        throwsA(
          isA<StateError>()
              .having((error) => error.toString(), 'message', contains('Workflow one-shot claude command failed'))
              .having((error) => error.toString(), 'diagnostic', contains('result=auth failed')),
        ),
      );
      expect(process.killCalled, isTrue);
    });

    test('failure result emitted before teardown keeps the diagnostic StateError', () async {
      late FakeProcess process;
      final runner = WorkflowCliRunner(
        providers: const {'claude': WorkflowCliProviderConfig(executable: 'claude')},
        processStarter: (exe, args, {workingDirectory, environment}) async {
          process = FakeProcess(completeExitOnKill: true, killExitCode: 143);
          return process;
        },
      );

      final turn = runner.executeTurn(
        provider: 'claude',
        prompt: 'Test',
        workingDirectory: Directory.systemTemp.path,
        profileId: 'workspace',
      );
      await pumpEventQueue();
      process.emitStdout(
        jsonEncode({
          'type': 'result',
          'session_id': 'claude-error-before-cancel',
          'subtype': 'error_during_execution',
          'is_error': true,
          'result': 'auth failed',
        }),
      );
      await pumpEventQueue();

      await runner.cancelInflight();

      await expectLater(
        turn,
        throwsA(
          isA<StateError>()
              .having((error) => error.toString(), 'message', contains('Workflow one-shot claude command failed'))
              .having((error) => error.toString(), 'diagnostic', contains('result=auth failed')),
        ),
      );
    });

    test('stderr-only failure output before teardown keeps the diagnostic StateError', () async {
      late FakeProcess process;
      final runner = WorkflowCliRunner(
        providers: const {'claude': WorkflowCliProviderConfig(executable: 'claude')},
        processStarter: (exe, args, {workingDirectory, environment}) async {
          process = FakeProcess(completeExitOnKill: true, killExitCode: 143);
          return process;
        },
      );

      final turn = runner.executeTurn(
        provider: 'claude',
        prompt: 'Test',
        workingDirectory: Directory.systemTemp.path,
        profileId: 'workspace',
      );
      await pumpEventQueue();
      process.emitStderr('Error: invalid API key; please run /login');
      await pumpEventQueue();

      await runner.cancelInflight();

      await expectLater(
        turn,
        throwsA(
          isA<StateError>()
              .having((error) => error.toString(), 'message', contains('Workflow one-shot claude command failed'))
              .having((error) => error.toString(), 'stderr', contains('invalid API key')),
        ),
      );
    });

    test('benign stderr before teardown still records a cancellation', () async {
      late FakeProcess process;
      final runner = WorkflowCliRunner(
        providers: const {'claude': WorkflowCliProviderConfig(executable: 'claude')},
        processStarter: (exe, args, {workingDirectory, environment}) async {
          process = FakeProcess(completeExitOnKill: true, killExitCode: 143);
          return process;
        },
      );

      final turn = runner.executeTurn(
        provider: 'claude',
        prompt: 'Test',
        workingDirectory: Directory.systemTemp.path,
        profileId: 'workspace',
      );
      await pumpEventQueue();
      process.emitStderr('CLAUDE_CODE_SUBPROCESS_ENV_SCRUB active');
      await pumpEventQueue();

      await runner.cancelInflight();
      final result = await turn;

      expect(result.cancelled, isTrue);
    });

    test('cancelInflight after a terminal result preserves the parsed success', () async {
      late FakeProcess process;
      final runner = WorkflowCliRunner(
        providers: const {'claude': WorkflowCliProviderConfig(executable: 'claude')},
        processStarter: (exe, args, {workingDirectory, environment}) async {
          process = FakeProcess(completeExitOnKill: true, killExitCode: 143);
          return process;
        },
      );

      final turn = runner.executeTurn(
        provider: 'claude',
        prompt: 'Test',
        workingDirectory: Directory.systemTemp.path,
        profileId: 'workspace',
      );
      await pumpEventQueue();
      process.emitStdout(jsonEncode({'type': 'system', 'subtype': 'init', 'session_id': 'claude-after-terminal'}));
      process.emitStdout(jsonEncode({'type': 'result', 'session_id': 'claude-after-terminal', 'result': 'done'}));
      await pumpEventQueue();

      await runner.cancelInflight();
      final result = await turn;

      expect(result.cancelled, isFalse);
      expect(result.providerSessionId, 'claude-after-terminal');
      expect(result.responseText, 'done');
    });

    test('non-zero exit completed before cancelInflight keeps the diagnostic StateError', () async {
      late FakeProcess process;
      final runner = WorkflowCliRunner(
        providers: const {'claude': WorkflowCliProviderConfig(executable: 'claude')},
        processStarter: (exe, args, {workingDirectory, environment}) async {
          process = FakeProcess(killResult: false);
          return process;
        },
      );

      final turn = runner.executeTurn(
        provider: 'claude',
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
            'Bad state: Workflow one-shot claude command failed with exit code 17',
          ),
        ),
      );
    });

    test('happy path: command vector contains expected flags', () async {
      late String executable;
      late List<String> arguments;
      final runner = WorkflowCliRunner(
        providers: const {
          'claude': WorkflowCliProviderConfig(executable: 'claude', options: {'permissionMode': 'dontAsk'}),
        },
        processStarter: (exe, args, {workingDirectory, environment}) async {
          executable = exe;
          arguments = List<String>.from(args);
          final payload = _streamJsonStdout({
            'session_id': 'claude-provider-test',
            'result': 'hello',
            'usage': {'input_tokens': 5, 'output_tokens': 2},
          }).replaceAll("'", "'\\''");
          return Process.start('/bin/sh', ['-lc', "printf '%s' '$payload'"]);
        },
      );

      await runner.executeTurn(
        provider: 'claude',
        prompt: 'Hi',
        workingDirectory: Directory.systemTemp.path,
        profileId: 'workspace',
        model: 'claude-opus-4',
        maxTurns: 3,
      );

      expect(executable, 'claude');
      expect(
        arguments,
        containsAll(['-p', '--output-format', 'stream-json', '--verbose', '--include-partial-messages']),
      );
      expect(arguments, containsAll(['--model', 'claude-opus-4']));
      expect(arguments, containsAll(['--max-turns', '3']));
      expect(arguments, isNot(contains('--setting-sources')));
      expect(arguments, isNot(contains('--dangerously-skip-permissions')));
      expect(arguments, containsAll(['--permission-mode', 'dontAsk']));
    });

    test('inherit_user_settings false adds project setting sources before model', () async {
      late List<String> arguments;
      final runner = WorkflowCliRunner(
        providers: const {
          'claude': WorkflowCliProviderConfig(executable: 'claude', options: {'inherit_user_settings': false}),
        },
        processStarter: (exe, args, {workingDirectory, environment}) async {
          arguments = List<String>.from(args);
          final payload = _streamJsonStdout({
            'session_id': 'claude-provider-test',
            'result': 'hello',
          }).replaceAll("'", "'\\''");
          return Process.start('/bin/sh', ['-lc', "printf '%s' '$payload'"]);
        },
      );

      await runner.executeTurn(
        provider: 'claude',
        prompt: 'Hi',
        workingDirectory: Directory.systemTemp.path,
        profileId: 'workspace',
        model: 'claude-opus-4',
      );

      final settingIndex = arguments.indexOf('--setting-sources');
      final modelIndex = arguments.indexOf('--model');
      expect(settingIndex, isNonNegative);
      expect(arguments[settingIndex + 1], 'project');
      expect(modelIndex, isNonNegative);
      expect(settingIndex, lessThan(modelIndex));
    });

    test('container manager: working directory translated to container path', () async {
      final workingDirectory = await Directory.systemTemp.createTemp('claude-provider-container');
      addTearDown(() async {
        if (await workingDirectory.exists()) await workingDirectory.delete(recursive: true);
      });

      final container = _FakeContainerExecutor(
        hostRoot: workingDirectory.path,
        containerRoot: '/workspace',
        stdout: _streamJsonStdout({'session_id': 'claude-container-provider', 'result': 'ok'}),
      );

      final runner = WorkflowCliRunner(
        providers: const {'claude': WorkflowCliProviderConfig(executable: 'claude')},
        containerManagers: {'workspace': container},
      );

      await runner.executeTurn(
        provider: 'claude',
        prompt: 'Test',
        workingDirectory: workingDirectory.path,
        profileId: 'workspace',
      );

      expect(container.lastWorkingDirectory, '/workspace');
      expect(container.lastCommand, isNot(contains('--setting-sources')));
    });

    test('parses tokens from the terminal result event usage map, ignoring earlier events', () async {
      late WorkflowCliTurnResult result;
      final runner = WorkflowCliRunner(
        providers: const {'claude': WorkflowCliProviderConfig(executable: 'claude')},
        processStarter: (exe, args, {workingDirectory, environment}) async {
          // Preceding stream events (including a decoy with conflicting token
          // fields) must be skipped; only the terminal `result` event counts.
          final payload = _streamJsonStdout(
            {
              'session_id': 'claude-usage-test',
              'result': 'done',
              'total_cost_usd': 0.5,
              'usage': {
                'input_tokens': 11,
                'output_tokens': 22,
                'cache_read_input_tokens': 33,
                'cache_creation_input_tokens': 44,
              },
            },
            events: [
              {
                'type': 'assistant',
                'usage': {'input_tokens': 999, 'output_tokens': 999},
              },
            ],
          ).replaceAll("'", "'\\''");
          return Process.start('/bin/sh', ['-lc', "printf '%s' '$payload'"]);
        },
      );

      result = await runner.executeTurn(
        provider: 'claude',
        prompt: 'Hi',
        workingDirectory: Directory.systemTemp.path,
        profileId: 'workspace',
      );

      expect(result.responseText, 'done');
      expect(result.providerSessionId, 'claude-usage-test');
      expect(result.inputTokens, 11);
      expect(result.outputTokens, 22);
      expect(result.cacheReadTokens, 33);
      expect(result.cacheWriteTokens, 44);
      expect(result.totalCostUsd, 0.5);
    });

    test('emits ordered live progress events from assistant usage without changing terminal result tokens', () async {
      final progress = _captureProgressEvents();

      final runner = WorkflowCliRunner(
        providers: const {'claude': WorkflowCliProviderConfig(executable: 'claude')},
        eventBus: progress.eventBus,
        processStarter: (exe, args, {workingDirectory, environment}) async {
          final payload = _streamJsonStdout(
            {
              'session_id': 'claude-progress-test',
              'result': 'done',
              'usage': {
                'input_tokens': 999,
                'output_tokens': 88,
                'cache_read_input_tokens': 77,
                'cache_creation_input_tokens': 66,
              },
            },
            events: [
              _assistantEvent(inputTokens: 100, outputTokens: 20),
              _assistantEvent(inputTokens: 260, outputTokens: 35, cacheReadTokens: 12, cacheWriteTokens: 7),
            ],
          ).replaceAll("'", "'\\''");
          return Process.start('/bin/sh', ['-lc', "printf '%s' '$payload'"]);
        },
      );

      final result = await runner.executeTurn(
        provider: 'claude',
        prompt: 'Hi',
        workingDirectory: Directory.systemTemp.path,
        profileId: 'workspace',
        taskId: 'task-1',
        sessionId: 'session-1',
      );

      final progressEvents = progress.events;
      expect(progressEvents, hasLength(2));
      expect(progressEvents.map((event) => event.provider), everyElement('claude'));
      expect(progressEvents.map((event) => event.turnIndex), [1, 2]);
      expect(progressEvents.map((event) => event.taskId), everyElement('task-1'));
      expect(progressEvents.map((event) => event.sessionId), everyElement('session-1'));
      expect(progressEvents.map((event) => event.cumulativeTokens), [120, 315]);
      expect(progressEvents.map((event) => event.inputTokens), [100, 260]);
      expect(progressEvents.map((event) => event.outputTokens), [20, 55]);
      expect(progressEvents.last.cacheReadTokens, 12);
      expect(progressEvents.last.cacheWriteTokens, 7);
      expect(result.inputTokens, 999);
      expect(result.outputTokens, 88);
      expect(result.cacheReadTokens, 77);
      expect(result.cacheWriteTokens, 66);
    });

    test('ignores malformed and usage-less assistant lines while preserving result parsing', () async {
      final progress = _captureProgressEvents();

      final runner = WorkflowCliRunner(
        providers: const {'claude': WorkflowCliProviderConfig(executable: 'claude')},
        eventBus: progress.eventBus,
        processStarter: (exe, args, {workingDirectory, environment}) async {
          final payload = _streamJsonStdout(
            {
              'session_id': 'claude-malformed-progress-test',
              'result': 'done',
              'usage': {'input_tokens': 10, 'output_tokens': 5},
            },
            rawEvents: [
              'not-json',
              jsonEncode({
                'type': 'stream_event',
                'event': {
                  'type': 'content_block_delta',
                  'delta': {'text': 'working'},
                },
              }),
              jsonEncode({'type': 'assistant', 'message': {}}),
              '{"type":"assistant","message":{"usage":',
              '{"type":"assistant","message":{"usage":{"input_tokens":1e400,"output_tokens":5}}}',
              jsonEncode(_assistantEvent(inputTokens: 10, outputTokens: 5)),
            ],
          ).replaceAll("'", "'\\''");
          return Process.start('/bin/sh', ['-lc', "printf '%s' '$payload'"]);
        },
      );

      final result = await runner.executeTurn(
        provider: 'claude',
        prompt: 'Hi',
        workingDirectory: Directory.systemTemp.path,
        profileId: 'workspace',
      );

      expect(progress.events, hasLength(1));
      expect(progress.events.single.cumulativeTokens, 15);
      expect(result.providerSessionId, 'claude-malformed-progress-test');
      expect(result.inputTokens, 10);
      expect(result.outputTokens, 5);
    });

    test('mutation step grants the Edit family alongside Write under dontAsk', () async {
      late List<String> arguments;
      final runner = _recordingRunner((args) => arguments = args);

      await runner.executeTurn(
        provider: 'claude',
        prompt: 'Fix it',
        workingDirectory: Directory.systemTemp.path,
        profileId: 'workspace',
        allowedTools: ['shell', 'file_read', 'file_write', 'file_edit'],
      );

      expect(arguments, containsAll(['--permission-mode', 'dontAsk']));
      expect(arguments, isNot(contains('--dangerously-skip-permissions')));
      final allow = _permissionsAllow(arguments);
      expect(allow, containsAll(['Write(*)', 'Edit(*)', 'MultiEdit(*)', 'NotebookEdit(*)']));
    });

    test('file_write without file_edit omits the Edit family (default unchanged)', () async {
      late List<String> arguments;
      final runner = _recordingRunner((args) => arguments = args);

      await runner.executeTurn(
        provider: 'claude',
        prompt: 'Write only',
        workingDirectory: Directory.systemTemp.path,
        profileId: 'workspace',
        allowedTools: ['shell', 'file_read', 'file_write'],
      );

      final allow = _permissionsAllow(arguments);
      expect(allow, contains('Write(*)'));
      expect(allow, isNot(contains('Edit(*)')));
      expect(allow, isNot(contains('MultiEdit(*)')));
      expect(allow, isNot(contains('NotebookEdit(*)')));
    });

    test('approval: never opts into full access — no allow-list, bypass mode, no StateError', () async {
      late List<String> arguments;
      final runner = _recordingRunner((args) => arguments = args, options: {'approval': 'never'});

      await runner.executeTurn(
        provider: 'claude',
        prompt: 'Do it',
        workingDirectory: Directory.systemTemp.path,
        profileId: 'workspace',
        allowedTools: ['shell', 'file_read', 'file_write', 'file_edit'],
      );

      expect(arguments, containsAll(['--permission-mode', 'bypassPermissions']));
      // No allow-list policy is constructed → no --settings permissions block.
      final settingsIndex = arguments.indexOf('--settings');
      if (settingsIndex >= 0) {
        final settings = jsonDecode(arguments[settingsIndex + 1]) as Map<String, dynamic>;
        expect(settings.containsKey('permissions'), isFalse);
      }
    });

    test('full access (approval: never) opts the spawn env out of the subprocess env-scrub', () async {
      late Map<String, String>? environment;
      final runner = _envRecordingRunner(
        (env) => environment = env,
        options: {'approval': 'never'},
        // Production overlays the v0.14.6 hardening (scrub=1) on every claude spawn.
        providerEnvironment: {'CLAUDE_CODE_SUBPROCESS_ENV_SCRUB': '1'},
      );

      await runner.executeTurn(
        provider: 'claude',
        prompt: 'Do it',
        workingDirectory: Directory.systemTemp.path,
        profileId: 'workspace',
        allowedTools: ['shell', 'file_write', 'file_edit'],
      );

      // The scrub forces --permission-mode default and neutralizes the bypass
      // posture full access relies on, so the run ships an explicit =0 that wins
      // over the inherited hardening.
      expect(environment?['CLAUDE_CODE_SUBPROCESS_ENV_SCRUB'], '0');
    });

    test('policy-enforced step keeps the subprocess env-scrub hardening', () async {
      late Map<String, String>? environment;
      final runner = _envRecordingRunner(
        (env) => environment = env,
        providerEnvironment: {'CLAUDE_CODE_SUBPROCESS_ENV_SCRUB': '1'},
      );

      await runner.executeTurn(
        provider: 'claude',
        prompt: 'Fix it',
        workingDirectory: Directory.systemTemp.path,
        profileId: 'workspace',
        allowedTools: ['shell', 'file_read', 'file_write'],
      );

      // dontAsk + --settings allow rules are honored under forced-default, so the
      // hardening stays on — the provider never overrides it.
      expect(environment?['CLAUDE_CODE_SUBPROCESS_ENV_SCRUB'], '1');
    });

    test('sandbox: workspace-write maps to the sandbox block but keeps dontAsk gating', () async {
      late List<String> arguments;
      final runner = _recordingRunner((args) => arguments = args, options: {'sandbox': 'workspace-write'});

      await runner.executeTurn(
        provider: 'claude',
        prompt: 'Run',
        workingDirectory: Directory.systemTemp.path,
        profileId: 'workspace',
        allowedTools: ['shell', 'file_read', 'file_write', 'file_edit'],
      );

      // Sandbox axis: the block reflects workspace-write isolation.
      final settings = _settingsJson(arguments)!;
      expect(settings['sandbox'], {'enabled': true});
      // Approval axis is untouched: still dontAsk + allow-list.
      expect(arguments, containsAll(['--permission-mode', 'dontAsk']));
      expect(_permissionsAllow(arguments), contains('Edit(*)'));
    });

    test('sandbox: danger-full-access disables isolation but never relaxes prompt gating', () async {
      late List<String> arguments;
      final runner = _recordingRunner((args) => arguments = args, options: {'sandbox': 'danger-full-access'});

      await runner.executeTurn(
        provider: 'claude',
        prompt: 'Run',
        workingDirectory: Directory.systemTemp.path,
        profileId: 'workspace',
        allowedTools: ['shell', 'file_read', 'file_write', 'file_edit'],
      );

      final settings = _settingsJson(arguments)!;
      expect(settings['sandbox'], {'enabled': false});
      expect(arguments, containsAll(['--permission-mode', 'dontAsk']));
      expect(_permissionsAllow(arguments), contains('Edit(*)'));
    });

    test('full-access approval is refused under the restricted container profile', () async {
      final workingDirectory = await Directory.systemTemp.createTemp('claude-restricted');
      addTearDown(() async {
        if (await workingDirectory.exists()) await workingDirectory.delete(recursive: true);
      });
      final container = _FakeContainerExecutor(
        hostRoot: workingDirectory.path,
        containerRoot: '/workspace',
        profileId: 'restricted',
      );
      final runner = WorkflowCliRunner(
        providers: const {
          'claude': WorkflowCliProviderConfig(executable: 'claude', options: {'approval': 'never'}),
        },
        containerManagers: {'restricted': container},
      );

      await expectLater(
        runner.executeTurn(
          provider: 'claude',
          prompt: 'Do it',
          workingDirectory: workingDirectory.path,
          profileId: 'restricted',
          allowedTools: ['shell', 'file_write', 'file_edit'],
        ),
        throwsA(isA<StateError>().having((e) => e.toString(), 'message', contains('restricted container profile'))),
      );
    });

    test('non-zero exit surfaces the stdout result-JSON diagnostic, not just the stderr warning', () async {
      final runner = WorkflowCliRunner(
        providers: const {'claude': WorkflowCliProviderConfig(executable: 'claude')},
        processStarter: (exe, args, {workingDirectory, environment}) async {
          // claude -p reports turn errors in the stdout result JSON; stderr
          // carries only the benign env-scrub warning. Exit 1.
          final payload = _streamJsonStdout({
            'subtype': 'error_during_execution',
            'is_error': true,
            'result': 'reviewer panel crashed',
          }).replaceAll("'", "'\\''");
          const warning = 'Permission mode forced to default — CLAUDE_CODE_SUBPROCESS_ENV_SCRUB is set';
          return Process.start('/bin/sh', ['-lc', "printf '%s' '$payload'; printf '%s' '$warning' 1>&2; exit 1"]);
        },
      );

      await expectLater(
        runner.executeTurn(
          provider: 'claude',
          prompt: 'Review',
          workingDirectory: Directory.systemTemp.path,
          profileId: 'workspace',
        ),
        throwsA(
          isA<Object>().having(
            (e) => e.toString(),
            'message',
            allOf([
              contains('exit code 1'),
              contains('subtype=error_during_execution'),
              contains('is_error=true'),
              contains('result=reviewer panel crashed'),
            ]),
          ),
        ),
      );
    });
  });
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

({EventBus eventBus, List<WorkflowCliTurnProgressEvent> events}) _captureProgressEvents() {
  final eventBus = EventBus();
  addTearDown(eventBus.dispose);
  final events = <WorkflowCliTurnProgressEvent>[];
  final subscription = eventBus.on<WorkflowCliTurnProgressEvent>().listen(events.add);
  addTearDown(subscription.cancel);
  return (eventBus: eventBus, events: events);
}

/// Builds a runner whose claude process-starter records the argv and emits a
/// minimal successful result. [options] overrides the claude provider options.
WorkflowCliRunner _recordingRunner(void Function(List<String>) capture, {Map<String, dynamic> options = const {}}) {
  return WorkflowCliRunner(
    providers: {'claude': WorkflowCliProviderConfig(executable: 'claude', options: options)},
    processStarter: (exe, args, {workingDirectory, environment}) async {
      capture(List<String>.from(args));
      final payload = _streamJsonStdout({'session_id': 'rec', 'result': 'ok'}).replaceAll("'", "'\\''");
      return Process.start('/bin/sh', ['-lc', "printf '%s' '$payload'"]);
    },
  );
}

/// Builds a runner whose claude process-starter records the spawn [environment]
/// and emits a minimal successful result. [providerEnvironment] seeds the
/// provider config's base spawn env (production overlays the harness hardening
/// here); [options] overrides the claude provider options.
WorkflowCliRunner _envRecordingRunner(
  void Function(Map<String, String>? environment) capture, {
  Map<String, dynamic> options = const {},
  Map<String, String> providerEnvironment = const {},
}) {
  return WorkflowCliRunner(
    providers: {
      'claude': WorkflowCliProviderConfig(executable: 'claude', options: options, environment: providerEnvironment),
    },
    processStarter: (exe, args, {workingDirectory, environment}) async {
      capture(environment);
      final payload = _streamJsonStdout({'session_id': 'rec', 'result': 'ok'}).replaceAll("'", "'\\''");
      return Process.start('/bin/sh', ['-lc', "printf '%s' '$payload'"]);
    },
  );
}

/// Decodes the `--settings` JSON object from a recorded argv, or null when none.
Map<String, dynamic>? _settingsJson(List<String> arguments) {
  final index = arguments.indexOf('--settings');
  if (index < 0) return null;
  return jsonDecode(arguments[index + 1]) as Map<String, dynamic>;
}

/// Extracts the `permissions.allow` patterns from the recorded `--settings`.
List<String> _permissionsAllow(List<String> arguments) {
  final settings = _settingsJson(arguments);
  final permissions = settings?['permissions'];
  if (permissions is! Map) return const [];
  final allow = permissions['allow'];
  return allow is List ? allow.cast<String>() : const [];
}

/// Builds claude `--output-format stream-json` stdout: a leading `system/init`
/// event, any [events], then the terminal `result` event carrying [result]'s
/// fields. Mirrors the real CLI's NDJSON-per-line output.
String _streamJsonStdout(
  Map<String, dynamic> result, {
  List<Map<String, dynamic>> events = const [],
  List<String> rawEvents = const [],
}) {
  final lines = <String>[
    jsonEncode({'type': 'system', 'subtype': 'init', 'session_id': result['session_id'] ?? 'sess'}),
    ...events.map(jsonEncode),
    ...rawEvents,
    jsonEncode({'type': 'result', ...result}),
  ];
  return lines.join('\n');
}

Map<String, dynamic> _assistantEvent({
  required int inputTokens,
  required int outputTokens,
  int cacheReadTokens = 0,
  int cacheWriteTokens = 0,
}) {
  return {
    'type': 'assistant',
    'message': {
      'usage': {
        'input_tokens': inputTokens,
        'output_tokens': outputTokens,
        'cache_read_input_tokens': cacheReadTokens,
        'cache_creation_input_tokens': cacheWriteTokens,
      },
    },
  };
}

class _FakeContainerExecutor implements ContainerExecutor {
  @override
  final String profileId;
  @override
  final String workingDir = '/workspace';
  @override
  final bool hasProjectMount = true;

  final String hostRoot;
  final String containerRoot;
  final String stdout;
  late List<String> lastCommand;
  String? lastWorkingDirectory;

  _FakeContainerExecutor({
    required this.hostRoot,
    required this.containerRoot,
    this.profileId = 'workspace',
    String? stdout,
  }) : stdout = stdout ?? _streamJsonStdout({'session_id': 'fake', 'result': 'ok'});

  @override
  Future<void> start() async {}

  @override
  Future<void> copyFileToContainer(String hostPath, String containerPath) async {}

  @override
  Future<void> deleteFileInContainer(String containerPath) async {}

  @override
  Future<Process> exec(List<String> command, {Map<String, String>? env, String? workingDirectory}) async {
    lastCommand = List<String>.from(command);
    lastWorkingDirectory = workingDirectory;
    final escaped = stdout.replaceAll("'", "'\\''");
    return Process.start('/bin/sh', ['-lc', "printf '%s' '$escaped'"]);
  }

  @override
  String? containerPathForHostPath(String hostPath) {
    final normalizedHostPath = File(hostPath).absolute.path;
    final normalizedHostRoot = Directory(hostRoot).absolute.path;
    if (normalizedHostPath == normalizedHostRoot) return containerRoot;
    if (!normalizedHostPath.startsWith('$normalizedHostRoot${Platform.pathSeparator}')) return null;
    final relative = normalizedHostPath.substring(normalizedHostRoot.length + 1).replaceAll('\\', '/');
    return '$containerRoot/$relative';
  }
}
