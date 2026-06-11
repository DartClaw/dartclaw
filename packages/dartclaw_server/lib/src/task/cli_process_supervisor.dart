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

  final Completer<WorkflowCliException> _failure = Completer<WorkflowCliException>();
  Future<void>? _termination;
  Timer? _timeoutTimer;
  TurnProgressMonitor? _stallMonitor;

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
    _termination = terminateCliProcess(process, grace: terminationGrace);
    _completeFailure(failure);
  }
}

Future<void> terminateCliProcess(Process process, {Duration grace = const Duration(seconds: 5)}) =>
    killWithEscalation(process, label: 'workflow CLI', gracePeriod: grace);
