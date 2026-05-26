import 'package:dartclaw_core/dartclaw_core.dart' show ContainerExecutor, EventBus;
import 'package:logging/logging.dart';
import 'package:uuid/uuid.dart';

import 'workflow_cli_runner.dart';

/// Abstraction for a single-turn CLI provider invocation.
///
/// Each concrete implementation owns its command construction, stdout/stderr
/// parsing, and any temp-file lifecycle for the provider it wraps.
abstract class CliProvider {
  /// Runs a one-shot turn described by [request] and returns the parsed result.
  Future<WorkflowCliTurnResult> run(CliTurnRequest request);
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
    this.allowedTools,
    this.readOnly = false,
    this.maxTurns,
    this.jsonSchema,
    this.appendSystemPrompt,
    this.sandboxOverride,
    this.extraEnvironment,
    required this.providerConfig,
    required this.containerManager,
    required this.processStarter,
    this.eventBus,
    required this.uuid,
    required this.log,
  });
}
