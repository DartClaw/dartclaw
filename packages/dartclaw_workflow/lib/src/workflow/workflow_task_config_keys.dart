/// Shared `task.configJson` keys used by the workflow one-shot execution path.
///
/// The `WorkflowExecutor` and `TaskExecutor` (in `dartclaw_server`) communicate
/// across package boundaries via these task config entries. Centralizing the
/// keys here prevents silent breakage from typos and makes the contract
/// explicit.
///
/// **Scope**: only keys that cross the `dartclaw_workflow ↔ dartclaw_server`
/// package boundary belong here. Keys used solely within `WorkflowExecutor`
/// (e.g. `_continueSessionId`, `_sessionBaselineTokens`, `_workflowGit`,
/// `_workflowWorkspaceDir`, `_mapIterationIndex`) intentionally remain string
/// literals — migrating them here would bloat the contract without improving
/// safety. New cross-package keys MUST be added as constants in this class.
abstract final class WorkflowTaskConfigKeys {
  /// Multi-prompt follow-up list queued by the executor for the one-shot runner.
  static const followUpPrompts = '_workflowFollowUpPrompts';

  /// JSON schema for the structured output extraction turn.
  static const structuredSchema = '_workflowStructuredSchema';

  /// Provider-side session id (Claude `session_id` / Codex `thread_id`)
  /// captured from the one-shot runner and re-read by the executor.
  static const providerSessionId = '_workflowProviderSessionId';

  /// Parsed structured-output payload from the extraction turn. Consumed by
  /// `ContextExtractor` to bypass heuristic extraction.
  static const structuredOutputPayload = '_workflowStructuredOutputPayload';

  /// Prior-step provider session id forwarded via `continueSession` chaining.
  static const continueProviderSessionId = '_continueProviderSessionId';
}
