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

  /// Current lifecycle state of the harness.
  WorkerState get state;

  /// Persistent broadcast stream of bridge events (survives restarts).
  Stream<BridgeEvent> get events;

  /// Start the underlying agent runtime. Throws if already busy.
  Future<void> start();

  /// Send a conversational turn and return the result.
  ///
  /// When [resume] is true, the harness resumes an existing SDK session
  /// instead of starting a fresh conversation (maps to `options.resume`).
  Future<Map<String, dynamic>> turn({
    required String sessionId,
    required List<Map<String, dynamic>> messages,
    required String systemPrompt,
    Map<String, dynamic>? mcpServers,
    bool resume = false,
    String? directory,
    String? model,
  });

  /// Cancel the current in-progress turn.
  Future<void> cancel();

  /// Graceful shutdown — cancels any active turn, kills the process.
  Future<void> stop();

  /// Terminal shutdown — closes event stream permanently. Idempotent.
  /// Must not call [start] after [dispose].
  Future<void> dispose();
}
