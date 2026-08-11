import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' show ContainerExecutor, EventBus;

import '../container/container_authority.dart';
import '../container/gateway/gateway_models.dart';
import 'package:dartclaw_config/dartclaw_config.dart' show ExecutionPolicy, ProviderIdentity, TurnProgressAction;
import 'package:dartclaw_security/dartclaw_security.dart';
import 'package:logging/logging.dart';
import 'package:meta/meta.dart';
import 'package:uuid/uuid.dart';

import 'cli_provider.dart';
import 'claude_cli_provider.dart';
import 'codex_cli_provider.dart';

export 'cli_provider.dart'
    show
        CliProvider,
        CliTurnRequest,
        ProcessBackedCliProvider,
        RootProcessTerminationObserver,
        StructuredTurnLimitProvider,
        WorkflowCliUsageBaseline;

/// Starts a CLI provider subprocess and returns the long-lived [Process].
typedef WorkflowCliProcessStarter =
    Future<Process> Function(
      String executable,
      List<String> arguments, {
      String? workingDirectory,
      Map<String, String>? environment,
    });

/// YAML-decoded provider configuration for workflow one-shot execution.
///
/// The [options] map is intentionally untyped because it mirrors authored
/// workflow/provider YAML directly; callers must normalize individual keys
/// before using them.
class WorkflowCliProviderConfig {
  final String executable;
  final Map<String, String> environment;
  final Map<String, dynamic> options;

  const WorkflowCliProviderConfig({
    required this.executable,
    this.environment = const <String, String>{},
    this.options = const <String, dynamic>{},
  });
}

/// Base class for workflow CLI subprocess failures.
sealed class WorkflowCliException implements Exception {
  /// Workflow step name associated with the failed subprocess, if known.
  final String? stepName;

  const WorkflowCliException({required this.stepName});
}

/// Raised when a workflow CLI subprocess is silent for longer than configured.
final class WorkflowCliStallException extends WorkflowCliException {
  /// Configured silent duration that triggered the stall.
  final Duration silentDuration;

  const WorkflowCliStallException({required super.stepName, required this.silentDuration});

  @override
  String toString() =>
      'WorkflowCliStallException(stepName: ${stepName ?? '<unknown>'}, silentDuration: $silentDuration)';
}

/// Raised when a workflow CLI subprocess exceeds its wall-clock timeout.
final class WorkflowCliTimeoutException extends WorkflowCliException {
  /// Configured wall-clock timeout.
  final Duration configuredTimeout;

  const WorkflowCliTimeoutException({required super.stepName, required this.configuredTimeout});

  @override
  String toString() =>
      'WorkflowCliTimeoutException(stepName: ${stepName ?? '<unknown>'}, configuredTimeout: $configuredTimeout)';
}

/// Raised when a workflow CLI subprocess exceeds its bounded output allowance.
final class WorkflowCliOutputLimitException extends WorkflowCliException {
  /// Provider whose subprocess exceeded the limit.
  final String provider;

  /// Output stream that exceeded the limit.
  final String streamName;

  /// Maximum accepted bytes for the stream.
  final int maxBytes;

  const WorkflowCliOutputLimitException({
    required super.stepName,
    required this.provider,
    required this.streamName,
    required this.maxBytes,
  });

  @override
  String toString() =>
      'WorkflowCliOutputLimitException(provider: $provider, stepName: ${stepName ?? '<unknown>'}, '
      'stream: $streamName, maxBytes: $maxBytes)';
}

/// Captures provider telemetry and decoded output from a single CLI turn.
class WorkflowCliTurnResult {
  /// Provider-owned conversation/session identifier returned by the CLI.
  final String providerSessionId;

  /// Raw assistant text returned by the provider after protocol parsing.
  final String responseText;

  /// Provider-enforced structured payload, when available.
  final Map<String, dynamic>? structuredOutput;

  /// Total input tokens reported by the provider for the turn.
  final int inputTokens;

  /// Total output tokens reported by the provider for the turn.
  final int outputTokens;

  /// Cache-read tokens reported by the provider for the turn.
  final int cacheReadTokens;

  /// Cache-write tokens reported by the provider for the turn.
  final int cacheWriteTokens;

  /// Fresh input tokens derived from provider telemetry normalization.
  final int newInputTokens;

  /// Reported cost, when the provider exposes it.
  final double? totalCostUsd;

