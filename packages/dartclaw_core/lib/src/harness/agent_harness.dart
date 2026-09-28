import '../bridge/bridge_events.dart';
import '../worker/worker_state.dart';

/// Strategy for injecting behavior content into the agent's system prompt.
enum PromptStrategy {
  /// Replace the agent's built-in prompt (used for harnesses with no built-in prompt).
  replace,

  /// Append to the agent's built-in prompt via spawn-time flag.
  append,
}

/// Per-turn context fields an adapter serializes to its provider transport.
///
/// Which values each field accepts is not declared here: the provider process
/// reports them as a [ModelCatalogue].
final class EffectiveContextCapabilities {
  final bool model;
  final bool effort;

  const new({required this.model, required this.effort});

  static const unavailable = EffectiveContextCapabilities(model: false, effort: false);

  Map<String, Object> toJson() => {'model': model, 'effort': effort};

  static EffectiveContextCapabilities of(AgentHarness harness) => harness is EffectiveContextCapabilityProvider
      ? (harness as EffectiveContextCapabilityProvider).effectiveContextCapabilities
      : EffectiveContextCapabilities.unavailable;
}

abstract interface class EffectiveContextCapabilityProvider {
  EffectiveContextCapabilities get effectiveContextCapabilities;
}

/// One model a provider offers the account.
final class ModelCatalogueEntry {
  /// The value the provider accepts as its model selection.
  final String id;

  /// The provider's own human-readable name, verbatim.
  final String label;

  /// Efforts the provider reports for this model; empty when it supports none.
  final List<String> efforts;

  const new({required this.id, required this.label, this.efforts = const []});
}

/// The models a provider process reports for the account it runs as.
final class ModelCatalogue {
  /// Selectable models in the provider's order.
  final List<ModelCatalogueEntry> entries;

  /// The entry the provider's default resolves to, or `null` when the resolved
  /// model is not among [entries].
  final String? defaultId;

  const new({required this.entries, this.defaultId});

  /// The entry whose id is [id], or `null` when [id] is null or not listed.
  ModelCatalogueEntry? entryFor(String? id) {
    for (final entry in entries) {
      if (entry.id == id) return entry;
    }
    return null;
  }

  /// The entry Default resolves to, or `null` when [defaultId] is unresolved.
  ModelCatalogueEntry? get defaultEntry => entryFor(defaultId);
}

/// A harness that can read its provider's [ModelCatalogue] without a turn.
abstract interface class ModelCatalogueProvider {
  /// Starts the provider process, reads the catalogue and the resolved
  /// default, and stops the process.
  ///
  /// Throws when the provider cannot start or its answer lacks a field the
  /// catalogue is built from; no partial catalogue is returned.
  Future<ModelCatalogue> discoverModelCatalogue();
}

/// Adapter evidence that provider-native skill invocation is supported.
abstract interface class NativeSkillCapabilityProvider {
  bool get supportsNativeSkillInvocation;
}

/// Host-owned identity for the turn currently executing in a harness.
final class HarnessTurnContext {
  const new({
    required this.sessionId,
    required this.turnId,
    required this.source,
    required this.agentName,
    this.turnTimeout,
    this.allowOperatorApproval = false,
  });

  final String sessionId;
  final String turnId;
  final String? source;
  final String agentName;
  final bool allowOperatorApproval;

  /// Provider-process backstop derived from this turn's effective wall-clock budget.
  final Duration? turnTimeout;
}

/// Provider-independent outcome of one [AgentHarness.turn] call.
///
/// The field set is the union every consumer reads, so a provider that cannot
/// supply a value must still name it: token counts default to `0` rather than
/// being absent, while [costUsd] and [sessionTitle] stay nullable because
/// "not reported" and "no title" are real states callers distinguish.
///
/// [stopReason] carries the provider's own vocabulary. A harness signals failure
/// with `'error'` and cancellation with `'cancelled'`; those two literals are all
/// the runtime interprets, through [isError] and [isCancelled].
final class TurnResult {
  const new({
    this.finalText,
    this.stopReason,
    this.error,
    this.costUsd,
    this.sessionTitle,
    this.providerSessionId,
    this.structuredOutput,
    this.inputTokens = 0,
    this.outputTokens = 0,
    this.cacheReadTokens = 0,
    this.cacheWriteTokens = 0,
    this.tokenUsageComplete = false,
    this.claudeUsageSnapshot,
    this.mainSessionInputTokens,
  });

