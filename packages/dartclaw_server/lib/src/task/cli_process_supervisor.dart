import 'dart:async';
import 'dart:io';

import 'package:dartclaw_config/dartclaw_config.dart' show TurnProgressAction;
import 'package:dartclaw_core/dartclaw_core.dart' show EventBus, WorkflowCliStallEvent, killWithEscalation;
import 'package:logging/logging.dart';

import '../turn_progress_monitor.dart';
import 'workflow_cli_runner.dart';

final class CliProcessSupervisor {
  CliProcessSupervisor({
    required this.process,
    required this.provider,
    required this.stepName,
    required this.stallTimeout,
    required this.stallAction,
    required this.stepTimeout,
    required this.eventBus,
    required this.log,
    this.terminationGrace = const Duration(seconds: 5),
    this.postTerminalResultGrace = const Duration(seconds: 10),
  });

  final Process process;
  final String provider;
  final String? stepName;
  final Duration stallTimeout;
  final TurnProgressAction stallAction;
  final Duration? stepTimeout;
  final EventBus? eventBus;
  final Logger log;
  final Duration terminationGrace;
  final Duration postTerminalResultGrace;

  final Completer<WorkflowCliException> _failure = Completer<WorkflowCliException>();
  Future<void>? _termination;
  Timer? _timeoutTimer;
  Timer? _postTerminalResultTimer;
  TurnProgressMonitor? _stallMonitor;
  bool _terminalResultRecorded = false;
  bool _postTerminalResultTerminationStarted = false;

  bool get postTerminalResultTerminationStarted => _postTerminalResultTerminationStarted;

  bool get terminalResultRecorded => _terminalResultRecorded;

  void start() {
    if (stallTimeout > Duration.zero) {
      _stallMonitor = TurnProgressMonitor(
        stallTimeout: stallTimeout,
        onStall: (duration) {
          eventBus?.fire(
            WorkflowCliStallEvent(
              provider: provider,
              stepName: stepName ?? '',
              silentDuration: duration,
              action: stallAction.name,
              timestamp: DateTime.now(),
            ),
          );
          switch (stallAction) {
            case TurnProgressAction.warn:
              log.warning('Workflow CLI $provider step "${stepName ?? '<unknown>'}" stalled for $duration');
              _stallMonitor?.recordProgress();
            case TurnProgressAction.cancel:
              _failAndTerminate(WorkflowCliStallException(stepName: stepName, silentDuration: duration));
            case TurnProgressAction.ignore:
              _stallMonitor?.recordProgress();
          }
        },
      )..start();
    }
    final timeout = stepTimeout;
    if (timeout != null && timeout > Duration.zero) {
      _timeoutTimer = Timer(timeout, () {
        _failAndTerminate(WorkflowCliTimeoutException(stepName: stepName, configuredTimeout: timeout));
      });
    }
  }

  void recordParsedOutput() {
    _stallMonitor?.recordProgress();
  }

  void recordTerminalResult() {
    if (_terminalResultRecorded) return;
    _terminalResultRecorded = true;
    recordParsedOutput();
    _stallMonitor?.stop();
    _stallMonitor = null;
    _timeoutTimer?.cancel();
    _timeoutTimer = null;
    if (postTerminalResultGrace <= Duration.zero) {
      _terminateAfterTerminalResult();
      return;
    }
    _postTerminalResultTimer = Timer(postTerminalResultGrace, _terminateAfterTerminalResult);
  }

  Future<int> waitForExitCode() async {
    final exitCode = process.exitCode.then<Object>((code) => code);
    final result = await Future.any<Object>([exitCode, _failure.future]);
    if (result is WorkflowCliException) {
      await (_termination ?? Future<void>.value());
      throw result;
    }
    if (_failure.isCompleted) {
      final failure = await _failure.future;
      await (_termination ?? Future<void>.value());
      throw failure;
    }
    return result as int;
  }

  void stop() {
    _timeoutTimer?.cancel();
    _timeoutTimer = null;
    _postTerminalResultTimer?.cancel();
    _postTerminalResultTimer = null;
    _stallMonitor?.stop();
    _stallMonitor = null;
  }

  void _completeFailure(WorkflowCliException failure) {
    if (!_failure.isCompleted) {
      _failure.complete(failure);
    }
  }

  void _failAndTerminate(WorkflowCliException failure) {
    if (_failure.isCompleted) return;
    _postTerminalResultTimer?.cancel();
    _postTerminalResultTimer = null;
    _termination = terminateCliProcess(process, grace: terminationGrace);
    _completeFailure(failure);
  }

  void _terminateAfterTerminalResult() {
    if (_failure.isCompleted || _postTerminalResultTerminationStarted) return;
    _postTerminalResultTerminationStarted = true;
    _termination = terminateCliProcess(process, grace: terminationGrace);
  }
}

Future<bool> terminateCliProcess(
  Process process, {
  Duration grace = const Duration(seconds: 5),
  bool alreadySignalled = false,
}) => killWithEscalation(process, label: 'workflow CLI', gracePeriod: grace, alreadySignalled: alreadySignalled);