  /// End-to-end turn duration, including process startup and parsing.
  final Duration duration;

  /// Whether the provider process was intentionally cancelled during teardown.
  final bool cancelled;

  WorkflowCliTurnResult({
    required this.providerSessionId,
    required this.responseText,
    this.structuredOutput,
    this.inputTokens = 0,
    this.outputTokens = 0,
    this.cacheReadTokens = 0,
    this.cacheWriteTokens = 0,
    required this.newInputTokens,
    this.totalCostUsd,
    this.duration = Duration.zero,
    this.cancelled = false,
  });

  WorkflowCliTurnResult.cancelled({this.duration = Duration.zero})
    : providerSessionId = '',
      responseText = '',
      structuredOutput = null,
      inputTokens = 0,
      outputTokens = 0,
      cacheReadTokens = 0,
      cacheWriteTokens = 0,
      newInputTokens = 0,
      totalCostUsd = null,
      cancelled = true;
}

/// Drives a CLI provider subprocess to execute one or more workflow turns.
///
/// Adding a new provider requires only a new [CliProvider] implementation –
/// no edits to this class. Register it by passing [providerImpls] to the
/// constructor alongside the corresponding [WorkflowCliProviderConfig] entry
/// in [providers].
class WorkflowCliRunner {
  final Map<String, WorkflowCliProviderConfig> providers;

  /// Leases a dedicated container authority for one container-policy turn.
  ///
  /// `null` in host-only deployments; a container policy then fails rather
  /// than silently running on the host.
  final ContainerAuthorityProvider? containerAuthorities;
  final EventBus? _eventBus;
  final WorkflowCliProcessStarter _processStarter;
  final Uuid _uuid;
  final Map<String, CliProvider> _providerImpls;

  /// Leases the container backing [policy], or `null` for host execution.
  ///
  /// Each one-shot turn gets its own authority, so two concurrent workflow
  /// steps never share a container, a bridge, or generated state.
  Future<ContainerAuthorityLease?> _leaseContainer(
    ExecutionPolicy policy, {
    required String provider,
    required String? sessionId,
    required String? taskId,
  }) async {
    if (!policy.isContainer) return null;
    final acquire = containerAuthorities;
    if (acquire == null) {
      throw StateError(
        'Workflow one-shot requires container profile "${policy.containerProfile}", but this deployment has no '
        'container mediation. Enable container.enabled: true or select host execution for this task type.',
      );
    }
    return acquire(
      GatewayPrincipal(
        sessionId: sessionId ?? taskId ?? 'workflow-one-shot',
        providerId: provider,
        policy: policy,
        taskId: taskId,
      ),
    );
  }

  WorkflowCliRunner({
    required this.providers,
    this.containerAuthorities,
    EventBus? eventBus,
    WorkflowCliProcessStarter? processStarter,
    Uuid? uuid,
    Map<String, CliProvider>? providerImpls,
  }) : _processStarter = processStarter ?? _defaultProcessStarter,
       _eventBus = eventBus,
       _uuid = uuid ?? const Uuid(),
       _providerImpls = providerImpls ?? {'claude': ClaudeCliProvider(), 'codex': CodexCliProvider()};

  int? maxTurnsForStructuredTurn({required String provider, required bool noTools}) {
    final providerConfig = providers[provider];
    if (providerConfig == null) {
      throw StateError('No workflow CLI provider config for "$provider"');
    }
    final providerFamily = ProviderIdentity.resolveFamily(
      provider,
      options: providerConfig.options,
      executable: providerConfig.executable,
    );
    final impl = _providerImpls[providerFamily];
    if (impl == null) {
      throw UnsupportedError(
        'Workflow one-shot CLI is not implemented for provider "$provider" (family "$providerFamily")',
      );
    }
    if (impl is! StructuredTurnLimitProvider) return null;
    return (impl as StructuredTurnLimitProvider).maxTurnsForStructuredTurn(noTools: noTools);
  }