  final String? stopReason;

  /// The turn's authoritative assistant text when the provider reports it on
  /// completion. Null when the delta stream is the only source.
  final String? finalText;

  /// Provider-supplied failure detail, set only when [isError].
  final String? error;

  final double? costUsd;
  final String? sessionTitle;

  /// Resumable provider-native session identity, or null when not requested.
  final String? providerSessionId;

  /// Payload the provider reported under the turn's output schema.
  ///
  /// Null on every schema-free turn. The harness returns whatever the provider
  /// reported, verbatim, and never judges or repairs it — so check [isError]
  /// before trusting a payload: a failed turn may still carry one.
  final Map<String, dynamic>? structuredOutput;
  final int inputTokens;
  final int outputTokens;
  final int cacheReadTokens;
  final int cacheWriteTokens;

  /// Whether the scalar token counters cover all work in this turn.
  final bool tokenUsageComplete;

  /// Claude's cumulative native-session reading; the runtime derives a turn delta.
  final ClaudeUsageSnapshot? claudeUsageSnapshot;

  /// The root conversation's input measure for context-window monitoring.
  final int? mainSessionInputTokens;

  bool get isError => stopReason == 'error';

  bool get isCancelled => stopReason == 'cancelled';

  @override
  String toString() =>
      'TurnResult(stopReason: $stopReason, error: $error, costUsd: $costUsd, sessionTitle: $sessionTitle, '
      'providerSessionId: $providerSessionId, structuredOutput: $structuredOutput, '
      'inputTokens: $inputTokens, outputTokens: $outputTokens, '
      'cacheReadTokens: $cacheReadTokens, cacheWriteTokens: $cacheWriteTokens)';
}

/// One model's cumulative counters in a Claude native session.
final class ClaudeModelUsage {
  const new({required this.input, required this.output, required this.cacheRead, required this.cacheWrite});

  final int input;
  final int output;
  final int cacheRead;
  final int cacheWrite;

  Map<String, Object> toJson() => {
    'input': input,
    'output': output,
    'cache_read': cacheRead,
    'cache_write': cacheWrite,
  };

  static ClaudeModelUsage? fromJson(Object? value) {
    if (value is! Map) return null;
    final input = value['input'];
    final output = value['output'];
    final cacheRead = value['cache_read'];
    final cacheWrite = value['cache_write'];
    if (input is! int ||
        input < 0 ||
        output is! int ||
        output < 0 ||
        cacheRead is! int ||
        cacheRead < 0 ||
        cacheWrite is! int ||
        cacheWrite < 0) {
      return null;
    }
    return ClaudeModelUsage(input: input, output: output, cacheRead: cacheRead, cacheWrite: cacheWrite);
  }
}

/// Claude's full cumulative snapshot, scoped to its native session identity.
final class ClaudeUsageSnapshot {
  const new({required this.nativeSessionId, required this.models, this.totalCostUsd});

  final String nativeSessionId;
  final Map<String, ClaudeModelUsage> models;
  final double? totalCostUsd;

  Map<String, Object?> toJson() => {
    'native_session_id': nativeSessionId,
    'models': {for (final entry in models.entries) entry.key: entry.value.toJson()},
    'total_cost_usd': totalCostUsd,
  };

  static ClaudeUsageSnapshot? fromJson(Object? value) {
    if (value is! Map) return null;
    final id = value['native_session_id'];
    final rawModels = value['models'];
    final rawCost = value['total_cost_usd'];
    if (id is! String || id.isEmpty || rawModels is! Map || rawModels.isEmpty) {
      return null;
    }
    final models = <String, ClaudeModelUsage>{};
    for (final entry in rawModels.entries) {
      if (entry.key is! String || (entry.key as String).isEmpty) return null;
      final usage = ClaudeModelUsage.fromJson(entry.value);
      if (usage == null) return null;
      models[entry.key as String] = usage;
    }
    final cost = rawCost is num && rawCost.isFinite && rawCost >= 0 ? rawCost.toDouble() : null;
    return ClaudeUsageSnapshot(nativeSessionId: id, models: models, totalCostUsd: cost);
  }
}

