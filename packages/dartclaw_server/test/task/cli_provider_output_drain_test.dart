import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_config/dartclaw_config.dart' show PlatformCapabilities;
import 'package:dartclaw_core/dartclaw_core.dart' show ProcessTerminationResult;
import 'package:dartclaw_server/dartclaw_server.dart'
    show CliTurnRequest, WorkflowCliProviderConfig, WorkflowCliRunner, WorkflowCliTurnResult;
import 'package:dartclaw_server/src/task/claude_cli_provider.dart' show ClaudeCliProvider;
import 'package:dartclaw_server/src/task/cli_provider.dart' show CliProvider, ProcessBackedCliProvider;
import 'package:dartclaw_server/src/task/codex_cli_provider.dart' show CodexCliProvider;
import 'package:dartclaw_testing/dartclaw_testing.dart' show FakeProcess, NullIoSink;
import 'package:test/test.dart';

void main() {
  test('accepted Windows tree cleanup clears cancellation after a late root exit', () async {
    final provider = _AcceptedTreeProvider();
    final process = FakeProcess();
    provider.trackInflightProcess(process);

    await provider.cancelInflight();
    provider.finishInflightRun(process);
    expect(provider.cancellationRequestedFor(process), isTrue);

    process.exit(0);
    await pumpEventQueue();

    expect(provider.cancellationRequestedFor(process), isFalse);
  });

  for (final provider in const ['claude', 'codex']) {
    test('$provider turn completes when a descendant keeps output pipes open after root exit', () async {
      final stdoutController = StreamController<List<int>>();
      final stderrController = StreamController<List<int>>();
      late FakeProcess process;
      final implementation = switch (provider) {
        'claude' => ClaudeCliProvider(outputDrainGracePeriod: Duration.zero),
        _ => CodexCliProvider(outputDrainGracePeriod: Duration.zero),
      };
      final runner = WorkflowCliRunner(
        providers: {provider: WorkflowCliProviderConfig(executable: provider)},
        providerImpls: <String, CliProvider>{provider: implementation},
        processStarter: (executable, arguments, {workingDirectory, environment}) async {
          process = FakeProcess(
            stdoutController: stdoutController,
            stderrController: stderrController,
            closeStreamsOnExit: false,
          );
          return process;
        },
      );

      final turn = runner.executeTurn(
        provider: provider,
        prompt: 'Test',
        workingDirectory: Directory.systemTemp.path,
        profileId: 'workspace',
      );
      await pumpEventQueue();

      for (final event in _eventsFor(provider)) {
        process.emitStdout(jsonEncode(event));
      }
      await pumpEventQueue();
      process.exit(0);

      final result = await turn;

      expect(result.responseText, 'done');
      await stdoutController.close();
      await stderrController.close();
    });

    test('$provider cancellation completes when stdin close fails and a descendant keeps output pipes open', () async {
      final stdoutController = StreamController<List<int>>();
      final stderrController = StreamController<List<int>>();
      addTearDown(stdoutController.close);
      addTearDown(stderrController.close);
      late _CloseFailsAfterKillProcess process;
      final implementation = switch (provider) {
        'claude' => ClaudeCliProvider(outputDrainGracePeriod: Duration.zero),
        _ => CodexCliProvider(outputDrainGracePeriod: Duration.zero),
      };
      final runner = WorkflowCliRunner(
        providers: {provider: WorkflowCliProviderConfig(executable: provider)},
        providerImpls: <String, CliProvider>{provider: implementation},
        processStarter: (executable, arguments, {workingDirectory, environment}) async {
          process = _CloseFailsAfterKillProcess(stdoutController: stdoutController, stderrController: stderrController);
          return process;
        },
      );

      await runner.cancelInflight(cancelFutureProcesses: true);
      final result = await runner.executeTurn(
        provider: provider,
        prompt: 'Test',
        workingDirectory: Directory.systemTemp.path,
        profileId: 'workspace',
      );

      expect(result.cancelled, isTrue);
      expect(process.killCalled, isTrue);
    });

    test('$provider cancellation settles and retains ownership when exit is unconfirmed', () async {
      final stdoutController = StreamController<List<int>>();
      final stderrController = StreamController<List<int>>();
      addTearDown(stdoutController.close);
      addTearDown(stderrController.close);
      late _CloseFailsAfterKillProcess process;
      final capabilities = PlatformCapabilities(operatingSystem: 'linux');
      final implementation = switch (provider) {
        'claude' => ClaudeCliProvider(
          platformCapabilities: capabilities,
          terminationGracePeriod: Duration.zero,
          outputDrainGracePeriod: Duration.zero,
        ),
        _ => CodexCliProvider(
          platformCapabilities: capabilities,
          terminationGracePeriod: Duration.zero,
          outputDrainGracePeriod: Duration.zero,
        ),
      };
      final runner = WorkflowCliRunner(
        providers: {provider: WorkflowCliProviderConfig(executable: provider)},
        providerImpls: <String, CliProvider>{provider: implementation},
        processStarter: (executable, arguments, {workingDirectory, environment}) async {
          process = _CloseFailsAfterKillProcess(
            stdoutController: stdoutController,
            stderrController: stderrController,
            completeExitOnKill: false,
            waitForKillOnClose: true,
          );
          return process;
        },
      );

      await runner.cancelInflight(cancelFutureProcesses: true);
      final result = await runner.executeTurn(
        provider: provider,
        prompt: 'Test',
        workingDirectory: Directory.systemTemp.path,
        profileId: 'workspace',
      );

      expect(result.cancelled, isTrue);
      expect(process.killSignals, [ProcessSignal.sigterm, ProcessSignal.sigkill]);
      await runner.cancelInflight();
      expect(process.killSignals, [
        ProcessSignal.sigterm,
        ProcessSignal.sigkill,
        ProcessSignal.sigterm,
        ProcessSignal.sigkill,
      ]);
      process.exit(143);
    });

    test('$provider in-flight cancellation releases after confirmed root exit', () async {
      final stdoutController = StreamController<List<int>>();
      final stderrController = StreamController<List<int>>();
      addTearDown(stdoutController.close);
      addTearDown(stderrController.close);
      late FakeProcess process;
      final capabilities = PlatformCapabilities(operatingSystem: 'windows');
      final implementation = switch (provider) {
        'claude' => ClaudeCliProvider(
          platformCapabilities: capabilities,
          terminationGracePeriod: Duration.zero,
          outputDrainGracePeriod: Duration.zero,
        ),
        _ => CodexCliProvider(
          platformCapabilities: capabilities,
          terminationGracePeriod: Duration.zero,
          outputDrainGracePeriod: Duration.zero,
        ),
      };
      final runner = WorkflowCliRunner(
        providers: {provider: WorkflowCliProviderConfig(executable: provider)},
        providerImpls: <String, CliProvider>{provider: implementation},
        processStarter: (executable, arguments, {workingDirectory, environment}) async {
          process = FakeProcess(
            pid: 2147483647,
            stdoutController: stdoutController,
            stderrController: stderrController,
            completeExitOnKill: true,
            closeStreamsOnExit: false,
          );
          return process;
        },
      );

      final turn = runner.executeTurn(
        provider: provider,
        prompt: 'Test',
        workingDirectory: Directory.systemTemp.path,
        profileId: 'workspace',
      );
      await pumpEventQueue();

      await runner.cancelInflight();
      final result = await turn;

      expect(result.cancelled, isTrue);
      expect(process.killSignals, [ProcessSignal.sigterm]);
      expect(implementation.cancellationRequestedFor(process), isFalse);
      await runner.cancelInflight();
      expect(process.killSignals, [ProcessSignal.sigterm]);
    });
  }
}

