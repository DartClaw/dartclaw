import 'dart:convert';

import 'base_protocol_adapter.dart' show codexErrorSummary, codexPrimaryFileChange, intValue, mapValue, stringValue;
import 'canonical_tool.dart';
import 'protocol_message.dart';

export 'base_protocol_adapter.dart'
    show
        decodeJsonObject,
        intValue,
        listValue,
        mapValue,
        stringifyMessageContent,
        stringifyValue,
        stringValue,
        warnOnUnmappedToolName,
        codexErrorSummary,
        codexMapToolName,
        codexPrimaryFileChange,
        codexUnknownItemInput;

ToolUse? codexBuildCommandExecutionToolUse(Map<String, dynamic> item, {required CanonicalTool? tool}) {
  if (tool == null) {
    return null;
  }

  return ToolUse(
    name: tool.stableName,
    id: stringValue(item['id']) ?? '',
    input: {'command': stringValue(item['command']) ?? ''},
  );
}

ToolUse codexBuildFileChangeToolUse(
  Map<String, dynamic> item, {
  required CanonicalTool? Function(String providerToolName, {String? kind}) mapToolName,
  bool preferPrimaryChange = false,
  String fallbackName = 'codex:file_change',
}) {
  final change = preferPrimaryChange ? codexPrimaryFileChange(item) : null;
  final kind = stringValue(change?['kind']) ?? stringValue(item['kind']);
  final path = stringValue(change?['path']) ?? stringValue(item['path']) ?? '';
  final tool = mapToolName('file_change', kind: kind);

  return ToolUse(
    name: tool?.stableName ?? fallbackName,
    id: stringValue(item['id']) ?? '',
    input: {'path': path, 'kind': kind ?? ''},
  );
}

ToolUse? codexBuildMcpToolUse(Map<String, dynamic> item, {required CanonicalTool? tool}) {
  if (tool == null) {
    return null;
  }

  return ToolUse(
    name: tool.stableName,
    id: stringValue(item['id']) ?? '',
    input: {
      'server': stringValue(item['server']) ?? '',
      'tool': stringValue(item['tool']) ?? '',
      'arguments': mapValue(item['arguments']) ?? const <String, dynamic>{},
    },
  );
}

TextDelta? codexBuildAgentMessageDelta(Map<String, dynamic> item, {bool allowDeltaFallback = true}) {
  final text = stringValue(item['text']) ?? (allowDeltaFallback ? stringValue(item['delta']) : null);
  if (text == null) {
    return null;
  }
  return TextDelta(text);
}

ToolResult codexBuildCommandExecutionToolResult(Map<String, dynamic> item) {
  return ToolResult(
    toolId: stringValue(item['id']) ?? '',
    output: stringValue(item['aggregated_output']) ?? codexErrorSummary(item['error']) ?? '',
    isError: (intValue(item['exit_code']) ?? 0) != 0,
  );
}

ToolResult codexBuildJsonFieldToolResult(Map<String, dynamic> item, {required String field, bool isError = false}) {
  return ToolResult(toolId: stringValue(item['id']) ?? '', output: jsonEncode(item[field]), isError: isError);
}

TurnComplete codexBuildTurnComplete(Map<String, dynamic> usage, {required String stopReason}) {
  // OpenAI/Codex reports input_tokens as TOTAL input (cached included). Anthropic
  // reports it as FRESH-only with cache_read_input_tokens as a separate bucket.
  // Normalize to the Anthropic convention so downstream sums mean the same thing
  // across harnesses.
  final rawInput = intValue(usage['input_tokens']);
  final rawCached = intValue(usage['cached_input_tokens']);
  final int? freshInput;
  if (rawInput == null) {
    freshInput = null;
  } else {
    final diff = rawInput - (rawCached ?? 0);
    freshInput = diff < 0 ? 0 : diff;
  }
  return TurnComplete(
    stopReason: stopReason,
    inputTokens: freshInput,
    outputTokens: intValue(usage['output_tokens']),
    cacheReadTokens: rawCached,
    cacheWriteTokens: 0,
  );
}
