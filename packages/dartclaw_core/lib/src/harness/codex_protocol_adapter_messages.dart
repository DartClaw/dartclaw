part of 'codex_protocol_adapter.dart';

extension _CodexProtocolMessages on CodexProtocolAdapter {
  ProtocolMessage? _extractResponseMessage(Map<String, dynamic>? result) {
    if (result == null || result.containsKey('thread_id')) return null;
    final payload = mapValue(result['response']) ?? result;
    final capabilities = mapValue(payload['capabilities']);
    final tools = listValue(payload['tools']);
    final contextWindow = intValue(capabilities?['context_window']) ?? intValue(payload['context_window']);
    if (!payload.containsKey('session_id') && capabilities == null && tools == null) return null;
    return SystemInit(
      sessionId: stringValue(payload['session_id']),
      toolCount: tools?.length ?? 0,
      contextWindow: contextWindow,
    );
  }

  TextDelta? _extractAgentMessageDelta(Map<String, dynamic> params) {
    final text = stringValue(params['delta']) ?? stringValue(params['text']);
    return text == null ? null : TextDelta(text);
  }

  ControlRequest _extractCommandApproval(String requestId, Map<String, dynamic> params) {
    final itemId = stringValue(params['itemId']) ?? '';
    final startedItem = _startedItems[itemId];
    final command = stringValue(params['command']) ?? stringValue(startedItem?['command']);
    final cwd = stringValue(params['cwd']) ?? stringValue(startedItem?['cwd']);
    final reason = stringValue(params['reason']);
    final availableDecisions = listValue(params['availableDecisions']);
    _commandDenials[requestId] = switch (availableDecisions) {
      null when params['availableDecisions'] == null => _CommandDenial.decline,
      final decisions? when decisions.contains('decline') => _CommandDenial.decline,
      final decisions? when decisions.contains('cancel') => _CommandDenial.cancel,
      _ => _CommandDenial.error,
    };
    final unsupportedReasons = <String>[
      if (command == null || command.trim().isEmpty) 'missing command',
      if (params['additionalPermissions'] != null) 'additional permissions',
      if (params['networkApprovalContext'] != null) 'network approval context',
      if (params['environmentId'] != null) 'remote environment',
    ];
    if (unsupportedReasons.isNotEmpty) {
      return ControlRequest(
        requestId: requestId,
        subtype: 'unsupported_command_request',
        data: {...params, 'dartclawUnsupportedReasons': unsupportedReasons},
      );
    }
    if (params['availableDecisions'] != null &&
        (availableDecisions == null || !availableDecisions.contains('accept'))) {
      return ControlRequest(
        requestId: requestId,
        subtype: 'unsupported_command_request',
        data: {
          ...params,
          'dartclawUnsupportedReasons': ['accept decision unavailable'],
        },
      );
    }
    return ControlRequest(
      requestId: requestId,
      subtype: 'approval',
      data: {
        'tool_name': 'command_execution',
        'tool_use_id': itemId,
        'tool_input': {'command': command, 'cwd': ?cwd, 'reason': ?reason},
      },
    );
  }

  ControlRequest _extractFileChangeApproval(String requestId, Map<String, dynamic> params) {
    final itemId = stringValue(params['itemId']) ?? '';
    final input = <String, dynamic>{};
    final startedItem = _startedItems[itemId];
    if (startedItem != null) {
      for (final entry in startedItem.entries) {
        if (entry.key != 'type' && entry.key != 'status') input[entry.key] = entry.value;
      }
    }
    final reason = stringValue(params['reason']);
    final grantRoot = stringValue(params['grantRoot']);
    if (reason != null) input['reason'] = reason;
    if (grantRoot != null) input['grantRoot'] = grantRoot;
    return ControlRequest(
      requestId: requestId,
      subtype: 'approval',
      data: {'tool_name': 'file_change', 'tool_use_id': itemId, 'tool_input': input},
    );
  }

  ControlRequest _extractMcpApproval(String requestId, Map<String, dynamic> params) {
    final metadata = mapValue(params['_meta']);
    return ControlRequest(
      requestId: requestId,
      subtype: 'approval',
      data: {
        'tool_name': 'mcp_tool_call',
        'tool_use_id': requestId,
        'tool_input': {
          'server': stringValue(params['serverName']) ?? '',
          'tool': stringValue(metadata?['tool_name']) ?? '',
          'arguments': mapValue(metadata?['tool_params']) ?? const <String, dynamic>{},
        },
      },
    );
  }

  String _registerApproval(Object wireId, [_ApprovalResponseKind? responseKind]) {
    final baseId = '$wireId';
    var requestId = baseId;
    var suffix = 1;
    while (_approvalWireIds.containsKey(requestId)) {
      requestId = '$baseId#${suffix++}';
    }
    _approvalWireIds[requestId] = wireId;
    if (responseKind != null) _approvalResponseKinds[requestId] = responseKind;
    return requestId;
  }

  ProtocolMessage? _handleStartedItem(Map<String, dynamic>? item) {
    final itemId = stringValue(item?['id']);
    if (item != null && itemId != null && itemId.isNotEmpty) _startedItems[itemId] = item;
    return _extractStartedItem(item);
  }

  ProtocolMessage? _handleCompletedItem(Map<String, dynamic>? item) {
    final message = _extractCompletedItem(item);
    final itemId = stringValue(item?['id']);
    if (itemId != null) _startedItems.remove(itemId);
    return message;
  }

