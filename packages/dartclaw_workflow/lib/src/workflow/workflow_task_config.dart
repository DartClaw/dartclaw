import 'package:logging/logging.dart';

/// Shared `task.configJson` keys and typed accessors for the workflow
/// one-shot execution path.
///
/// The `WorkflowExecutor` and `TaskExecutor` (in `dartclaw_server`) communicate
/// across package boundaries via these task config entries. Centralising both
/// the **names** and the **shape contract** here prevents silent breakage from
/// typos or asymmetric coercion: every cross-package read goes through a
/// `read*` method, and every cross-package write goes through a `write*`
/// method. Type drift between writer and reader becomes impossible.
///
/// **Scope**: only keys that cross the `dartclaw_workflow ↔ dartclaw_server`
/// package boundary belong here. Keys used solely within `WorkflowExecutor`
/// (e.g. `_continueSessionId`, `_sessionBaselineTokens`, `_workflowGit`,
/// `_workflowWorkspaceDir`, `_mapIterationIndex`) intentionally remain string
/// literals — migrating them here would bloat the contract without improving
/// safety. New cross-package keys MUST be added as constants in this class
/// with matching `read*` (and `write*` if there is an actual write site)
/// accessors.
///
/// Writer helpers are added only when a real write call site exists; do not
/// pre-add writer stubs for read-only keys (dead-code avoidance is the point
/// of this class).
///
/// **Reader robustness**: all `read*` accessors are defensive — they return
/// `null` (or an empty collection) when the underlying value is missing,
/// `null`, or the wrong shape. They never throw. Earlier inline call sites
/// used `as String?` casts that would throw on malformed `task.configJson`
/// payloads; the accessors swallow such cases silently because the only
/// writers are funnelled through the `write*` helpers (which are
/// compile-time type-checked), so a malformed value can only originate from
/// corrupted persistent storage — a state in which a silent skip is safer
/// than crashing one-shot execution.
abstract final class WorkflowTaskConfig {
  static final _log = Logger('WorkflowTaskConfig');

  // ── Key constants ─────────────────────────────────────────────────────────

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

  /// Authored workflow step id for one-shot task event attribution.
  static const workflowStepId = '_workflowStepId';

  /// Per-step incremental input token count excluding prompt-cache reads.
  static const inputTokensNew = '_workflowInputTokensNew';

  /// Per-step prompt-cache reads for one-shot workflow execution.
  static const cacheReadTokens = '_workflowCacheReadTokens';

  /// Per-step output tokens for one-shot workflow execution.
  static const outputTokens = '_workflowOutputTokens';

  // ── Typed readers ─────────────────────────────────────────────────────────

  /// Reads [followUpPrompts] as a `List<String>`. Coerces non-string entries
  /// via `toString()`. Returns an empty const list when the key is absent or
  /// the value is not a list.
  static List<String> readFollowUpPrompts(Map<String, dynamic> cfg) {
    return switch (cfg[followUpPrompts]) {
      final List<dynamic> values => values.map((v) => v.toString()).toList(growable: false),
      _ => const <String>[],
    };
  }

  /// Reads [structuredSchema] as `Map<String, dynamic>?`. Accepts both typed
  /// and raw map shapes (YAML deserialisation may produce
  /// `Map<Object?, Object?>`). Returns `null` when the key is absent or the
  /// value is not a map.
  static Map<String, dynamic>? readStructuredSchema(Map<String, dynamic> cfg) {
    return switch (cfg[structuredSchema]) {
      final Map<String, dynamic> s => s,
      final Map<Object?, Object?> s => s.map((k, v) => MapEntry(k.toString(), v)),
      _ => null,
    };
  }

  /// Reads [structuredOutputPayload] as `Map<String, dynamic>?`. Accepts both
  /// typed and raw map shapes. Returns `null` when the key is absent or the
  /// value is not a map.
  static Map<String, dynamic>? readStructuredOutputPayload(Map<String, dynamic> cfg) {
    return switch (cfg[structuredOutputPayload]) {
      final Map<String, dynamic> p => p,
      final Map<Object?, Object?> p => p.map((k, v) => MapEntry(k.toString(), v)),
      _ => null,
    };
  }

