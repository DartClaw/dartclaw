import 'dart:convert';

import 'package:logging/logging.dart';

final _log = Logger('ClaudeProtocol');

/// Env vars to clear to prevent claude nesting detection.
/// Shared between [ClaudeCodeHarness] and [ClaudeBinaryClassifier].
const claudeNestingEnvVars = ['CLAUDECODE', 'CLAUDE_CODE_ENTRYPOINT', 'CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS'];

/// Env var the `claude` CLI reads a subscription `setup-token` from.
///
/// Written into a *host* spawn environment after the sensitive-name sanitize,
/// so the token DartClaw stores is what the CLI authenticates on and an
/// inherited shell value never is. Containerized spawns never carry it: the
/// container is mediated by the host gateway and holds no credential.
const claudeOauthTokenEnvVar = 'CLAUDE_CODE_OAUTH_TOKEN';

/// Security-hardening env vars applied to every *host* (direct-spawn) Claude
/// harness launch. Containerized spawns use [claudeContainerHardeningEnvVars].
///
/// `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1` makes the claude CLI scrub the env it
/// hands to child processes, so an allowlisted child cannot read the host
/// `ANTHROPIC_API_KEY`. The CLI also treats it as a broader hardening signal:
/// it forces `--permission-mode default`, printing a benign stderr notice
/// ("Permission mode forced to default"). That is compatible with every host
/// spawn path: workflow one-shot tasks carry their tool policy as `--settings`
/// permission rules, which default mode enforces identically in headless
/// runs (non-allowed tools are denied, never prompted), and the long-lived
/// harness fields permission requests over the control protocol. The notice
/// is operational noise, not a failure cause — verified live 2026-07-07
/// (allowed tools run, denied tools deny, skills invoke, structured output
/// completes, with the var set). Full-access (`approval: never`) one-shots
/// opt out with an explicit `=0` (see `ClaudeCliProvider`), because the
/// forced default mode would neutralize their bypass posture.
const claudeHardeningEnvVars = <String, String>{
  'CLAUDE_CODE_SUBPROCESS_ENV_SCRUB': '1',
  'DISABLE_AUTOUPDATER': '1',
  'CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC': '1',
};

/// Env vars for containerized Claude spawns — [claudeHardeningEnvVars] with
/// the subprocess env-scrub explicitly disabled.
///
/// The scrub buys nothing inside the container boundary: a containerized
/// spawn starts from this minimal set (never the host environment), and the
/// only `ANTHROPIC_API_KEY` present is the non-credential placeholder
/// [containerClaudePlaceholderApiKey] — there is no host secret to scrub.
/// Worse, the current claude CLI reads `=1` as a demand for host-sandbox
/// tooling (bubblewrap) that cannot start under the container's own hardening
/// (`--cap-drop ALL`, `no-new-privileges`). Tool enforcement for containerized
/// spawns is the guard chain plus the host gateway, never Claude's permission
/// mode. The explicit `0` wins over any image-level default.
const claudeContainerHardeningEnvVars = <String, String>{
  'CLAUDE_CODE_SUBPROCESS_ENV_SCRUB': '0',
  'DISABLE_AUTOUPDATER': '1',
  'CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC': '1',
};

/// Placeholder `ANTHROPIC_API_KEY` for a containerized Claude launch.
///
/// Not a credential, and deliberately not one: the claude CLI refuses at its
/// own local auth gate before making any request when no key is present at all
/// – `duration_api_ms: 0`, "Not logged in" – so a containerized client that is
/// meant to be mediated would never reach the host bridge. This value only
/// satisfies that local check. The host adapter drops every client-supplied
/// credential header and injects the real host key last, so this string cannot
/// reach a provider.
const containerClaudePlaceholderApiKey = 'dartclaw-host-mediated-no-credential';

// ---------------------------------------------------------------------------
// Sealed class hierarchy for claude binary JSONL messages
// ---------------------------------------------------------------------------

sealed class ClaudeMessage;

/// System init event — emitted by the CLI at the start of each turn response.
final class SystemInit extends ClaudeMessage {
  final String? sessionId;
  final int toolCount;
  final int? contextWindow;

  new({this.sessionId, required this.toolCount, this.contextWindow});

  @override
  String toString() => 'SystemInit(sessionId: $sessionId, toolCount: $toolCount)';
}

/// Streaming text delta from `content_block_delta`.
final class StreamTextDelta extends ClaudeMessage {
  final String text;

  new(this.text);

  @override
  String toString() => 'StreamTextDelta(text: ${text.length > 80 ? '${text.substring(0, 80)}...' : text})';
}

/// Tool use block from an `assistant` message.
final class ToolUseBlock extends ClaudeMessage {
  final String name;
  final String id;
  final Map<String, dynamic> input;

  new({required this.name, required this.id, required this.input});

  @override
  String toString() => 'ToolUseBlock(name: $name, id: $id)';
}

/// Tool result block from an `assistant` message.
final class ToolResultBlock extends ClaudeMessage {
  final String toolId;
  final String output;
  final bool isError;

  new({required this.toolId, required this.output, this.isError = false});

  @override
  String toString() => 'ToolResultBlock(toolId: $toolId, isError: $isError)';
}

/// Control request from the claude binary (e.g. `can_use_tool`, `hook_callback`).
final class ControlRequest extends ClaudeMessage {
  final String requestId;
  final String subtype;
  final Map<String, dynamic> data;

  new({required this.requestId, required this.subtype, required this.data});

  @override
  String toString() => 'ControlRequest(requestId: $requestId, subtype: $subtype)';
}

