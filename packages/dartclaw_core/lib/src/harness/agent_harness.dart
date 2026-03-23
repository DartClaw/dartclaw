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
  Future<Map<String, dynamic>> turn({
    required String sessionId,
    required List<Map<String, dynamic>> messages,
    required String systemPrompt,
    Map<String, dynamic>? mcpServers,
    bool resume = false,
    String? directory,
    String? model,
    String? effort,
  });

  /// Cancel the current in-progress turn.
  Future<void> cancel();

  /// Graceful shutdown — cancels any active turn, kills the process.
  Future<void> stop();

  /// Terminal shutdown — closes event stream permanently. Idempotent.
  /// Must not call [start] after [dispose].
  Future<void> dispose();
}
