import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' show ContainerExecutor, EventBus, ProcessTerminationResult;
import 'package:dartclaw_config/dartclaw_config.dart' show PlatformCapabilities, TurnProgressAction;
import 'package:logging/logging.dart';
import 'package:uuid/uuid.dart';

import 'cli_process_supervisor.dart';
import 'workflow_cli_runner.dart';

final _log = Logger('ProcessBackedCliProvider');

/// Abstraction for a single-turn CLI provider invocation.
///
/// Each concrete implementation owns its command construction, stdout/stderr
/// parsing, and any temp-file lifecycle for the provider it wraps.
abstract class CliProvider {
  /// Runs a one-shot turn described by [request] and returns the parsed result.
  Future<WorkflowCliTurnResult> run(CliTurnRequest request);

  /// Requests termination of any subprocesses currently owned by this provider.
  Future<void> cancelInflight({bool cancelFutureProcesses = false});
}

/// Shared process ownership for CLI providers backed by one-shot subprocesses.
abstract class ProcessBackedCliProvider implements CliProvider {
  ProcessBackedCliProvider({
    PlatformCapabilities? platformCapabilities,
    this.terminationGracePeriod = const Duration(seconds: 5),
    this.outputDrainGracePeriod = const Duration(seconds: 2),
  }) : platformCapabilities = platformCapabilities ?? PlatformCapabilities();

  /// Shared across every teardown path so platform policy cannot diverge mid-run.
  final PlatformCapabilities platformCapabilities;

  /// Bounds POSIX cooperative shutdown; Windows hard-terminates the managed root.
  final Duration terminationGracePeriod;

  /// Bounds output draining after the root process exits.
  final Duration outputDrainGracePeriod;

  final Set<Process> _inflight = <Process>{};
  final Set<Process> _cancelling = <Process>{};
  final Set<Process> _finishedRuns = <Process>{};
  final Map<Process, Future<ProcessTerminationResult>> _terminations = <Process, Future<ProcessTerminationResult>>{};
  final Map<Process, ProcessTerminationResult> _terminationResults = <Process, ProcessTerminationResult>{};
  final Map<Process, Completer<ProcessTerminationResult>> _cancellationSignals =
      <Process, Completer<ProcessTerminationResult>>{};
  final Set<Process> _windowsTeardownPending = <Process>{};
  final Set<Process> _windowsExitObservedDuringTeardown = <Process>{};
  bool _cancelFutureProcesses = false;

  /// Marks [process] as owned by this provider until its exit is observed.
  void trackInflightProcess(Process process) {
    _cancelling.remove(process);
    _finishedRuns.remove(process);
    _windowsTeardownPending.remove(process);
    _windowsExitObservedDuringTeardown.remove(process);
    _inflight.add(process);
    _cancellationSignals[process] = Completer<ProcessTerminationResult>();
    unawaited(
      process.exitCode.then<void>(
        (_) {
          if (_windowsTeardownPending.contains(process)) {
            _windowsExitObservedDuringTeardown.add(process);
          } else {
            _releaseInflightProcess(process);
          }
        },
        onError: (Object error, StackTrace stackTrace) {
          _log.warning('Failed to observe workflow CLI process exit', error, stackTrace);
        },
      ),
    );
  }

  /// Starts teardown for [process] when [cancelInflight] already requested future process cancellation.
  void cancelFutureStartedProcessIfRequested(Process process) {
    if (_cancelFutureProcesses) {
      unawaited(_cancelInflightProcess(process));
    }
  }

  /// Clears run-scoped cancellation state without releasing process ownership.
  void finishInflightRun(Process process) {
    if (_inflight.contains(process) && _cancelling.contains(process)) {
      _finishedRuns.add(process);
    } else {
      _finishedRuns.remove(process);
      _cancelling.remove(process);
    }
  }

  /// Whether [process] is exiting because [cancelInflight] requested teardown.
  bool cancellationRequestedFor(Process? process) => process != null && _cancelling.contains(process);

  Future<ProcessTerminationResult> inflightCancellation(Process process) {
    final signal = _cancellationSignals[process];
    if (signal == null) {
      throw StateError('Workflow CLI process is not tracked');
    }
    return signal.future;
  }

