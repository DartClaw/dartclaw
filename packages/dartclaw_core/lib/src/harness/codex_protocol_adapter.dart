import 'canonical_tool.dart';
import 'base_protocol_adapter.dart';
import 'codex_protocol_utils.dart';
import 'protocol_message.dart';

/// Codex app-server implementation of [ProtocolAdapter].
class CodexProtocolAdapter extends BaseProtocolAdapter {
  static const String _clientName = 'dartclaw';
  static const String _clientVersion = '0.9.0';

  @override
  ProtocolMessage? parseLine(String line) {
    final decoded = decodeJsonObject(line);
    if (decoded == null) return null;

    final method = stringValue(decoded['method']);
    final id = decoded['id'];

    if (id != null && (method == 'control/approval' || method == 'approval/request')) {
      return ControlRequest(
        requestId: '$id',
        subtype: 'approval',
        data: mapValue(decoded['params']) ?? const <String, dynamic>{},
      );
    }

    if (method != null) {
      final params = mapValue(decoded['params']) ?? const <String, dynamic>{};
      return switch (method) {
        'item/agentMessage/delta' => _extractAgentMessageDelta(params),
        'item/started' => _extractToolUse(mapValue(params['item'])),
        'item/completed' => _extractCompletedItem(mapValue(params['item'])),
        'turn/completed' => _extractTurnComplete(params),
        'turn/failed' => const TurnComplete(stopReason: 'error'),
        'turn/started' => null,
        _ => null,
      };
    }

    if (id != null) {
      return _extractResponseMessage(mapValue(decoded['result']));
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

      final text = stringifyMessageContent(message['content']);
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
    return switch (stringValue(role)) {
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
      'web_search' => CanonicalTool.webFetch,
      _ => codexMapToolName(providerToolName, kind: kind),
    };
  }

  ProtocolMessage? _extractResponseMessage(Map<String, dynamic>? result) {
    if (result == null) return null;
    if (result.containsKey('thread_id')) return null;

    final capabilities = mapValue(result['capabilities']);
    final tools = listValue(result['tools']);
    final contextWindow = intValue(capabilities?['context_window']) ?? intValue(result['context_window']);

    if (!result.containsKey('session_id') && capabilities == null && tools == null) {
      return null;
    }

    return SystemInit(
      sessionId: stringValue(result['session_id']),
      toolCount: tools?.length ?? 0,
      contextWindow: contextWindow,
    );
  }

  TextDelta? _extractAgentMessageDelta(Map<String, dynamic> params) {
    final text = stringValue(params['delta']) ?? stringValue(params['text']);
    if (text == null) return null;
    return TextDelta(text);
  }

  ToolUse? _extractToolUse(Map<String, dynamic>? item) {
    if (item == null) return null;

    final itemType = stringValue(item['type']);
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
    return codexBuildCommandExecutionToolUse(item, tool: mapToolName('command_execution'));
  }

  ToolUse? _buildFileChangeToolUse(Map<String, dynamic> item) {
    return codexBuildFileChangeToolUse(item, mapToolName: mapToolName, preferPrimaryChange: true);
  }

  ToolUse? _buildMcpToolUse(Map<String, dynamic> item) {
    return codexBuildMcpToolUse(item, tool: mapToolName('mcp_tool_call'));
  }

  ToolUse? _buildWebSearchToolUse(Map<String, dynamic> item) {
    final name = mapToolName('web_search');
    if (name == null) return null;

    return ToolUse(name: name.stableName, id: stringValue(item['id']) ?? '', input: codexUnknownItemInput(item));
  }

  ProtocolMessage? _extractCompletedItem(Map<String, dynamic>? item) {
    if (item == null) return null;

    final itemType = stringValue(item['type']);
    if (itemType == null) return null;

    if (itemType == 'agent_message') {
      return codexBuildAgentMessageDelta(item);
    }

    return _extractToolResult(item);
  }

  ToolResult? _extractToolResult(Map<String, dynamic> item) {
    final itemType = stringValue(item['type']);
    if (itemType == null) return null;

    return switch (itemType) {
      'command_execution' => codexBuildCommandExecutionToolResult(item),
      'file_change' => ToolResult(toolId: stringValue(item['id']) ?? '', output: _summarizeFileChanges(item)),
      'mcp_tool_call' => _buildMcpToolResult(item),
      'web_search' => ToolResult(
        toolId: stringValue(item['id']) ?? '',
        output: stringifyValue(item['result'] ?? item['results'] ?? item['summary'] ?? item['text']) ?? '',
        isError: item['error'] != null,
      ),
      _ => _buildUnknownToolResult(item, itemType),
    };
  }

  ToolResult _buildMcpToolResult(Map<String, dynamic> item) {
    final error = item['error'];
    final output = stringifyValue(item['result']) ?? codexErrorSummary(error) ?? '';
    return ToolResult(toolId: stringValue(item['id']) ?? '', output: output, isError: error != null);
  }

  ToolUse _buildUnknownToolUse(Map<String, dynamic> item, String itemType) {
    return ToolUse(name: 'codex:$itemType', id: stringValue(item['id']) ?? '', input: codexUnknownItemInput(item));
  }

  ToolResult _buildUnknownToolResult(Map<String, dynamic> item, String itemType) {
    final details = codexUnknownItemInput(item);
    return ToolResult(
      toolId: stringValue(item['id']) ?? '',
      output: 'codex:$itemType ${stringifyValue(details) ?? ''}'.trim(),
      isError: item['error'] != null,
    );
  }

  TurnComplete _extractTurnComplete(Map<String, dynamic> params) {
    final usage = mapValue(params['usage']) ?? const <String, dynamic>{};
    return codexBuildTurnComplete(usage, stopReason: 'completed');
  }

  String _summarizeFileChanges(Map<String, dynamic> item) {
    final changes = listValue(item['changes']);
    if (changes == null || changes.isEmpty) {
      final kind = stringValue(item['kind']) ?? 'change';
      final path = stringValue(item['path']) ?? '<unknown>';
      return '$kind $path';
    }

    final summaries = <String>[];
    for (final rawChange in changes) {
      final change = mapValue(rawChange);
      if (change == null) continue;
      final kind = stringValue(change['kind']) ?? 'change';
      final path = stringValue(change['path']) ?? '<unknown>';
      summaries.add('$kind $path');
    }

    if (summaries.isEmpty) {
      return 'file_change completed';
    }

    return summaries.join('\n');
  }
}
