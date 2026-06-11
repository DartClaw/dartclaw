import 'dart:convert';

import 'acp_client.dart';
import 'protocol_message.dart';

/// Maps ACP JSON-RPC session events into DartClaw protocol messages.
final class AcpProtocolAdapter {
  /// Converts one raw ACP JSON-RPC line into provider-agnostic protocol messages.
  List<ProtocolMessage> parseLine(String line) {
    Object? decoded;
    try {
      decoded = jsonDecode(line);
    } on FormatException catch (error) {
      return [ProtocolDiagnostic(message: 'Malformed ACP JSON-RPC line: ${error.message}')];
    }
    if (decoded is! Map) {
      return const [ProtocolDiagnostic(message: 'ACP JSON-RPC line is not an object')];
    }
    final message = Map<String, dynamic>.from(decoded);
    if (message['method'] == 'session/update') {
      final params = message['params'];
      return messagesForSessionUpdate(params is Map ? Map<String, dynamic>.from(params) : const <String, dynamic>{});
    }
    final method = _stringValue(message['method']);
    if (method != null && method.startsWith('system/')) {
      return [ProtocolDiagnostic(message: 'Skipped unsupported ACP method "$method"', method: method)];
    }
    return const <ProtocolMessage>[];
  }

  /// Converts ACP `session/update` parameters into provider-agnostic protocol messages.
  List<ProtocolMessage> messagesForSessionUpdate(Map<String, dynamic> params) {
    final update = _updatePayload(params);
    final updateType = _updateType(update);
    if (updateType == null) {
      return const [
        ProtocolDiagnostic(
          message: 'Skipped malformed ACP session/update without an update type',
          method: 'session/update',
        ),
      ];
    }

    switch (updateType) {
      case 'agent_message_chunk':
        final text = _text(update);
        return text == null ? [_missingText(updateType)] : [TextDelta(text)];
      case 'user_message_chunk':
        final text = _text(update);
        return text == null ? [_missingText(updateType)] : [ProgressMessage(text: text, kind: updateType)];
      case 'agent_thought_chunk':
        final text = _text(update);
        return text == null ? [_missingText(updateType)] : [ProgressMessage(text: text, kind: updateType)];
      case 'tool_call':
      case 'tool_use':
        return [_toolUse(update, updateType)];
      case 'tool_call_update':
      case 'tool_update':
        return _toolUpdate(update, updateType);
      case 'tool_call_result':
      case 'tool_result':
      case 'tool_completed':
        return [_toolResult(update, updateType)];
      case 'session_info_update':
        return [
          SessionMetadataUpdate(
            title: _stringValue(update['title']),
            metadata: _metadata(update, exclude: const {'type', 'sessionUpdate', 'title'}),
          ),
        ];
      case 'usage_update':
      case 'context_update':
        return [
          SessionMetadataUpdate(metadata: _metadata(update, exclude: const {'type', 'sessionUpdate'})),
        ];
      case 'available_command_update':
      case 'available_commands_update':
      case 'current_mode_update':
      case 'plan_update':
      case 'model_update':
      case 'available-command':
      case 'current-mode':
      case 'plan':
      case 'model':
      case 'system/api_retry':
        return [
          ProtocolDiagnostic(
            message: 'Skipped unsupported optional ACP session/update "$updateType"',
            method: 'session/update',
            updateType: updateType,
          ),
        ];
      default:
        return [
          ProtocolDiagnostic(
            message: 'Skipped unknown ACP session/update "$updateType"',
            method: 'session/update',
            updateType: updateType,
          ),
        ];
    }
  }

  /// Converts a completed prompt result into provider-agnostic protocol messages.
  List<ProtocolMessage> messagesForPromptResult(AcpPromptResult result) {
    return [
      if (result.text.isNotEmpty) TextDelta(result.text),
      if (result.sessionTitle != null || result.metadata.isNotEmpty)
        SessionMetadataUpdate(title: result.sessionTitle, metadata: result.metadata),
      TurnComplete(
        stopReason: result.stopReason,
        inputTokens: result.inputTokens ?? 0,
        outputTokens: result.outputTokens ?? 0,
        cacheReadTokens: result.cacheReadTokens ?? 0,
        cacheWriteTokens: result.cacheWriteTokens ?? 0,
      ),
    ];
  }

