import 'dart:convert';

import 'package:logging/logging.dart';

final _log = Logger('ClaudeProtocol');

/// Env vars to clear to prevent claude nesting detection.
/// Shared between [ClaudeCodeHarness] and [ClaudeBinaryClassifier].
const claudeNestingEnvVars = ['CLAUDECODE', 'CLAUDE_CODE_ENTRYPOINT', 'CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS'];

// ---------------------------------------------------------------------------
// Sealed class hierarchy for claude binary JSONL messages
// ---------------------------------------------------------------------------

sealed class ClaudeMessage {}

/// System init event — emitted once at session start.
final class SystemInit extends ClaudeMessage {
  final String? sessionId;
  final int toolCount;
  final int? contextWindow;

  SystemInit({this.sessionId, required this.toolCount, this.contextWindow});

  @override
  String toString() => 'SystemInit(sessionId: $sessionId, toolCount: $toolCount)';
}

/// Streaming text delta from `content_block_delta`.
final class StreamTextDelta extends ClaudeMessage {
  final String text;

  StreamTextDelta(this.text);

  @override
  String toString() => 'StreamTextDelta(text: ${text.length > 80 ? '${text.substring(0, 80)}...' : text})';
}

/// Tool use block from an `assistant` message.
final class ToolUseBlock extends ClaudeMessage {
  final String name;
  final String id;
  final Map<String, dynamic> input;

  ToolUseBlock({required this.name, required this.id, required this.input});

  @override
  String toString() => 'ToolUseBlock(name: $name, id: $id)';
}

/// Tool result block from an `assistant` message.
final class ToolResultBlock extends ClaudeMessage {
  final String toolId;
  final String output;
  final bool isError;

  ToolResultBlock({required this.toolId, required this.output, this.isError = false});

  @override
  String toString() => 'ToolResultBlock(toolId: $toolId, isError: $isError)';
}

/// Control request from the claude binary (e.g. `can_use_tool`, `hook_callback`).
final class ControlRequest extends ClaudeMessage {
  final String requestId;
  final String subtype;
  final Map<String, dynamic> data;

  ControlRequest({required this.requestId, required this.subtype, required this.data});

  @override
  String toString() => 'ControlRequest(requestId: $requestId, subtype: $subtype)';
}

/// Turn result — signals turn completion.
final class TurnResult extends ClaudeMessage {
  final String? stopReason;
  final double? costUsd;
  final int? durationMs;
  final int? inputTokens;
  final int? outputTokens;

  TurnResult({this.stopReason, this.costUsd, this.durationMs, this.inputTokens, this.outputTokens});

  int get totalTokens => (inputTokens ?? 0) + (outputTokens ?? 0);

  @override
  String toString() => 'TurnResult(stopReason: $stopReason, costUsd: $costUsd, durationMs: $durationMs, '
      'inputTokens: $inputTokens, outputTokens: $outputTokens)';
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
  if (subtype != 'init') return null;

  final sessionId = json['session_id'] as String?;
  final tools = json['tools'] as List?;
  final contextWindow = json['context_window'] as int?;
  return SystemInit(sessionId: sessionId, toolCount: tools?.length ?? 0, contextWindow: contextWindow);
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
    stopReason: json['stop_reason'] as String?,
    costUsd: (json['total_cost_usd'] as num?)?.toDouble(),
    durationMs: json['duration_ms'] as int?,
    inputTokens: usage?['input_tokens'] as int?,
    outputTokens: usage?['output_tokens'] as int?,
  );
}