  /// Returns a cancellation result when teardown won before a terminal result.
  WorkflowCliTurnResult? cancellationResultForExit({
    required Process? process,
    required CliProcessSupervisor supervisor,
    required Duration duration,
    required bool hasProviderFailureEvidence,
  }) {
    if (hasProviderFailureEvidence) return null;
    if (supervisor.postTerminalResultTerminationStarted) return null;
    if (!cancellationRequestedFor(process)) return null;
    if (supervisor.terminalResultRecorded) return null;
    return WorkflowCliTurnResult.cancelled(duration: duration);
  }

  /// Whether a non-zero exit should still surface as the provider diagnostic failure.
  bool shouldThrowForNonZeroExit(Process? process, CliProcessSupervisor supervisor) {
    return !supervisor.postTerminalResultTerminationStarted && !cancellationRequestedFor(process);
  }

  /// Whether [stderr] carries genuine provider-failure output.
  ///
  /// Any non-empty line that does not exactly match one of [benignLines] counts
  /// as failure evidence, so a provider/auth/runtime error emitted only on
  /// stderr before teardown is not silently reclassified as a cancellation.
  bool hasNonBenignStderr(String stderr, List<String> benignLines) {
    for (final line in const LineSplitter().convert(stderr)) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      if (benignLines.contains(trimmed)) continue;
      return true;
    }
    return false;
  }

  /// Drains provider output within the supervisor bound and cancels inherited readers on expiry.
  Future<void> waitForCliOutputDrain({
    required CliProcessSupervisor supervisor,
    required Future<void> stdoutDone,
    required Future<void> stderrDone,
    required Future<void> Function() cancelSubscriptions,
  }) => supervisor.waitForOutputDrain(
    stdoutDone: stdoutDone,
    stderrDone: stderrDone,
    cancelSubscriptions: cancelSubscriptions,
  );

  @override
  Future<void> cancelInflight({bool cancelFutureProcesses = false}) async {
    _cancelFutureProcesses = _cancelFutureProcesses || cancelFutureProcesses;
    final processes = List<Process>.from(_inflight);
    await Future.wait(processes.map(_cancelInflightProcess), eagerError: false);
  }

  Future<void> _cancelInflightProcess(Process process) async {
    if (!_inflight.contains(process)) return;
    final windowsTeardown = !platformCapabilities.posixSignalsAvailable;
    if (windowsTeardown) {
      _cancelling.add(process);
      _windowsTeardownPending.add(process);
    }
    try {
      await process.exitCode.timeout(Duration.zero);
      if (!windowsTeardown) {
        _releaseInflightProcess(process);
        return;
      }
    } on TimeoutException {
      // Still running.
    } catch (error, stackTrace) {
      _log.warning('Failed to observe workflow CLI process exit before cancellation', error, stackTrace);
    }
    _cancelling.add(process);
    final result = await terminateInflightProcess(process);
    final cancellationSignal = _cancellationSignals[process];
    if (cancellationSignal != null && !cancellationSignal.isCompleted) {
      cancellationSignal.complete(result);
    }
    if (windowsTeardown) _windowsTeardownPending.remove(process);
    final exitObserved = _windowsExitObservedDuringTeardown.remove(process);
    if (result.confirmsOwnershipRelease() || exitObserved) {
      _releaseInflightProcess(process);
    }
  }

  void _releaseInflightProcess(Process process) {
    _windowsTeardownPending.remove(process);
    _windowsExitObservedDuringTeardown.remove(process);
    _inflight.remove(process);
    _terminations.remove(process);
    _terminationResults.remove(process);
    _cancellationSignals.remove(process);
    if (_finishedRuns.remove(process)) _cancelling.remove(process);
  }

  /// Coalesces concurrent teardown requests while allowing later retries when exit is unconfirmed.
  Future<ProcessTerminationResult> terminateInflightProcess(Process process) {
    final existing = _terminations[process];
    if (existing != null) return existing;
    final termination = terminateCliProcess(
      process,
      grace: terminationGracePeriod,
      platformCapabilities: platformCapabilities,
    );
    _terminations[process] = termination;
    unawaited(
      termination.then<void>(
        (result) {
          _terminationResults[process] = result;
          if (identical(_terminations[process], termination)) _terminations.remove(process);
        },
        onError: (Object _, StackTrace _) {
          if (identical(_terminations[process], termination)) _terminations.remove(process);
        },
      ),
    );
    return termination;
  }

  /// Returns the current or most recent bounded termination result without starting another attempt.
  Future<ProcessTerminationResult?> waitForInflightTermination(Process process) async {
    final inProgress = _terminations[process];
    if (inProgress != null) return inProgress;
    return _terminationResults[process];
  }
}

