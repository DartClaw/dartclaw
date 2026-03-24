import 'dart:convert';

import 'canonical_tool.dart';
import 'codex_protocol_utils.dart';
import 'protocol_adapter.dart';
import 'protocol_message.dart';

/// Codex exec-mode implementation of [ProtocolAdapter].
class CodexExecProtocolAdapter implements ProtocolAdapter {
  @override
  ProtocolMessage? parseLine(String line) {
    if (line.trim().isEmpty) {
      return null;
    }

    final decoded = codexDecodeJsonObject(line);
    if (decoded == null) {
      return null;
    }

    return switch (codexStringValue(decoded['type'])) {
      'thread.started' || 'turn.started' => null,
      'item.started' => _extractToolUse(codexMapValue(decoded['item'])),
      'item.completed' => _extractCompletedItem(codexMapValue(decoded['item'])),
      'turn.completed' => _extractTurnComplete(decoded),
      _ => null,
    };
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
    return const <String, dynamic>{};
  }

  @override
  Map<String, dynamic> buildApprovalResponse(
    String requestId, {
    required bool allow,
    String? toolUseId,
    String? reason,
  }) {
    return const <String, dynamic>{};
  }

  @override
  CanonicalTool? mapToolName(String providerToolName, {String? kind}) {
    return switch (providerToolName) {
      'command_execution' => CanonicalTool.shell,
      'file_change' => switch (kind) {
        'update' || 'modify' => CanonicalTool.fileEdit,
        _ => CanonicalTool.fileWrite,
      },
      'mcp_tool_call' => CanonicalTool.mcpCall,
      _ => null,
    };
  }

  ToolUse? _extractToolUse(Map<String, dynamic>? item) {
    if (item == null) {
      return null;
    }

    final itemType = codexStringValue(item['type']);
    if (itemType == null) {
      return null;
    }

    return switch (itemType) {
      'command_execution' => _buildCommandExecutionToolUse(item),
      'file_change' => _buildFileChangeToolUse(item),
      'mcp_tool_call' => _buildMcpToolUse(item),
      _ => null,
    };
  }

  ToolUse? _buildCommandExecutionToolUse(Map<String, dynamic> item) {
    final name = mapToolName('command_execution');
    if (name == null) {
      return null;
    }

    return ToolUse(
      name: name.stableName,
      id: codexStringValue(item['id']) ?? '',
      input: {'command': codexStringValue(item['command']) ?? ''},
    );
  }

  ToolUse? _buildFileChangeToolUse(Map<String, dynamic> item) {
    final kind = codexStringValue(item['kind']);
    final name = mapToolName('file_change', kind: kind);
    if (name == null) {
      return null;
    }

    return ToolUse(
      name: name.stableName,
      id: codexStringValue(item['id']) ?? '',
      input: {'path': codexStringValue(item['path']) ?? '', 'kind': kind ?? ''},
    );
  }

  ToolUse? _buildMcpToolUse(Map<String, dynamic> item) {
    final name = mapToolName('mcp_tool_call');
    if (name == null) {
      return null;
    }

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

  ProtocolMessage? _extractCompletedItem(Map<String, dynamic>? item) {
    if (item == null) {
      return null;
    }

    return switch (codexStringValue(item['type'])) {
      'agent_message' => _extractAgentMessage(item),
      'command_execution' => _extractCommandExecutionResult(item),
      'file_change' => _extractJsonEncodedResult(item, field: 'changes'),
      'mcp_tool_call' => _extractJsonEncodedResult(item, field: 'result'),
      _ => null,
    };
  }

  TextDelta? _extractAgentMessage(Map<String, dynamic> item) {
    final text = codexStringValue(item['text']);
    if (text == null) {
      return null;
    }
    return TextDelta(text);
  }

  ToolResult _extractCommandExecutionResult(Map<String, dynamic> item) {
    return ToolResult(
      toolId: codexStringValue(item['id']) ?? '',
      output: codexStringValue(item['aggregated_output']) ?? '',
      isError: (codexIntValue(item['exit_code']) ?? 0) != 0,
    );
  }

  ToolResult _extractJsonEncodedResult(Map<String, dynamic> item, {required String field}) {
    return ToolResult(toolId: codexStringValue(item['id']) ?? '', output: jsonEncode(item[field]), isError: false);
  }

  TurnComplete _extractTurnComplete(Map<String, dynamic> decoded) {
    final usage = codexMapValue(decoded['usage']) ?? const <String, dynamic>{};
    return TurnComplete(
      stopReason: 'end_turn',
      inputTokens: codexIntValue(usage['input_tokens']),
      outputTokens: codexIntValue(usage['output_tokens']),
      cacheReadTokens: codexIntValue(usage['cached_input_tokens']),
      cacheWriteTokens: 0,
    );
  }
}