final class _AcceptedTreeProvider extends ProcessBackedCliProvider {
  _AcceptedTreeProvider()
    : super(
        platformCapabilities: PlatformCapabilities(operatingSystem: 'windows'),
        terminationGracePeriod: Duration.zero,
      );

  @override
  Future<ProcessTerminationResult> terminateInflightProcess(Process process) async => const ProcessTerminationResult(
    initialTerminationAccepted: true,
    exitConfirmed: false,
    hardTerminationUsed: true,
    processTreeTerminationAccepted: true,
  );

  @override
  Future<WorkflowCliTurnResult> run(CliTurnRequest request) => throw UnimplementedError();
}

final class _CloseFailsAfterKillProcess extends FakeProcess {
  _CloseFailsAfterKillProcess({
    required super.stdoutController,
    required super.stderrController,
    super.completeExitOnKill = true,
    this.waitForKillOnClose = false,
  }) : super(killExitCode: 143, closeStreamsOnExit: false);

  final bool waitForKillOnClose;
  final Completer<void> _killed = Completer<void>();
  late final IOSink _stdin = _CloseFailsAfterKillSink(
    () => killCalled,
    killed: _killed.future,
    waitForKill: waitForKillOnClose,
  );

  @override
  IOSink get stdin => _stdin;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    final result = super.kill(signal);
    if (!_killed.isCompleted) _killed.complete();
    return result;
  }
}

final class _CloseFailsAfterKillSink extends NullIoSink {
  _CloseFailsAfterKillSink(this._isKilled, {required this.killed, required this.waitForKill});

  final bool Function() _isKilled;
  final Future<void> killed;
  final bool waitForKill;

  @override
  Future<void> close() async {
    if (waitForKill && !_isKilled()) await killed;
    if (_isKilled()) throw StateError('stdin close failed after kill');
    await super.close();
  }
}

List<Map<String, dynamic>> _eventsFor(String provider) => switch (provider) {
  'claude' => [
    {'type': 'system', 'subtype': 'init', 'session_id': 'claude-session'},
    {'type': 'result', 'session_id': 'claude-session', 'result': 'done'},
  ],
  _ => [
    {'type': 'thread.started', 'thread_id': 'codex-thread'},
    {
      'type': 'item.completed',
      'item': {'id': 'message', 'type': 'agent_message', 'text': 'done'},
    },
    {
      'type': 'turn.completed',
      'usage': {'input_tokens': 1, 'output_tokens': 1},
    },
  ],
};