/// Compact boundary signal — emitted after context compaction completes.
///
/// Wire format: `{"type": "system", "subtype": "compact_boundary",
///               "trigger": "auto|manual", "pre_tokens": 142857}`.
final class CompactBoundary extends ClaudeMessage {
  /// Trigger source: `"auto"` or `"manual"`.
  final String trigger;

  /// Token count before compaction. May be null if omitted by the binary.
  final int? preTokens;

  new({required this.trigger, this.preTokens});

  @override
  String toString() => 'CompactBoundary(trigger: $trigger, preTokens: $preTokens)';
}

/// Turn result — signals turn completion.
final class TurnResult extends ClaudeMessage {
  final String? stopReason;
  final double? costUsd;
  final int? durationMs;
  final int? inputTokens;
  final int? outputTokens;
  final int? cacheReadInputTokens;
  final int? cacheCreationInputTokens;

  new({
    this.stopReason,
    this.costUsd,
    this.durationMs,
    this.inputTokens,
    this.outputTokens,
    this.cacheReadInputTokens,
    this.cacheCreationInputTokens,
  });
  @override
  String toString() =>
      'TurnResult(stopReason: $stopReason, costUsd: $costUsd, durationMs: $durationMs, '
      'inputTokens: $inputTokens, outputTokens: $outputTokens, '
      'cacheReadInputTokens: $cacheReadInputTokens, cacheCreationInputTokens: $cacheCreationInputTokens)';
}

// ---------------------------------------------------------------------------
// Parsing
// ---------------------------------------------------------------------------

/// Parse a single JSONL line from the claude binary into a [ClaudeMessage].
///
/// Returns `null` for malformed JSON, unknown types, or irrelevant stream
/// events (message lifecycle, input_json_delta, etc.).
ClaudeMessage? parseJsonlLine(String line) {
  if (line.isEmpty) return null;

  Map<String, dynamic> json;
  try {
    json = jsonDecode(line) as Map<String, dynamic>;
  } catch (e) {
    _log.warning('Failed to parse JSONL: $e');
    return null;
  }

  final type = json['type'] as String?;

  return switch (type) {
    'system' => _parseSystem(json),
    'stream_event' => _parseStreamEvent(json),
    'assistant' => _parseAssistant(json),
    'control_request' => _parseControlRequest(json),
    'result' => _parseResult(json),
    _ => null,
  };
}

// ---------------------------------------------------------------------------
// Internal parsers
// ---------------------------------------------------------------------------

ClaudeMessage? _parseSystem(Map<String, dynamic> json) {
  final subtype = json['subtype'] as String?;

  if (subtype == 'init') {
    final sessionId = json['session_id'] as String?;
    final tools = json['tools'] as List?;
    final contextWindow = json['context_window'] as int?;
    return SystemInit(sessionId: sessionId, toolCount: tools?.length ?? 0, contextWindow: contextWindow);
  }

  if (subtype == 'compact_boundary') {
    final trigger = json['trigger'] as String? ?? 'auto';
    final preTokens = json['pre_tokens'] as int?;
    return CompactBoundary(trigger: trigger, preTokens: preTokens);
  }

  return null;
}

ClaudeMessage? _parseStreamEvent(Map<String, dynamic> json) {
  final event = json['event'] as Map<String, dynamic>?;
  if (event == null) return null;

  final eventType = event['type'] as String?;
  if (eventType != 'content_block_delta') return null;

  final delta = event['delta'] as Map<String, dynamic>?;
  if (delta == null) return null;

  final deltaType = delta['type'] as String?;
  if (deltaType != 'text_delta') return null;

  final text = delta['text'] as String? ?? '';
  if (text.isEmpty) return null;

  return StreamTextDelta(text);
}

/// Parse `assistant` messages for tool_use and tool_result blocks only.
/// Text is intentionally ignored here — it comes from stream_event to avoid
/// double-counting.
ClaudeMessage? _parseAssistant(Map<String, dynamic> json) {
  final message = json['message'] as Map<String, dynamic>?;
  if (message == null) return null;

  final content = message['content'];
  if (content is! List) return null;

  // Return the first tool_use or tool_result block found.
  // Multiple blocks per message are possible but rare; callers that need all
  // blocks can use parseAssistantBlocks (future extension).
  for (final block in content) {
    if (block is! Map<String, dynamic>) continue;
    final blockType = block['type'] as String?;

    if (blockType == 'tool_use') {
      return ToolUseBlock(
        name: block['name'] as String? ?? 'unknown',
        id: block['id'] as String? ?? '',
        input: block['input'] as Map<String, dynamic>? ?? {},
      );
    }

    if (blockType == 'tool_result') {
      return ToolResultBlock(
        toolId: block['tool_use_id'] as String? ?? '',
        output: block['content'] as String? ?? '',
        isError: block['is_error'] as bool? ?? false,
      );
    }
  }

  return null;
}

ClaudeMessage _parseControlRequest(Map<String, dynamic> json) {
  final requestId = json['request_id'] as String? ?? '';
  final request = json['request'] as Map<String, dynamic>? ?? {};
  final subtype = request['subtype'] as String? ?? 'unknown';
  return ControlRequest(requestId: requestId, subtype: subtype, data: request);
}

ClaudeMessage _parseResult(Map<String, dynamic> json) {
  final usage = json['usage'] as Map<String, dynamic>?;
  return TurnResult(
    stopReason: json['is_error'] == true ? 'error' : json['stop_reason'] as String?,
    costUsd: (json['total_cost_usd'] as num?)?.toDouble(),
    durationMs: json['duration_ms'] as int?,
    inputTokens: usage?['input_tokens'] as int?,
    outputTokens: usage?['output_tokens'] as int?,
    cacheReadInputTokens: usage?['cache_read_input_tokens'] as int?,
    cacheCreationInputTokens: usage?['cache_creation_input_tokens'] as int?,
  );
}