/// Thrown when a turn carries an input the target harness cannot honour.
///
/// Refusing by name is the point: an accepted-but-unenforced input is
/// indistinguishable from an enforced one at the call site.
final class UnsupportedHarnessCapabilityException implements Exception {
  const new({required this.provider, required this.capability});

  /// Harness type that refused the turn.
  final String provider;

  /// Capability the turn required, in the vocabulary of the contract getter.
  final String capability;

  @override
  String toString() => 'UnsupportedHarnessCapabilityException: $provider does not support $capability';
}

/// Receives trusted host turn identity before provider execution begins.
abstract interface class HarnessTurnContextSink {
  void setTurnContext(HarnessTurnContext? context);
}

/// Answers one provider-native approval request owned by the active turn.
abstract interface class HarnessToolApprovalResponder {
  bool canResolveToolApproval({required String turnId, required String requestId});

  Future<void> resolveToolApproval({required String turnId, required String requestId, required bool approved});
}

typedef ContextualMemoryToolHandler = Future<Map<String, dynamic>> Function(
  Map<String, dynamic> arguments,
  HarnessTurnContext context,
);

/// Abstract harness interface that decouples consumers from the specific
/// agent runtime (Deno worker, native CLI, etc.).
///
/// Consumers depend on this interface, not concrete implementations
/// (ClaudeCodeHarness, future PiHarness, etc.).
abstract class AgentHarness {
  /// How this harness injects behavior content. Default: [PromptStrategy.replace].
  PromptStrategy get promptStrategy => PromptStrategy.replace;

  /// Whether this harness reports per-turn cost information.
  bool get supportsCostReporting => true;

  /// Whether this harness can surface tool approval requests.
  bool get supportsToolApproval => true;

  /// Whether this harness emits streaming turn events.
  bool get supportsStreaming => true;

  /// Whether this harness reports cached token counts.
  bool get supportsCachedTokens => false;

  /// Whether this harness supports continuing an existing conversation session.
  ///
  /// When true, multi-prompt workflow steps can send follow-up turns in the
  /// same live harness session. When false, multi-prompt steps targeting this
  /// provider type are rejected at workflow load time.
  bool get supportsSessionContinuity => false;

  /// Whether turns can mint or resume a provider session that outlives this harness process.
  bool get supportsProviderSessionResume => false;

  /// Whether this harness can enforce an explicitly empty work-tool policy.
  ///
  /// The runtime supplies the mandatory deny-all guard. This capability means
  /// every provider-native and MCP work-tool call reaches that guard before it
  /// can execute; response-only structured output may remain available.
  bool get supportsNoWorkTools => false;

  /// Capability name carried by empty work-tool policy refusals.
  static const String noWorkToolsCapability = 'empty work-tool policy';

  /// Refuses an explicitly empty policy when [harness] cannot enforce it.
  static void requireNoWorkToolsSupport(
    AgentHarness harness, {
    required String provider,
    required bool emptyToolPolicyRequired,
  }) {
    if (!emptyToolPolicyRequired || harness.supportsNoWorkTools) return;
    throw UnsupportedHarnessCapabilityException(provider: provider, capability: noWorkToolsCapability);
  }

  /// Stable capability name used when provider-session resume is refused.
  static const String providerSessionResumeCapability = 'provider session resume';

  /// Throws when either provider-session input is supplied to a harness that cannot honor it.
  static void requireProviderSessionResumeSupport(
    AgentHarness harness,
    String? providerSessionId,
    bool requestProviderSessionResume,
  ) {
    if ((providerSessionId == null && !requestProviderSessionResume) || harness.supportsProviderSessionResume) return;
    final provider = harness.runtimeType.toString();
    throw UnsupportedHarnessCapabilityException(provider: provider, capability: providerSessionResumeCapability);
  }

  /// Whether this harness can have the provider enforce a per-turn output schema.
  ///
  /// Fail-closed: an implementation that does not override this refuses every
  /// schema-bearing turn through [requireStructuredOutputSupport], so a schema
  /// is never dropped on the way to a provider that would ignore it.
  bool get supportsStructuredOutput => false;

  /// Whether this harness can have the provider constrain the final assistant
  /// text to a per-turn output schema without returning a typed payload.
  ///
  /// Consulted only when [supportsStructuredOutput] is false. A schema forwarded
  /// under this capability leaves [TurnResult.structuredOutput] null; the caller
  /// reads the reply text itself.
  bool get supportsOutputSchemaConstraint => false;