  /// Reads [providerSessionId] as a trimmed non-empty string, or `null` when
  /// the key is absent, not a string, or whitespace-only.
  static String? readProviderSessionId(Map<String, dynamic> cfg) {
    return _readTrimmedString(cfg, providerSessionId);
  }

  /// Reads [continueProviderSessionId] as a trimmed non-empty string, or
  /// `null` when the key is absent, not a string, or whitespace-only.
  static String? readContinueProviderSessionId(Map<String, dynamic> cfg) {
    return _readTrimmedString(cfg, continueProviderSessionId);
  }

  /// Reads [workflowStepId] as a trimmed non-empty string.
  static String? readWorkflowStepId(Map<String, dynamic> cfg) {
    return _readTrimmedString(cfg, workflowStepId);
  }

  /// Reads [inputTokensNew] as a non-negative integer, defaulting to `0`.
  static int readInputTokensNew(Map<String, dynamic> cfg) => _readInt(cfg, inputTokensNew);

  /// Reads [cacheReadTokens] as a non-negative integer, defaulting to `0`.
  static int readCacheReadTokens(Map<String, dynamic> cfg) => _readInt(cfg, cacheReadTokens);

  /// Reads [outputTokens] as a non-negative integer, defaulting to `0`.
  static int readOutputTokens(Map<String, dynamic> cfg) => _readInt(cfg, outputTokens);

  // ── Typed writers ─────────────────────────────────────────────────────────
  // Only the keys with actual write sites get writers. Adding a writer
  // without a caller is exactly the dead stub this class exists to prevent.

  /// Writes [followUpPrompts]. Mirrors [readFollowUpPrompts]'s contract.
  static void writeFollowUpPrompts(Map<String, dynamic> cfg, List<String> prompts) {
    cfg[followUpPrompts] = prompts;
  }

  /// Writes [structuredSchema]. Mirrors [readStructuredSchema]'s contract.
  static void writeStructuredSchema(Map<String, dynamic> cfg, Map<String, dynamic> schema) {
    cfg[structuredSchema] = schema;
  }

  /// Writes [providerSessionId]. Mirrors [readProviderSessionId]'s contract.
  static void writeProviderSessionId(Map<String, dynamic> cfg, String id) {
    cfg[providerSessionId] = id;
  }

  /// Writes [structuredOutputPayload]. Mirrors
  /// [readStructuredOutputPayload]'s contract.
  static void writeStructuredOutputPayload(Map<String, dynamic> cfg, Map<String, dynamic> payload) {
    cfg[structuredOutputPayload] = payload;
  }

  /// Writes [continueProviderSessionId]. Used by the executor when chaining a
  /// prior step's provider session id into the next task.
  static void writeContinueProviderSessionId(Map<String, dynamic> cfg, String id) {
    cfg[continueProviderSessionId] = id;
  }

  /// Writes [workflowStepId]. Mirrors [readWorkflowStepId]'s contract.
  static void writeWorkflowStepId(Map<String, dynamic> cfg, String stepId) {
    cfg[workflowStepId] = stepId;
  }

  /// Writes [inputTokensNew]. Mirrors [readInputTokensNew]'s contract.
  static void writeInputTokensNew(Map<String, dynamic> cfg, int value) {
    cfg[inputTokensNew] = value;
  }

  /// Writes [cacheReadTokens]. Mirrors [readCacheReadTokens]'s contract.
  static void writeCacheReadTokens(Map<String, dynamic> cfg, int value) {
    cfg[cacheReadTokens] = value;
  }

  /// Writes [outputTokens]. Mirrors [readOutputTokens]'s contract.
  static void writeOutputTokens(Map<String, dynamic> cfg, int value) {
    cfg[outputTokens] = value;
  }

  static String? _readTrimmedString(Map<String, dynamic> cfg, String keyName) {
    final raw = cfg[keyName];
    if (raw == null) return null;
    if (raw is! String) {
      _log.fine('$keyName had unexpected shape ${raw.runtimeType}; returning null');
      return null;
    }
    final trimmed = raw.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  static int _readInt(Map<String, dynamic> cfg, String keyName) {
    final raw = cfg[keyName];
    return switch (raw) {
      final int value when value >= 0 => value,
      final num value when value >= 0 => value.toInt(),
      _ => 0,
    };
  }
}