final class WorkflowCliUsageBaseline {
  final int inputTokens;
  final int outputTokens;
  final int cacheReadTokens;
  final int cacheWriteTokens;

  const WorkflowCliUsageBaseline({
    this.inputTokens = 0,
    this.outputTokens = 0,
    this.cacheReadTokens = 0,
    this.cacheWriteTokens = 0,
  });
}

/// Value object bundling all per-turn inputs a [CliProvider] implementation needs.
///
/// The runner resolves all fields from [WorkflowCliRunner.executeTurn] parameters
/// and collaborators, then passes a single [CliTurnRequest] to the provider so
/// implementations remain testable in isolation.
final class CliTurnRequest {
  /// The user-authored prompt text to submit to the provider.
  final String prompt;

  /// Host filesystem path used as the process working directory.
  final String workingDirectory;

  /// Profile identifier used to look up the container manager.
  final String profileId;

  /// Task identifier propagated to progress events, if any.
  final String? taskId;

  /// Session identifier propagated to progress events, if any.
  final String? sessionId;

  /// Provider-specific conversation / session identifier for resume.
  final String? providerSessionId;

  /// Model override, when provided by the workflow step.
  final String? model;

  /// Effort level override, when provided by the workflow step.
  final String? effort;

  /// Workflow step name used in timeout and stall diagnostics.
  final String? stepName;

  /// Maximum silent period before the CLI process is considered stalled.
  final Duration stallTimeout;

  /// Action to apply when [stallTimeout] elapses without parsed output.
  final TurnProgressAction stallAction;

  /// Wall-clock timeout for the CLI process.
  final Duration? stepTimeout;

  /// Task-specific tool allowlist carried from workflow step config.
  ///
  /// Enforcement is provider-specific: Claude=permission patterns;
  /// Codex=advisory + sandbox/approval.
  final List<String>? allowedTools;

  /// Whether the workflow step must execute with read-only tool policy.
  ///
  /// Claude maps this to permissions and sandbox settings. Codex maps this to
  /// `--sandbox read-only`.
  final bool readOnly;

  /// Maximum number of agentic turns (Claude-specific).
  final int? maxTurns;

  /// JSON schema for structured output enforcement, if requested.
  final Map<String, dynamic>? jsonSchema;

  /// System-prompt text to append after the provider's built-in prompt.
  final String? appendSystemPrompt;

  /// Sandbox override that takes precedence over the provider config default.
  final String? sandboxOverride;

  /// Additional environment variables merged on top of the provider config env.
  final Map<String, String>? extraEnvironment;

  /// Persisted per-session usage already accounted before this turn.
  final WorkflowCliUsageBaseline usageBaseline;

  /// Decoded YAML provider configuration for this provider.
  final WorkflowCliProviderConfig providerConfig;

  /// Container executor bound to [profileId], or null when running on the host.
  final ContainerExecutor? containerManager;

  /// Process-spawning collaborator; injected so tests can intercept the spawn.
  final WorkflowCliProcessStarter processStarter;

  /// Event bus for emitting progress events, if wired.
  final EventBus? eventBus;

  /// UUID generator; injected for deterministic test scenarios.
  final Uuid uuid;

  /// Logger for the provider implementation.
  final Logger log;

  const CliTurnRequest({
    required this.prompt,
    required this.workingDirectory,
    required this.profileId,
    this.taskId,
    this.sessionId,
    this.providerSessionId,
    this.model,
    this.effort,
    this.stepName,
    this.stallTimeout = Duration.zero,
    this.stallAction = TurnProgressAction.warn,
    this.stepTimeout,
    this.allowedTools,
    this.readOnly = false,
    this.maxTurns,
    this.jsonSchema,
    this.appendSystemPrompt,
    this.sandboxOverride,
    this.extraEnvironment,
    this.usageBaseline = const WorkflowCliUsageBaseline(),
    required this.providerConfig,
    required this.containerManager,
    required this.processStarter,
    this.eventBus,
    required this.uuid,
    required this.log,
  });
}
