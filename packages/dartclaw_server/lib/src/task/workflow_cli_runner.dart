import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' show ContainerExecutor, EventBus;
import 'package:dartclaw_security/dartclaw_security.dart';
import 'package:logging/logging.dart';
import 'package:meta/meta.dart';
import 'package:uuid/uuid.dart';

import 'cli_provider.dart';
import 'claude_cli_provider.dart';
import 'codex_cli_provider.dart';

export 'cli_provider.dart' show CliProvider, CliTurnRequest;

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
  });
}

/// Drives a CLI provider subprocess to execute one or more workflow turns.
///
/// Adding a new provider requires only a new [CliProvider] implementation –
/// no edits to this class. Register it by passing [providerImpls] to the
/// constructor alongside the corresponding [WorkflowCliProviderConfig] entry
/// in [providers].
class WorkflowCliRunner {
  final Map<String, WorkflowCliProviderConfig> providers;
  final Map<String, ContainerExecutor> containerManagers;
  final EventBus? _eventBus;
  final WorkflowCliProcessStarter _processStarter;
  final Uuid _uuid;
  final Map<String, CliProvider> _providerImpls;

  WorkflowCliRunner({
    required this.providers,
    this.containerManagers = const <String, ContainerExecutor>{},
    EventBus? eventBus,
    WorkflowCliProcessStarter? processStarter,
    Uuid? uuid,
    Map<String, CliProvider>? providerImpls,
  }) : _processStarter = processStarter ?? _defaultProcessStarter,
       _eventBus = eventBus,
       _uuid = uuid ?? const Uuid(),
       _providerImpls = providerImpls ?? const {'claude': ClaudeCliProvider(), 'codex': CodexCliProvider()};

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
    required String profileId,
    String? taskId,
    String? sessionId,
    String? providerSessionId,
    String? model,
    String? effort,
    List<String>? allowedTools,
    bool readOnly = false,
    int? maxTurns,
    Map<String, dynamic>? jsonSchema,
    String? appendSystemPrompt,
    String? sandboxOverride,
    Map<String, String>? extraEnvironment,
  }) async {
    final providerConfig = providers[provider];
    if (providerConfig == null) {
      throw StateError('No workflow CLI provider config for "$provider"');
    }
    final impl = _providerImpls[provider];
    if (impl == null) {
      throw UnsupportedError('Workflow one-shot CLI is not implemented for provider "$provider"');
    }
    final req = CliTurnRequest(
      prompt: prompt,
      workingDirectory: workingDirectory,
      profileId: profileId,
      taskId: taskId,
      sessionId: sessionId,
      providerSessionId: providerSessionId,
      model: model,
      effort: effort,
      allowedTools: allowedTools,
      readOnly: readOnly,
      maxTurns: maxTurns,
      jsonSchema: jsonSchema,
      appendSystemPrompt: appendSystemPrompt,
      sandboxOverride: sandboxOverride,
      extraEnvironment: extraEnvironment,
      providerConfig: providerConfig,
      containerManager: containerManagers[profileId],
      processStarter: _processStarter,
      eventBus: _eventBus,
      uuid: _uuid,
      log: Logger('WorkflowCliRunner'),
    );
    return impl.run(req);
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
