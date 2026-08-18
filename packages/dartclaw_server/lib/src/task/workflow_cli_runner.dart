import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart'
    show ContainerExecutor, EventBus, ProviderExecutionInventory, ProviderExecutionVerdict, ProviderLaunchSurface;

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
typedef WorkflowCliProcessStarter = Future<Process> Function(
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

  const new({
    required this.executable,
    this.environment = const <String, String>{},
    this.options = const <String, dynamic>{},
  });
}

/// Base class for workflow CLI subprocess failures.
sealed class WorkflowCliException implements Exception {
  /// Workflow step name associated with the failed subprocess, if known.
  final String? stepName;

  const new({required this.stepName});
}

/// Raised when a workflow CLI subprocess is silent for longer than configured.
final class WorkflowCliStallException extends WorkflowCliException {
  /// Configured silent duration that triggered the stall.
  final Duration silentDuration;

  const new({required super.stepName, required this.silentDuration});

  @override
  String toString() =>
      'WorkflowCliStallException(stepName: ${stepName ?? '<unknown>'}, silentDuration: $silentDuration)';
}

/// Raised when a workflow CLI subprocess exceeds its wall-clock timeout.
final class WorkflowCliTimeoutException extends WorkflowCliException {
  /// Configured wall-clock timeout.
  final Duration configuredTimeout;

  const new({required super.stepName, required this.configuredTimeout});

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

  const new({required super.stepName, required this.provider, required this.streamName, required this.maxBytes});

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

