import '../bridge/bridge_events.dart';
import '../worker/worker_state.dart';

/// Strategy for injecting behavior content into the agent's system prompt.
enum PromptStrategy {
  /// Replace the agent's built-in prompt (used for harnesses with no built-in prompt).
  replace,

  /// Append to the agent's built-in prompt via spawn-time flag.
  append,
}

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
  /// same session (via `resume: true`). When false, multi-prompt steps targeting
  /// this provider type are rejected at workflow load time.
  bool get supportsSessionContinuity => false;

  /// Whether this harness registers and receives the `PreCompact` hook callback.
  ///
  /// When true, [ContextMonitor] suppresses the heuristic `shouldFlush` check
  /// because compaction signals are already available via hook callbacks.
  bool get supportsPreCompactHook => false;

  /// Renders the native skill-activation line this harness recognises.
  ///
  /// Workflow steps (and any caller that wants to hand the harness a skill
  /// to run) should use this to build the prompt preamble, so the harness
  /// can pre-load the `SKILL.md` body instead of asking the model to find
  /// and read it via a tool call. Skipping that tool-call round-trip saves
  /// one agent turn and a few thousand cumulative input tokens per skill
  /// invocation.
  ///
  /// Subclasses override with the harness-native form (Codex uses
  /// `$skill-name`, Claude Code uses `/skill-name`, etc.). The default
  /// here is the portable verbose form so a fresh harness works before
  /// anyone teaches it the convention — and so non-native harnesses still
  /// understand the intent via plain language.
  String skillActivationLine(String skill) => defaultSkillActivationLine(skill);

  /// The portable-verbose skill-activation line used when no harness
  /// override applies. Shared with `HarnessFactory` so the "unregistered
  /// provider" fallback mirrors the subclass default without duplicating
  /// the literal.
  static String defaultSkillActivationLine(String skill) => "Use the '$skill' skill.";

  /// Current lifecycle state of the harness.
  WorkerState get state;

  /// Persistent broadcast stream of bridge events (survives restarts).
  Stream<BridgeEvent> get events;

  /// Start the underlying agent runtime. Throws if already busy.
  Future<void> start();

  /// Send a conversational turn and return the result.
  ///
  /// [sessionId] identifies the SDK session to use for this turn. [messages]
  /// contains the message history payload forwarded to the runtime.
  /// [systemPrompt] is the effective behavior prompt for this turn.
  /// [mcpServers] configures inline MCP servers for the request when supported.
  /// When [resume] is true, the harness resumes an existing SDK session
  /// instead of starting a fresh conversation (maps to `options.resume`).
  /// [directory] overrides the working directory for this turn when supported.
  /// [model] overrides the default model for this turn.
  /// [effort] overrides the reasoning effort level for this turn.
  /// [maxTurns] caps harness-side autonomous turns when supported.
  Future<Map<String, dynamic>> turn({
    required String sessionId,
    required List<Map<String, dynamic>> messages,
    required String systemPrompt,
    Map<String, dynamic>? mcpServers,
    bool resume = false,
    String? directory,
    String? model,
    String? effort,
    int? maxTurns,
  });

  /// Cancel the current in-progress turn.
  Future<void> cancel();

  /// Graceful shutdown — cancels any active turn, kills the process.
  Future<void> stop();

  /// Terminal shutdown — closes event stream permanently. Idempotent.
  /// Must not call [start] after [dispose].
  Future<void> dispose();
}
