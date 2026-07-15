import 'dart:async';
import 'dart:io';

import 'package:dartclaw_config/dartclaw_config.dart' show PlatformCapabilities, TurnProgressAction;
import 'package:dartclaw_core/dartclaw_core.dart'
    show EventBus, ProcessTerminationResult, WorkflowCliStallEvent, killWithEscalation;
import 'package:logging/logging.dart';

import '../turn_progress_monitor.dart';
import 'workflow_cli_runner.dart';

final _processLifecycleLog = Logger('WorkflowCliProcess');

final class CliProcessSupervisor {
  static const defaultOutputLimitBytes = 16 * 1024 * 1024;

  CliProcessSupervisor({
    required this.process,
    required this.provider,
    required this.stepName,
    required this.stallTimeout,
    required this.stallAction,
    required this.stepTimeout,
    required this.eventBus,
    required this.log,
    this.processTerminator,
    this.externalCancellation,
    PlatformCapabilities? platformCapabilities,
    this.terminationGrace = const Duration(seconds: 5),
    this.postTerminalResultGrace = const Duration(seconds: 10),
    this.outputDrainGrace = const Duration(seconds: 2),
    this.maxOutputBytes = defaultOutputLimitBytes,
  }) : assert(maxOutputBytes > 0),
       platformCapabilities = platformCapabilities ?? PlatformCapabilities();

  final Process process;
  final String provider;
  final String? stepName;
  final Duration stallTimeout;
  final TurnProgressAction stallAction;
  final Duration? stepTimeout;
  final EventBus? eventBus;
  final Logger log;
  final Future<ProcessTerminationResult> Function()? processTerminator;
  final Future<ProcessTerminationResult>? externalCancellation;
  final PlatformCapabilities platformCapabilities;
  final Duration terminationGrace;
  final Duration postTerminalResultGrace;
  final Duration outputDrainGrace;
  final int maxOutputBytes;

  final Completer<WorkflowCliException> _failure = Completer<WorkflowCliException>();
  final Completer<void> _postTerminalResultCleanup = Completer<void>();
  Future<ProcessTerminationResult>? _termination;
  Timer? _timeoutTimer;
  Timer? _postTerminalResultTimer;
  TurnProgressMonitor? _stallMonitor;
  bool _terminalResultRecorded = false;
  bool _postTerminalResultTerminationStarted = false;
  bool _postTerminalResultExitUnconfirmed = false;
  bool _externalCancellationExitUnconfirmed = false;

  bool get postTerminalResultTerminationStarted => _postTerminalResultTerminationStarted;

  bool get terminalResultRecorded => _terminalResultRecorded;

  bool get postTerminalResultExitUnconfirmed => _postTerminalResultExitUnconfirmed;

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

  Stream<List<int>> limitOutput(Stream<List<int>> output, {required String streamName}) {
    var receivedBytes = 0;
    return output.transform(
      StreamTransformer<List<int>, List<int>>.fromHandlers(
        handleData: (chunk, sink) {
          if (chunk.length > maxOutputBytes - receivedBytes) {
            _failAndTerminate(
              WorkflowCliOutputLimitException(
                stepName: stepName,
                provider: provider,
                streamName: streamName,
                maxBytes: maxOutputBytes,
              ),
            );
            sink.close();
            return;
          }
          receivedBytes += chunk.length;
          sink.add(chunk);
        },
      ),
    );
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
    final terminalCleanup = _postTerminalResultCleanup.future.then<Object>((_) => 0);
    final waits = <Future<Object>>[exitCode, _failure.future, terminalCleanup];
    final cancellation = externalCancellation;
    if (cancellation != null) {
      waits.add(cancellation.then<Object>((result) => result));
    }
    final result = await Future.any<Object>(waits);
    if (result is WorkflowCliException) {
      await (_termination ?? Future<void>.value());
      throw result;
    }
    if (_failure.isCompleted) {
      final failure = await _failure.future;
      await (_termination ?? Future<void>.value());
      throw failure;
    }
    if (result is ProcessTerminationResult) {
      if (result.exitConfirmed) return process.exitCode;
      _externalCancellationExitUnconfirmed = true;
      return -1;
    }
    return result as int;
  }

  Future<void> waitForOutputDrain({
    required Future<void> stdoutDone,
    required Future<void> stderrDone,
    required Future<void> Function() cancelSubscriptions,
  }) async {
    if (_postTerminalResultExitUnconfirmed || _externalCancellationExitUnconfirmed) {
      await cancelSubscriptions();
      return;
    }
    try {
      await Future.wait([stdoutDone, stderrDone]).timeout(outputDrainGrace);
    } on TimeoutException {
      log.warning('Workflow CLI $provider output remained open after root exit; cancelling stream readers');
      await cancelSubscriptions();
    }
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
    _termination = _terminateProcess();
    _completeFailure(failure);
  }

  void _terminateAfterTerminalResult() {
    if (_failure.isCompleted || _postTerminalResultTerminationStarted) return;
    _postTerminalResultTerminationStarted = true;
    final termination = _terminateProcess();
    _termination = termination;
    unawaited(
      termination.then<void>(
        (result) {
          if (!result.exitConfirmed) {
            _postTerminalResultExitUnconfirmed = true;
            log.warning('Workflow CLI $provider process exit remains unconfirmed after a terminal result');
          }
          if (!_postTerminalResultCleanup.isCompleted) _postTerminalResultCleanup.complete();
        },
        onError: (Object error, StackTrace stackTrace) {
          _postTerminalResultExitUnconfirmed = true;
          log.warning('Workflow CLI $provider post-result cleanup failed', error, stackTrace);
          if (!_postTerminalResultCleanup.isCompleted) _postTerminalResultCleanup.complete();
        },
      ),
    );
  }

  Future<ProcessTerminationResult> _terminateProcess() async {
    final terminator = processTerminator;
    if (terminator != null) return terminator();
    return terminateCliProcess(process, grace: terminationGrace, log: log, platformCapabilities: platformCapabilities);
  }
}

Future<ProcessTerminationResult> terminateCliProcess(
  Process process, {
  Duration grace = const Duration(seconds: 5),
  bool? initialTerminationAccepted,
  Logger? log,
  PlatformCapabilities? platformCapabilities,
}) => killWithEscalation(
  process,
  label: 'workflow CLI',
  gracePeriod: grace,
  initialTerminationAccepted: initialTerminationAccepted,
  log: log ?? _processLifecycleLog,
  platformCapabilities: platformCapabilities,
);