  new({
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

  new cancelled({this.duration = Duration.zero})
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

  /// Leases a dedicated container authority for one workflow step.
  ///
  /// `null` in host-only deployments; a container policy then fails rather
  /// than silently running on the host.
  final ContainerAuthorityProvider? containerAuthorities;

  /// Derives the bridged-MCP grant a containerized step's authority is created
  /// with, from the step's effective tool policy.
  ///
  /// Injected so the single owner (`HarnessWiring`, which holds the global deny
  /// set and the servable tool set) computes the grant — `dartclaw_server`
  /// cannot import `dartclaw_cli`. Required whenever [containerAuthorities] is
  /// set; a container lease then fails closed rather than deriving a divergent,
  /// unguarded grant locally.
  final Set<String> Function(List<String>? allowedTools)? bridgedMcpToolsResolver;
  final EventBus? _eventBus;
  final WorkflowCliProcessStarter _processStarter;
  final Uuid _uuid;
  final Map<String, CliProvider> _providerImpls;

  /// Leases the one container authority backing a whole workflow step, or
  /// `null` for host execution.
  ///
  /// One container per step (the one-shot job), reused across every turn of the
  /// step — the main prompt, follow-ups, the finalizer, and its retry — and
  /// torn down only when the step ends. This is what lets a step's provider
  /// session (`providerSessionId`) resume across turns: the generated-state and
  /// session substrate survive because the container does. The lease is one
  /// trust principal; each [execute] call leases its own, so two concurrent
  /// steps never share a container, a bridge, or generated state.
  ///
  /// A container profile with no [containerAuthorities] fails closed rather than
  /// falling back to host execution.
  Future<ContainerAuthorityLease?> leaseStepContainer(
    ExecutionPolicy policy, {
    required String provider,
    required String? sessionId,
    required String? taskId,
    required List<String>? allowedTools,
    required String? artifactsDir,
  }) async {
    _requireSupported(provider, policy);
    if (!policy.isContainer) return null;
    final acquire = containerAuthorities;
    if (acquire == null) {
      throw StateError(
        'Workflow one-shot requires container profile "${policy.containerProfile}", but this deployment has no '
        'container mediation. Enable container.enabled: true or select host execution for this task type.',
      );
    }
    final resolveGrant = bridgedMcpToolsResolver;
    if (resolveGrant == null) {
      throw StateError(
        'Workflow one-shot has container mediation but no bridged-MCP grant resolver. Wiring must inject one from '
        'HarnessWiring so the deployment-wide deny and servable filter apply.',
      );
    }
    return acquire(
      GatewayPrincipal(
        sessionId: sessionId ?? taskId ?? 'workflow-one-shot',
        providerId: provider,
        policy: policy,
        sourceSessionId: sessionId,
        taskId: taskId,
      ),
      allowedMcpTools: resolveGrant(allowedTools),
      artifactsDir: artifactsDir,
    );
  }

  /// Releases provider state and then the container authority that owns it.
  ///
  /// Authority release is always attempted, even when provider-state cleanup
  /// fails.
  Future<void> releaseStepContainer(String provider, ContainerAuthorityLease lease) async {
    Object? cleanupError;
    StackTrace? cleanupStackTrace;
    final providerConfig = providers[provider];
    if (providerConfig != null) {
      final family = ProviderIdentity.resolveFamily(
        provider,
        options: providerConfig.options,
        executable: providerConfig.executable,
      );
      if (_providerImpls[family] case final CodexCliProvider codex) {
        try {
          await codex.releaseContainerState(lease.container);
        } catch (error, stackTrace) {
          cleanupError = error;
          cleanupStackTrace = stackTrace;
        }
      }
    }
    await lease.release();
    if (cleanupError != null) {
      Error.throwWithStackTrace(cleanupError, cleanupStackTrace!);
    }
  }

  /// Startup-computed launch compatibility, consulted by provider identity
  /// before family resolution.
  ///
  /// Family resolution deliberately aliases an unknown provider onto `claude`
  /// or `codex` when its ID or executable names one, which would route an ACP
  /// registration through a built-in adapter it has nothing to do with. The
  /// verdict is keyed by the configured provider ID, so that aliasing can never
  /// manufacture support this deployment does not have.
  final ProviderExecutionInventory? executionInventory;

  /// Makes the DartClaw-dedicated subscription home usable before a host spawn
  /// and answers its path, or `null` when this deployment presents an API key.
  ///
  /// Receives the execution's provider id as well as its resolved family: the
  /// credential is selected per `providers.<id>.auth`, so an alias that
  /// configures its own must not have this decided by its family's setting.
  ///
  /// Injected because the credential stores and the one refresh authority per
  /// store are composed in `dartclaw_cli`, which this package cannot import.
  final Future<String?> Function(String providerId, String providerFamily)? subscriptionHomeResolver;

  new({
    required this.providers,
    this.containerAuthorities,
    this.bridgedMcpToolsResolver,
    this.executionInventory,
    this.subscriptionHomeResolver,
    EventBus? eventBus,
    WorkflowCliProcessStarter? processStarter,
    Uuid? uuid,
    Map<String, CliProvider>? providerImpls,
    MessageRedactor? diagnosticRedactor,
  }) : _processStarter = processStarter ?? _defaultProcessStarter,
       _eventBus = eventBus,
       _uuid = uuid ?? const Uuid(),
       _providerImpls =
           providerImpls ??
           {
             'claude': ClaudeCliProvider(diagnosticRedactor: diagnosticRedactor),
             'codex': CodexCliProvider(diagnosticRedactor: diagnosticRedactor),
           };

  /// Rejects [provider] under [policy] when the inventory says this surface
  /// cannot run it, before any family resolution or process spawn.
  void _requireSupported(String provider, ExecutionPolicy policy) {
    final verdict = executionInventory?.verdictFor(
      providerId: provider,
      surface: ProviderLaunchSurface.workflowOneShot,
      policy: policy,
    );
    if (verdict != null && !verdict.isSupported) throw UnsupportedError(verdict.message);
  }

  /// The implementation launching [provider] on the workflow one-shot surface.
  ///
  /// A provider with no implementation is unavailable on this surface — the
  /// same verdict the long-lived surface reports — and is never routed through
  /// another family's adapter.
  CliProvider _implFor(String provider, String providerFamily) {
    final impl = _providerImpls[providerFamily];
    if (impl == null) {
      throw UnsupportedError(
        ProviderExecutionVerdict.unsupportedSurface(
          providerId: provider,
          surface: ProviderLaunchSurface.workflowOneShot,
        ).message,
      );
    }
    return impl;
  }

  int? maxTurnsForStructuredTurn({required String provider, required bool noTools}) {
    _requireSupported(provider, const ExecutionPolicy.host());
    final providerConfig = providers[provider];
    if (providerConfig == null) {
      throw StateError('No workflow CLI provider config for "$provider"');
    }
    final providerFamily = ProviderIdentity.resolveFamily(
      provider,
      options: providerConfig.options,
      executable: providerConfig.executable,
    );
    final impl = _implFor(provider, providerFamily);
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
    String? artifactsDir,
    ContainerAuthorityLease? stepContainer,
    WorkflowCliUsageBaseline usageBaseline = const WorkflowCliUsageBaseline(),
  }) async {
    // Compatibility first: an unavailable combination reports the same verdict
    // whether or not the operator also gave the provider a capacity entry.
    _requireSupported(provider, policy);
    final providerConfig = providers[provider];
    if (providerConfig == null) {
      throw StateError('No workflow CLI provider config for "$provider"');
    }
    final providerFamily = ProviderIdentity.resolveFamily(
      provider,
      options: providerConfig.options,
      executable: providerConfig.executable,
    );
    final impl = _implFor(provider, providerFamily);
    var rootProcessTerminationReported = false;
    final observer = onRootProcessTerminationConfirmed;
    // The step owns the container: when the caller (WorkflowOneShotRunner) holds
    // one for the whole step, reuse it and leave its lifecycle to the caller.
    // A direct single-turn call leases its own, matching one-turn == one-step.
    final callerHeldContainer = stepContainer;
    final lease =
        callerHeldContainer ??
        await leaseStepContainer(
          policy,
          provider: provider,
          sessionId: sessionId,
          taskId: taskId,
          allowedTools: allowedTools,
          artifactsDir: artifactsDir,
        );
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
        retainContainerState: lease != null,
        processStarter: _processStarter,
        eventBus: _eventBus,
        uuid: _uuid,
        log: Logger('WorkflowCliRunner'),
        prepareSubscriptionHome: switch (subscriptionHomeResolver) {
          final resolve? => () => resolve(provider, providerFamily),
          null => null,
        },
      );
      return await impl.run(req);
    } finally {
      if (observer != null && !rootProcessTerminationReported) await observer(false);
      // A caller-held step container outlives the turn; only a lease this call
      // acquired for a standalone single turn is released here.
      if (callerHeldContainer == null && lease != null) {
        try {
          await releaseStepContainer(provider, lease);
        } catch (_) {
          if (observer != null) await observer(false);
          rethrow;
        }
      }
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