  /// Capability name carried by structured-output refusals.
  static const String structuredOutputCapability = 'structured output';

  /// Refuses [outputSchema] when [harness] can neither enforce it with a typed
  /// readback nor have the provider constrain the reply to it.
  ///
  /// Every [turn] implementation calls this before any provider work. Static
  /// rather than an instance method because harnesses that adopt this contract
  /// with `implements` inherit no body and would each need their own copy.
  static void requireStructuredOutputSupport(AgentHarness harness, Map<String, dynamic>? outputSchema) {
    if (outputSchema == null || harness.supportsStructuredOutput || harness.supportsOutputSchemaConstraint) return;
    throw UnsupportedHarnessCapabilityException(
      provider: harness.runtimeType.toString(),
      capability: structuredOutputCapability,
    );
  }

  /// Whether this harness registers and receives the `PreCompact` hook callback.
  ///
  /// When true, the host's flush heuristic (`shouldFlushForCompactionSignal`)
  /// is suppressed because compaction signals already arrive via hook callbacks.
  bool get supportsPreCompactHook => false;

  /// Renders the native skill-activation line for prompts targeting this harness.
  ///
  /// Subclasses override with Codex/Claude-native forms; the default is portable.
  String skillActivationLine(String skill) => defaultSkillActivationLine(skill);

  /// Portable skill-activation line used when no harness override applies.
  static String defaultSkillActivationLine(String skill) => "Use the '$skill' skill.";

  /// Current lifecycle state of the harness.
  WorkerState get state;

  /// Whether no managed root process has an unconfirmed termination.
  ///
  /// Harnesses that do not manage a root process must return `true` explicitly.
  bool get isRootProcessTerminationConfirmed;

  /// Persistent broadcast stream of bridge events (survives restarts).
  Stream<BridgeEvent> get events;

  /// Start the underlying agent runtime. Throws if already busy.
  Future<void> start();

  /// Send a conversational turn and return its [TurnResult].
  ///
  /// [sessionId] identifies the SDK session to use for this turn. [messages]
  /// contains the message history payload forwarded to the runtime.
  /// A non-empty [systemPrompt] is the authoritative scoped prompt for this
  /// turn on every prompt strategy; empty selects the harness's configured
  /// default.
  /// [agentId] identifies a logical agent; null denotes the main agent.
  /// [mcpServers] configures inline MCP servers for the request when supported.
  /// [providerSessionId] identifies a provider-native session to resume.
  /// When [requestProviderSessionResume] is true, the provider must create or
  /// continue a session that a later harness process can resume.
  /// [directory] overrides the working directory for this turn when supported.
  /// [model] overrides the default model for this turn.
  /// [effort] overrides the reasoning effort level for this turn.
  /// [maxTurns] caps harness-side autonomous turns when supported.
  /// [outputSchema] is an opaque JSON Schema the provider applies to this turn.
  /// With [supportsStructuredOutput] the enforced payload returns on
  /// [TurnResult.structuredOutput]; with only [supportsOutputSchemaConstraint]
  /// the provider constrains the reply text and [TurnResult.structuredOutput]
  /// stays null. A harness with neither throws
  /// [UnsupportedHarnessCapabilityException] instead of running the turn.
  Future<TurnResult> turn({
    required String sessionId,
    required List<Map<String, dynamic>> messages,
    required String systemPrompt,
    String? agentId,
    Map<String, dynamic>? mcpServers,
    String? providerSessionId,
    bool requestProviderSessionResume = false,
    String? directory,
    String? model,
    String? effort,
    int? maxTurns,
    Map<String, dynamic>? outputSchema,
  });

  /// Clears provider-side conversation continuity for [sessionId], if any.
  ///
  /// Only a call for the session whose turn is active is a contract violation;
  /// callers must not make one. A call for any other session is always
  /// permitted, including while a turn is in flight, so implementations must
  /// answer for what their own process actually carries: either a no-op or a
  /// clear bounded to [sessionId] that is safe alongside the running turn.
  Future<void> resetSessionContinuity(String sessionId) async {}

  /// Cancel the current in-progress turn.
  Future<void> cancel();

  /// Graceful shutdown — cancels any active turn, kills the process.
  Future<void> stop();

  /// Terminal shutdown — closes event stream permanently. Idempotent.
  /// Must not call [start] after [dispose].
  Future<void> dispose();
}
