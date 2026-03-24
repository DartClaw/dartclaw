import 'dart:convert';

import 'canonical_tool.dart';
import 'codex_protocol_utils.dart';
import 'protocol_adapter.dart';
import 'protocol_message.dart';

/// Codex app-server implementation of [ProtocolAdapter].
class CodexProtocolAdapter implements ProtocolAdapter {
  static const String _clientName = 'dartclaw';
  static const String _clientVersion = '0.9.0';

  @override
  ProtocolMessage? parseLine(String line) {
    if (line.trim().isEmpty) return null;

    final decoded = codexDecodeJsonObject(line);
    if (decoded == null) return null;

    final method = codexStringValue(decoded['method']);
    final id = decoded['id'];

    if (id != null && (method == 'control/approval' || method == 'approval/request')) {
      return ControlRequest(
        requestId: '$id',
        subtype: 'approval',
        data: codexMapValue(decoded['params']) ?? const <String, dynamic>{},
      );
    }

    if (method != null) {
      final params = codexMapValue(decoded['params']) ?? const <String, dynamic>{};
      return switch (method) {
        'item/agentMessage/delta' => _extractAgentMessageDelta(params),
        'item/started' => _extractToolUse(codexMapValue(params['item'])),
        'item/completed' => _extractCompletedItem(codexMapValue(params['item'])),
        'turn/completed' => _extractTurnComplete(params),
        'turn/failed' => const TurnComplete(stopReason: 'error'),
        'turn/started' => null,
        _ => null,
      };
    }

    if (id != null) {
      return _extractResponseMessage(codexMapValue(decoded['result']));
    }

    return null;
  }

  @override
  Map<String, dynamic> buildTurnRequest({
    required String message,
    String? systemPrompt,
    String? threadId,
    List<Map<String, dynamic>>? history,
    Map<String, dynamic>? settings,
    bool resume = false,
  }) {
    final params = <String, dynamic>{
      'input': [
        {'type': 'text', 'text': message},
      ],
    };
    final previousResponseItems = _buildPreviousResponseItems(history);
    if (previousResponseItems.isNotEmpty) {
      params['previousResponseItems'] = previousResponseItems;
    }
    if (settings != null) {
      for (final entry in settings.entries) {
        if (entry.value == null) continue;
        params[switch (entry.key) {
              'approval_policy' => 'approvalPolicy',
              _ => entry.key,
            }] =
            entry.value;
      }
    }
    if (threadId != null) {
      params['threadId'] = threadId;
    }
    if (resume) {
      params['resume'] = true;
    }
    return {'method': 'turn/start', 'params': params};
  }

  List<Map<String, dynamic>> _buildPreviousResponseItems(List<Map<String, dynamic>>? history) {
    if (history == null || history.isEmpty) {
      return const <Map<String, dynamic>>[];
    }

    final items = <Map<String, dynamic>>[];
    for (final message in history) {
      final role = _mapHistoryRole(message['role']);
      if (role == null) continue;

      final text = codexStringifyMessageContent(message['content']);
      items.add({
        'type': 'message',
        'role': role,
        'content': [
          {'type': role == 'assistant' ? 'output_text' : 'input_text', 'text': text},
        ],
      });
    }
    return items;
  }

  String? _mapHistoryRole(Object? role) {
    return switch (codexStringValue(role)) {
      'human' || 'user' => 'user',
      'assistant' => 'assistant',
      _ => null,
    };
  }

  @override
  Map<String, dynamic> buildApprovalResponse(
    String requestId, {
    required bool allow,
    String? toolUseId,
    String? reason,
  }) {
    return {
      'jsonrpc': '2.0',
      'id': requestId,
      'result': {'approved': allow, if (!allow && reason != null) 'reason': reason},
    };
  }

  /// Builds an `initialize` request.
  Map<String, dynamic> buildInitializeRequest({required Object id, Map<String, dynamic>? params}) {
    return {
      'id': id,
      'method': 'initialize',
      'params': <String, dynamic>{
        'clientInfo': <String, dynamic>{'name': _clientName, 'version': _clientVersion},
        ...?params,
      },
    };
  }

  /// Builds an `initialized` notification.
  Map<String, dynamic> buildInitializedNotification({Map<String, dynamic>? params}) {
    return {'method': 'initialized', 'params': params ?? <String, dynamic>{}};
  }