  TurnComplete _handleTurnComplete(Map<String, dynamic> params) {
    _startedItems.clear();
    return _extractTurnComplete(params);
  }

  TurnComplete _handleTurnFailed() {
    _startedItems.clear();
    return const TurnComplete(stopReason: 'error');
  }

  ProtocolMessage? _extractStartedItem(Map<String, dynamic>? item) {
    if (item == null) return null;
    final itemType = stringValue(item['type']);
    if (itemType == 'contextCompaction') return CompactionStarted(id: stringValue(item['id']));
    if (itemType == 'reasoning') return _buildProviderProgress(item, 'reasoning');
    return _extractToolUse(item);
  }

  ToolUse? _extractToolUse(Map<String, dynamic>? item) {
    if (item == null) return null;
    final itemType = _normalizeItemType(stringValue(item['type']));
    if (itemType == null) return null;
    return switch (itemType) {
      'command_execution' => codexBuildCommandExecutionToolUse(item, tool: mapToolName('command_execution')),
      'file_change' => codexBuildFileChangeToolUse(item, mapToolName: mapToolName, preferPrimaryChange: true),
      'mcp_tool_call' => codexBuildMcpToolUse(
        item,
        tool: mapToolName('mcp_tool_call', mcpServer: stringValue(item['server']), mcpTool: stringValue(item['tool'])),
      ),
      'web_search' => _buildWebSearchToolUse(item),
      'user_message' || 'agent_message' => null,
      _ => ToolUse(name: 'codex:$itemType', id: stringValue(item['id']) ?? '', input: codexUnknownItemInput(item)),
    };
  }

  ToolUse? _buildWebSearchToolUse(Map<String, dynamic> item) {
    final name = mapToolName('web_search');
    return name == null
        ? null
        : ToolUse(name: name.stableName, id: stringValue(item['id']) ?? '', input: codexUnknownItemInput(item));
  }

  ProtocolMessage? _extractCompletedItem(Map<String, dynamic>? item) {
    if (item == null) return null;
    final rawItemType = stringValue(item['type']);
    if (rawItemType == null) return null;
    if (rawItemType == 'agent_message') return codexBuildAgentMessageDelta(item);
    final itemType = _normalizeItemType(rawItemType)!;
    if (itemType == 'agent_message' || itemType == 'user_message') return null;
    if (itemType == 'contextCompaction') return CompactionCompleted(id: stringValue(item['id']));
    if (itemType == 'reasoning') return _buildProviderProgress(item, 'reasoning');
    return _extractToolResult(item);
  }

  ProgressMessage _buildProviderProgress(Map<String, dynamic> item, String itemType) {
    final text =
        stringifyValue(item['summary'] ?? item['text'] ?? item['content'] ?? item['details']) ??
        stringifyValue(codexUnknownItemInput(item)) ??
        '';
    return ProgressMessage(text: text, kind: 'codex_$itemType');
  }

  ToolResult? _extractToolResult(Map<String, dynamic> item) {
    final itemType = _normalizeItemType(stringValue(item['type']));
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
    return ToolResult(
      toolId: stringValue(item['id']) ?? '',
      output: stringifyValue(item['result']) ?? codexErrorSummary(error) ?? '',
      isError: error != null,
    );
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
    final turn = mapValue(params['turn']);
    if (stringValue(turn?['status']) == 'failed' || turn?['error'] != null) {
      return const TurnComplete(stopReason: 'error');
    }
    return codexBuildTurnComplete(mapValue(params['usage']) ?? const {}, stopReason: 'completed');
  }

  ProtocolMessage? _extractConfigWarning(Map<String, dynamic> params) {
    final summary = stringValue(params['summary'])?.trim();
    if (summary == null || summary.isEmpty) return null;
    if (!summary.contains('Project-local config, hooks, and exec policies are disabled')) {
      return ProtocolDiagnostic(message: summary, method: 'configWarning');
    }
    final details = stringValue(params['details'])?.trim();
    return ProgressMessage(
      kind: 'provider_setup_warning',
      text: details == null || details.isEmpty ? summary : '$summary\n$details',
    );
  }

  ProtocolMessage? _extractMcpStartupStatus(Map<String, dynamic> params) {
    final status = stringValue(params['status']);
    if (status != 'failed') return null;
    final name = stringValue(params['name']) ?? '<unknown>';
    final error = stringValue(params['error']) ?? 'startup failed without provider detail';
    return ProtocolDiagnostic(
      message: 'Codex MCP server "$name" failed to start: $error',
      method: 'mcpServer/startupStatus/updated',
      updateType: status,
    );
  }

  String _summarizeFileChanges(Map<String, dynamic> item) {
    final changes = listValue(item['changes']);
    if (changes == null || changes.isEmpty) {
      return '${stringValue(item['kind']) ?? 'change'} ${stringValue(item['path']) ?? '<unknown>'}';
    }
    final summaries = <String>[];
    for (final rawChange in changes) {
      final change = mapValue(rawChange);
      if (change != null) {
        summaries.add('${stringValue(change['kind']) ?? 'change'} ${stringValue(change['path']) ?? '<unknown>'}');
      }
    }
    return summaries.isEmpty ? 'file_change completed' : summaries.join('\n');
  }

  String? _normalizeItemType(String? itemType) => switch (itemType) {
    'commandExecution' => 'command_execution',
    'fileChange' => 'file_change',
    'mcpToolCall' => 'mcp_tool_call',
    'webSearch' => 'web_search',
    'userMessage' => 'user_message',
    'agentMessage' => 'agent_message',
    _ => itemType,
  };
}