  static Map<String, dynamic> _updatePayload(Map<String, dynamic> params) {
    for (final key in const ['update', 'sessionUpdate', 'event', 'item']) {
      final value = params[key];
      if (value is Map) return Map<String, dynamic>.from(value);
    }
    return params;
  }

  static String? _updateType(Map<String, dynamic> update) {
    for (final key in const ['type', 'sessionUpdate', 'kind', 'method']) {
      final value = _stringValue(update[key]);
      if (value != null && value.isNotEmpty) return value;
    }
    return null;
  }

  static String? _text(Map<String, dynamic> update) {
    for (final key in const ['text', 'content', 'delta']) {
      final value = _stringValue(update[key]);
      if (value != null) return value;
    }
    final chunk = update['chunk'];
    if (chunk is Map) return _stringValue(chunk['text']) ?? _stringValue(chunk['content']);
    return null;
  }

  static ProtocolDiagnostic _missingText(String updateType) {
    return ProtocolDiagnostic(
      message: 'Skipped malformed ACP session/update "$updateType" without text',
      method: 'session/update',
      updateType: updateType,
    );
  }

  static ToolUse _toolUse(Map<String, dynamic> update, String updateType) {
    final id =
        _stringValue(update['id']) ??
        _stringValue(update['toolCallId']) ??
        _stringValue(update['tool_call_id']) ??
        'unknown';
    final title =
        _stringValue(update['title']) ?? _stringValue(update['name']) ?? _stringValue(update['toolName']) ?? 'acp_tool';
    final status = _stringValue(update['status']);
    final input = <String, dynamic>{};
    final updateTitle = _stringValue(update['title']);
    if (updateTitle != null) {
      input['title'] = updateTitle;
    }
    if (status != null) {
      input['status'] = status;
    }
    if (update['progress'] != null) {
      input['progress'] = update['progress'];
    }
    final rawInput = update['input'];
    if (rawInput is Map) {
      input.addAll(Map<String, dynamic>.from(rawInput));
    }
    return ToolUse(name: title, id: id, input: input);
  }

  static ToolResult _toolResult(Map<String, dynamic> update, String updateType) {
    final id =
        _stringValue(update['id']) ??
        _stringValue(update['toolCallId']) ??
        _stringValue(update['tool_call_id']) ??
        'unknown';
    final output =
        _stringValue(update['output']) ?? _stringValue(update['content']) ?? _stringValue(update['message']) ?? '';
    final status = _stringValue(update['status'])?.toLowerCase();
    return ToolResult(
      toolId: id,
      output: output,
      isError: update['isError'] == true || status == 'error' || status == 'failed',
    );
  }

  static List<ProtocolMessage> _toolUpdate(Map<String, dynamic> update, String updateType) {
    final status = _stringValue(update['status'])?.toLowerCase();
    if (status == 'completed' ||
        status == 'succeeded' ||
        status == 'success' ||
        status == 'error' ||
        status == 'failed') {
      return [_toolResult(update, updateType)];
    }
    final text =
        _stringValue(update['message']) ??
        _stringValue(update['title']) ??
        (update['progress'] == null ? 'ACP tool update' : 'ACP tool progress ${update['progress']}');
    return [ProgressMessage(text: text, kind: updateType)];
  }

  static Map<String, dynamic> _metadata(Map<String, dynamic> update, {required Set<String> exclude}) {
    final metadata = <String, dynamic>{};
    for (final entry in update.entries) {
      if (!exclude.contains(entry.key)) {
        metadata[entry.key] = entry.value;
      }
    }
    return metadata;
  }
}

String? _stringValue(Object? value) => value is String && value.isNotEmpty ? value : null;
