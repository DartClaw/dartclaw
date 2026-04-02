import 'package:logging/logging.dart';

import 'claude_protocol.dart' as claude_protocol;
import 'canonical_tool.dart';
import 'base_protocol_adapter.dart';
import 'protocol_message.dart';
import 'tool_policy.dart' as tool_policy;

/// Claude-specific implementation of [ProtocolAdapter].
class ClaudeProtocolAdapter extends BaseProtocolAdapter {
  static final _log = Logger('ClaudeProtocolAdapter');

  @override
  ProtocolMessage? parseLine(String line) {
    final message = claude_protocol.parseJsonlLine(line);
    if (message == null) return null;

    return switch (message) {
      claude_protocol.StreamTextDelta(:final text) => TextDelta(text),
      claude_protocol.ToolUseBlock(:final name, :final id, :final input) => ToolUse(name: name, id: id, input: input),
      claude_protocol.ToolResultBlock(:final toolId, :final output, :final isError) => ToolResult(
        toolId: toolId,
        output: output,
        isError: isError,
      ),
      claude_protocol.ControlRequest(:final requestId, :final subtype, :final data) => ControlRequest(
        requestId: requestId,
        subtype: subtype,
        data: data,
      ),
      claude_protocol.TurnResult(
        :final stopReason,
        :final costUsd,
        :final durationMs,
        :final inputTokens,
        :final outputTokens,
        :final cacheReadInputTokens,
        :final cacheCreationInputTokens,
      ) =>
        TurnComplete(
          stopReason: stopReason,
          costUsd: costUsd,
          durationMs: durationMs,
          inputTokens: inputTokens,
          outputTokens: outputTokens,
          cacheReadTokens: cacheReadInputTokens,
          cacheWriteTokens: cacheCreationInputTokens,
        ),
      claude_protocol.SystemInit(:final sessionId, :final toolCount, :final contextWindow) => SystemInit(
        sessionId: sessionId,
        toolCount: toolCount,
        contextWindow: contextWindow,
      ),
    };
  }

  /// Builds a Claude JSONL turn request.
  ///
  /// The [history] parameter is intentionally unused here — the Claude CLI
  /// stream-json protocol has no `previousResponseItems` equivalent. History
  /// replay is handled by [ClaudeCodeHarness] via user-message injection on
  /// cold-process turns. [CodexProtocolAdapter] actively uses [history] for
  /// `previousResponseItems`; the parameter remains on the [ProtocolAdapter]
  /// interface so Codex call sites are unaffected.
  @override
  Map<String, dynamic> buildTurnRequest({
    required String message,
    String? systemPrompt,
    String? threadId,
    List<Map<String, dynamic>>? history,
    Map<String, dynamic>? settings,
    bool resume = false,
  }) {
    final payload = <String, dynamic>{
      'type': 'user',
      'message': {'role': 'user', 'content': message},
    };
    if (systemPrompt != null) {
      payload['system_prompt'] = systemPrompt;
    }
    if (resume) {
      payload['resume'] = true;
    }
    return payload;
  }

  @override
  Map<String, dynamic> buildApprovalResponse(
    String requestId, {
    required bool allow,
    String? toolUseId,
    String? reason,
  }) {
    return tool_policy.buildToolResponse(requestId, allow: allow, toolUseId: toolUseId);
  }

  /// Builds a Claude `hook_callback` success response.
  Map<String, dynamic> buildHookResponse(String requestId, {required bool allow}) {
    return tool_policy.buildHookResponse(requestId, allow: allow);
  }

  /// Builds a Claude success response for unrecognised control subtypes.
  Map<String, dynamic> buildGenericResponse(String requestId) {
    return tool_policy.buildGenericResponse(requestId);
  }

  /// Builds a Claude initialize `control_request`.
  Map<String, dynamic> buildInitializeRequest({
    required String requestId,
    required Map<String, dynamic> hooks,
    required Map<String, dynamic> initializeFields,
    Map<String, dynamic>? sdkMcpServers,
  }) {
    final request = <String, dynamic>{'subtype': 'initialize', 'hooks': hooks, ...?sdkMcpServers, ...initializeFields};
    return {'type': 'control_request', 'request_id': requestId, 'request': request};
  }

  /// Builds a Claude credential-strip hook response with an updated input.
  Map<String, dynamic> buildCredentialStripResponse(String requestId, Map<String, dynamic> updatedInput) {
    return {
      'type': 'control_response',
      'response': {
        'subtype': 'success',
        'request_id': requestId,
        'response': {
          'continue': true,
          'hookSpecificOutput': {'hookEventName': 'PreToolUse', 'updatedInput': updatedInput},
        },
      },
    };
  }

  @override
  CanonicalTool? mapToolName(String providerToolName, {String? kind}) {
    final canonical = switch (providerToolName) {
      'Bash' => CanonicalTool.shell,
      'Read' => CanonicalTool.fileRead,
      'Write' || 'write_file' => CanonicalTool.fileWrite,
      'Edit' || 'edit_file' => CanonicalTool.fileEdit,
      'WebFetch' || 'web_fetch' => CanonicalTool.webFetch,
      _ when providerToolName.startsWith('mcp_') => CanonicalTool.mcpCall,
      _ => null,
    };

    return warnOnUnmappedToolName(_log, 'Claude', providerToolName, canonical);
  }
}
