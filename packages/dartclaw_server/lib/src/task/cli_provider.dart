import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' show ContainerExecutor, EventBus;
import 'package:dartclaw_config/dartclaw_config.dart' show TurnProgressAction;
import 'package:logging/logging.dart';
import 'package:uuid/uuid.dart';

import 'cli_process_supervisor.dart';
import 'workflow_cli_runner.dart';

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
  final Set<Process> _inflight = <Process>{};
  final Set<Process> _cancelling = <Process>{};
  bool _cancelFutureProcesses = false;

  /// Marks [process] as owned by this provider until [untrackInflightProcess].
  void trackInflightProcess(Process process) {
    _cancelling.remove(process);
    _inflight.add(process);
  }

  /// Starts teardown for [process] when [cancelInflight] already requested future process cancellation.
  void cancelFutureStartedProcessIfRequested(Process process) {
    if (_cancelFutureProcesses) {
      unawaited(_cancelInflightProcess(process));
    }
  }

  /// Stops tracking [process] after its run has settled.
  void untrackInflightProcess(Process process) {
    _inflight.remove(process);
    _cancelling.remove(process);
  }

  /// Whether [process] is exiting because [cancelInflight] requested teardown.
  bool cancellationRequestedFor(Process? process) => process != null && _cancelling.contains(process);

  /// Returns a cancellation result when a non-zero exit came from teardown before a terminal result.
  WorkflowCliTurnResult? cancellationResultForNonZeroExit({
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
  /// Any non-empty line that does not contain one of [benignFragments] counts
  /// as failure evidence, so a provider/auth/runtime error emitted only on
  /// stderr before teardown is not silently reclassified as a cancellation.
  bool hasNonBenignStderr(String stderr, List<String> benignFragments) {
    for (final line in const LineSplitter().convert(stderr)) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      if (benignFragments.any(trimmed.contains)) continue;
      return true;
    }
    return false;
  }

  @override
  Future<void> cancelInflight({bool cancelFutureProcesses = false}) async {
    _cancelFutureProcesses = _cancelFutureProcesses || cancelFutureProcesses;
    final processes = List<Process>.from(_inflight);
    await Future.wait(processes.map(_cancelInflightProcess), eagerError: false);
    _inflight.removeAll(processes);
  }

  Future<void> _cancelInflightProcess(Process process) async {
    final signalSent = process.kill();
    if (signalSent) {
      _cancelling.add(process);
    }
    await terminateCliProcess(process, alreadySignalled: true);
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
