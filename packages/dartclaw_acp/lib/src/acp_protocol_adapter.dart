import 'dart:convert';

import 'acp_client.dart';
import 'acp_errors.dart';

import 'package:dartclaw_core/dartclaw_core.dart';

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
    final updateValue = params['update'];
    if (updateValue is! Map) throw _protocolViolation('missing update envelope', params);
    final update = Map<String, dynamic>.from(updateValue);
    final updateType = _stringValue(update['sessionUpdate']);
    if (updateType == null) throw _protocolViolation('missing sessionUpdate discriminator', params);

    switch (updateType) {
      case 'agent_message_chunk':
        final text = _chunkText(update, params);
        return text.isEmpty ? const <ProtocolMessage>[] : [TextDelta(text)];
      case 'user_message_chunk':
        final text = _chunkText(update, params);
        return text.isEmpty ? const <ProtocolMessage>[] : [ProgressMessage(text: text, kind: updateType)];
      case 'agent_thought_chunk':
        final text = _chunkText(update, params);
        return text.isEmpty ? const <ProtocolMessage>[] : [ProgressMessage(text: text, kind: updateType)];
      case 'tool_call':
        return [_toolUse(update, updateType)];
      case 'tool_call_update':
        return _toolUpdate(update, updateType);
      case 'session_info_update':
        return [
          SessionMetadataUpdate(
            title: _stringValue(update['title']),
            metadata: _metadata(update, exclude: const {'sessionUpdate', 'title'}),
          ),
        ];
      case 'usage_update':
        return [
          SessionMetadataUpdate(metadata: _metadata(update, exclude: const {'sessionUpdate'})),
        ];
      case 'available_commands_update':
      case 'current_mode_update':
      case 'config_option_update':
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

  static String _chunkText(Map<String, dynamic> update, Map<String, dynamic> payload) {
    final chunk = update['content'];
    final content = chunk is Map ? chunk['content'] : null;
    if (content is! Map || content['type'] != 'text' || content['text'] is! String) {
      throw _protocolViolation('message chunk missing text content block', payload);
    }
    return content['text'] as String;
  }

  static AcpHarnessException _protocolViolation(String reason, Map<String, dynamic> payload) => AcpHarnessException(
    AcpHarnessErrorCode.protocolViolation,
    'Invalid ACP session/update: $reason',
    diagnostics: {'payload': payload},
  );

  static ToolUse _toolUse(Map<String, dynamic> update, String updateType) {
    final id = _stringValue(update['toolCallId']) ?? 'unknown';
    final title = _stringValue(update['title']) ?? 'acp_tool';
    final status = _stringValue(update['status']);
    final input = <String, dynamic>{};
    final updateTitle = _stringValue(update['title']);
    if (updateTitle != null) {
      input['title'] = updateTitle;
    }
    if (status != null) {
      input['status'] = status;
    }
    final rawInput = update['rawInput'];
    if (rawInput is Map) {
      input.addAll(Map<String, dynamic>.from(rawInput));
    }
    return ToolUse(name: title, id: id, input: input);
  }

  static ToolResultMessage _toolResult(Map<String, dynamic> update, String updateType) {
    final id = _stringValue(update['toolCallId']) ?? 'unknown';
    final rawOutput = update['rawOutput'];
    final output = rawOutput is String
        ? rawOutput
        : rawOutput == null
        ? ''
        : jsonEncode(rawOutput);
    final status = _stringValue(update['status'])?.toLowerCase();
    return ToolResultMessage(
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
    final text = _stringValue(update['title']) ?? 'ACP tool update';
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