  /// Builds a `thread/start` request.
  Map<String, dynamic> buildThreadStartRequest({required Object id, Map<String, dynamic>? params}) {
    return {'id': id, 'method': 'thread/start', 'params': params ?? <String, dynamic>{}};
  }

  @override
  CanonicalTool? mapToolName(String providerToolName, {String? kind}) {
    return switch (providerToolName) {
      'command_execution' => CanonicalTool.shell,
      'file_change' => switch (kind) {
        'create' => CanonicalTool.fileWrite,
        'update' || 'modify' => CanonicalTool.fileEdit,
        _ => CanonicalTool.fileWrite,
      },
      'mcp_tool_call' => CanonicalTool.mcpCall,
      'web_search' => CanonicalTool.webFetch,
      _ => null,
    };
  }

  ProtocolMessage? _extractResponseMessage(Map<String, dynamic>? result) {
    if (result == null) return null;
    if (result.containsKey('thread_id')) return null;

    final capabilities = codexMapValue(result['capabilities']);
    final tools = _listValue(result['tools']);
    final contextWindow = codexIntValue(capabilities?['context_window']) ?? codexIntValue(result['context_window']);

    if (!result.containsKey('session_id') && capabilities == null && tools == null) {
      return null;
    }

    return SystemInit(
      sessionId: codexStringValue(result['session_id']),
      toolCount: tools?.length ?? 0,
      contextWindow: contextWindow,
    );
  }

  TextDelta? _extractAgentMessageDelta(Map<String, dynamic> params) {
    final text = codexStringValue(params['delta']) ?? codexStringValue(params['text']);
    if (text == null) return null;
    return TextDelta(text);
  }

  ToolUse? _extractToolUse(Map<String, dynamic>? item) {
    if (item == null) return null;

    final itemType = codexStringValue(item['type']);
    if (itemType == null) return null;

    return switch (itemType) {
      'command_execution' => _buildCommandExecutionToolUse(item),
      'file_change' => _buildFileChangeToolUse(item),
      'mcp_tool_call' => _buildMcpToolUse(item),
      'web_search' => _buildWebSearchToolUse(item),
      _ => _buildUnknownToolUse(item, itemType),
    };
  }

  ToolUse? _buildCommandExecutionToolUse(Map<String, dynamic> item) {
    final name = mapToolName('command_execution');
    if (name == null) return null;

    return ToolUse(
      name: name.stableName,
      id: codexStringValue(item['id']) ?? '',
      input: {'command': codexStringValue(item['command']) ?? ''},
    );
  }

  ToolUse? _buildFileChangeToolUse(Map<String, dynamic> item) {
    final change = _primaryFileChange(item);
    final kind = codexStringValue(change?['kind']) ?? codexStringValue(item['kind']);
    final path = codexStringValue(change?['path']) ?? codexStringValue(item['path']) ?? '';
    final name = mapToolName('file_change', kind: kind);
    final toolName = name?.stableName ?? 'codex:file_change';

    return ToolUse(name: toolName, id: codexStringValue(item['id']) ?? '', input: {'path': path, 'kind': kind ?? ''});
  }

  ToolUse? _buildMcpToolUse(Map<String, dynamic> item) {
    final name = mapToolName('mcp_tool_call');
    if (name == null) return null;

    return ToolUse(
      name: name.stableName,
      id: codexStringValue(item['id']) ?? '',
      input: {
        'server': codexStringValue(item['server']) ?? '',
        'tool': codexStringValue(item['tool']) ?? '',
        'arguments': codexMapValue(item['arguments']) ?? const <String, dynamic>{},
      },
    );
  }

  ToolUse? _buildWebSearchToolUse(Map<String, dynamic> item) {
    final name = mapToolName('web_search');
    if (name == null) return null;

    final input = <String, dynamic>{};
    for (final entry in item.entries) {
      if (entry.key == 'id' || entry.key == 'type') continue;
      input[entry.key] = entry.value;
    }

    return ToolUse(name: name.stableName, id: codexStringValue(item['id']) ?? '', input: input);
  }

  ProtocolMessage? _extractCompletedItem(Map<String, dynamic>? item) {
    if (item == null) return null;

    final itemType = codexStringValue(item['type']);
    if (itemType == null) return null;

    if (itemType == 'agent_message') {
      final text = codexStringValue(item['text']) ?? codexStringValue(item['delta']);
      if (text == null) return null;
      return TextDelta(text);
    }

    return _extractToolResult(item);
  }

