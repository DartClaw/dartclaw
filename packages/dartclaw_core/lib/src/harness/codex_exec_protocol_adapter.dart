import 'canonical_tool.dart';
import 'base_protocol_adapter.dart';
import 'codex_protocol_utils.dart';
import 'protocol_message.dart';

/// Codex exec-mode implementation of [ProtocolAdapter].
class CodexExecProtocolAdapter extends BaseProtocolAdapter {
  @override
  ProtocolMessage? parseLine(String line) {
    final decoded = decodeJsonObject(line);
    if (decoded == null) {
      return null;
    }

    return switch (stringValue(decoded['type'])) {
      'thread.started' || 'turn.started' => null,
      'item.started' => _extractToolUse(mapValue(decoded['item'])),
      'item.completed' => _extractCompletedItem(mapValue(decoded['item'])),
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
    return codexMapToolName(providerToolName, kind: kind);
  }

  ToolUse? _extractToolUse(Map<String, dynamic>? item) {
    if (item == null) {
      return null;
    }

    final itemType = stringValue(item['type']);
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
    return codexBuildCommandExecutionToolUse(item, tool: mapToolName('command_execution'));
  }

  ToolUse? _buildFileChangeToolUse(Map<String, dynamic> item) {
    return codexBuildFileChangeToolUse(item, mapToolName: mapToolName);
  }

  ToolUse? _buildMcpToolUse(Map<String, dynamic> item) {
    return codexBuildMcpToolUse(item, tool: mapToolName('mcp_tool_call'));
  }

  ProtocolMessage? _extractCompletedItem(Map<String, dynamic>? item) {
    if (item == null) {
      return null;
    }

    return switch (stringValue(item['type'])) {
      'agent_message' => _extractAgentMessage(item),
      'command_execution' => _extractCommandExecutionResult(item),
      'file_change' => _extractJsonEncodedResult(item, field: 'changes'),
      'mcp_tool_call' => _extractJsonEncodedResult(item, field: 'result'),
      _ => null,
    };
  }

  TextDelta? _extractAgentMessage(Map<String, dynamic> item) {
    return codexBuildAgentMessageDelta(item, allowDeltaFallback: false);
  }

  ToolResult _extractCommandExecutionResult(Map<String, dynamic> item) {
    return codexBuildCommandExecutionToolResult(item);
  }

  ToolResult _extractJsonEncodedResult(Map<String, dynamic> item, {required String field}) {
    return codexBuildJsonFieldToolResult(item, field: field);
  }

  TurnComplete _extractTurnComplete(Map<String, dynamic> decoded) {
    final usage = mapValue(decoded['usage']) ?? const <String, dynamic>{};
    return codexBuildTurnComplete(usage, stopReason: 'end_turn');
  }
}