  @visibleForTesting
  (String, List<String>) buildCodexCommandForTesting({
    required String prompt,
    String? providerSessionId,
    String? model,
    String? effort,
    Map<String, dynamic>? jsonSchema,
    required String schemaDirectory,
    ContainerExecutor? containerManager,
    String? appendSystemPrompt,
    String? sandboxOverride,
  }) {
    return (_providerImpls['codex'] as CodexCliProvider).buildCommandForTesting(
      prompt: prompt,
      providerSessionId: providerSessionId,
      model: model,
      effort: effort,
      jsonSchema: jsonSchema,
      schemaDirectory: schemaDirectory,
      providerConfig: providers['codex'] ?? const WorkflowCliProviderConfig(executable: 'codex'),
      appendSystemPrompt: appendSystemPrompt,
      sandboxOverride: sandboxOverride,
    );
  }

  /// Executes a one-shot turn for [provider].
  ///
  /// Dispatches to the registered [CliProvider] implementation for [provider].
  /// Throws [StateError] when no provider config is registered for [provider],
  /// and [UnsupportedError] when a config exists but no implementation is
  /// registered.
  Future<WorkflowCliTurnResult> executeTurn({
    required String provider,
    required String prompt,
    required String workingDirectory,
    required ExecutionPolicy policy,
    String? taskId,
    String? sessionId,
    String? providerSessionId,
    String? model,
    String? effort,
    String? stepName,
    Duration stallTimeout = Duration.zero,
    TurnProgressAction stallAction = TurnProgressAction.warn,
    Duration? stepTimeout,
    List<String>? allowedTools,
    bool readOnly = false,
    int? maxTurns,
    RootProcessTerminationObserver? onRootProcessTerminationConfirmed,
    Map<String, dynamic>? jsonSchema,
    String? appendSystemPrompt,
    String? sandboxOverride,
    Map<String, String>? extraEnvironment,
    WorkflowCliUsageBaseline usageBaseline = const WorkflowCliUsageBaseline(),
  }) async {
    final providerConfig = providers[provider];
    if (providerConfig == null) {
      throw StateError('No workflow CLI provider config for "$provider"');
    }
    final providerFamily = ProviderIdentity.resolveFamily(
      provider,
      options: providerConfig.options,
      executable: providerConfig.executable,
    );
    final impl = _providerImpls[providerFamily];
    if (impl == null) {
      throw UnsupportedError(
        'Workflow one-shot CLI is not implemented for provider "$provider" (family "$providerFamily")',
      );
    }
    var rootProcessTerminationReported = false;
    final observer = onRootProcessTerminationConfirmed;
    final lease = await _leaseContainer(policy, provider: provider, sessionId: sessionId, taskId: taskId);
    try {
      final req = CliTurnRequest(
        prompt: prompt,
        workingDirectory: workingDirectory,
        policy: policy,
        taskId: taskId,
        sessionId: sessionId,
        providerSessionId: providerSessionId,
        model: model,
        effort: effort,
        stepName: stepName,
        stallTimeout: stallTimeout,
        stallAction: stallAction,
        stepTimeout: stepTimeout,
        allowedTools: allowedTools,
        readOnly: readOnly,
        maxTurns: maxTurns,
        onRootProcessTerminationConfirmed: observer == null
            ? null
            : (confirmed) async {
                rootProcessTerminationReported = true;
                await observer(confirmed);
              },
        jsonSchema: jsonSchema,
        appendSystemPrompt: appendSystemPrompt,
        sandboxOverride: sandboxOverride,
        extraEnvironment: extraEnvironment,
        usageBaseline: usageBaseline,
        providerConfig: providerConfig,
        containerManager: lease?.container,
        processStarter: _processStarter,
        eventBus: _eventBus,
        uuid: _uuid,
        log: Logger('WorkflowCliRunner'),
      );
      return await impl.run(req);
    } finally {
      if (observer != null && !rootProcessTerminationReported) await observer(false);
      // The authority outlives nothing: the container and its bridges go away
      // with the turn, on success and failure alike.
      await lease?.release();
    }
  }

  /// Requests cancellation of all in-flight CLI subprocesses.
  Future<void> cancelInflight({bool cancelFutureProcesses = false}) async {
    await Future.wait(
      _providerImpls.values.map((provider) => provider.cancelInflight(cancelFutureProcesses: cancelFutureProcesses)),
      eagerError: false,
    );
  }

  static Future<Process> _defaultProcessStarter(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
  }) {
    return SafeProcess.start(
      executable,
      arguments,
      env: EnvPolicy.passthrough(environment: environment ?? const <String, String>{}),
      workingDirectory: workingDirectory,
      runInShell: false,
    );
  }
}