  ToolResult? _extractToolResult(Map<String, dynamic> item) {
    final itemType = codexStringValue(item['type']);
    if (itemType == null) return null;

    return switch (itemType) {
      'command_execution' => ToolResult(
        toolId: codexStringValue(item['id']) ?? '',
        output: codexStringValue(item['aggregated_output']) ?? _errorSummary(item['error']) ?? '',
        isError: (codexIntValue(item['exit_code']) ?? 0) != 0,
      ),
      'file_change' => ToolResult(toolId: codexStringValue(item['id']) ?? '', output: _summarizeFileChanges(item)),
      'mcp_tool_call' => _buildMcpToolResult(item),
      'web_search' => ToolResult(
        toolId: codexStringValue(item['id']) ?? '',
        output: _stringifyValue(item['result'] ?? item['results'] ?? item['summary'] ?? item['text']) ?? '',
        isError: item['error'] != null,
      ),
      _ => _buildUnknownToolResult(item, itemType),
    };
  }

  ToolResult _buildMcpToolResult(Map<String, dynamic> item) {
    final error = item['error'];
    final output = _stringifyValue(item['result']) ?? _errorSummary(error) ?? '';
    return ToolResult(toolId: codexStringValue(item['id']) ?? '', output: output, isError: error != null);
  }

  ToolUse _buildUnknownToolUse(Map<String, dynamic> item, String itemType) {
    return ToolUse(name: 'codex:$itemType', id: codexStringValue(item['id']) ?? '', input: _unknownItemInput(item));
  }

  ToolResult _buildUnknownToolResult(Map<String, dynamic> item, String itemType) {
    final details = _unknownItemInput(item);
    return ToolResult(
      toolId: codexStringValue(item['id']) ?? '',
      output: 'codex:$itemType ${_stringifyValue(details) ?? ''}'.trim(),
      isError: item['error'] != null,
    );
  }

  Map<String, dynamic> _unknownItemInput(Map<String, dynamic> item) {
    final input = <String, dynamic>{};
    for (final entry in item.entries) {
      if (entry.key == 'id' || entry.key == 'type') continue;
      input[entry.key] = entry.value;
    }
    return input;
  }

  TurnComplete _extractTurnComplete(Map<String, dynamic> params) {
    final usage = codexMapValue(params['usage']) ?? const <String, dynamic>{};
    return TurnComplete(
      stopReason: 'completed',
      costUsd: null,
      inputTokens: codexIntValue(usage['input_tokens']),
      outputTokens: codexIntValue(usage['output_tokens']),
      cacheReadTokens: codexIntValue(usage['cached_input_tokens']),
      cacheWriteTokens: 0,
    );
  }

  Map<String, dynamic>? _primaryFileChange(Map<String, dynamic> item) {
    final changes = _listValue(item['changes']);
    if (changes == null || changes.isEmpty) return null;
    return codexMapValue(changes.first);
  }

  String _summarizeFileChanges(Map<String, dynamic> item) {
    final changes = _listValue(item['changes']);
    if (changes == null || changes.isEmpty) {
      final kind = codexStringValue(item['kind']) ?? 'change';
      final path = codexStringValue(item['path']) ?? '<unknown>';
      return '$kind $path';
    }

    final summaries = <String>[];
    for (final rawChange in changes) {
      final change = codexMapValue(rawChange);
      if (change == null) continue;
      final kind = codexStringValue(change['kind']) ?? 'change';
      final path = codexStringValue(change['path']) ?? '<unknown>';
      summaries.add('$kind $path');
    }

    if (summaries.isEmpty) {
      return 'file_change completed';
    }

    return summaries.join('\n');
  }

  List<dynamic>? _listValue(Object? value) {
    if (value is List<dynamic>) return value;
    if (value is List) return value.cast<dynamic>();
    return null;
  }

  String? _errorSummary(Object? error) {
    final map = codexMapValue(error);
    if (map == null) return _stringifyValue(error);
    return codexStringValue(map['message']) ?? _stringifyValue(map);
  }

  String? _stringifyValue(Object? value) {
    if (value == null) return null;
    if (value is String) return value;
    try {
      return jsonEncode(value);
    } on JsonUnsupportedObjectError {
      return '$value';
    }
  }
}
