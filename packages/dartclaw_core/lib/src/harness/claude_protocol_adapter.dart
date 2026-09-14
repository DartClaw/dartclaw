import 'package:logging/logging.dart';

import 'claude_protocol.dart' as claude_protocol;
import 'canonical_tool.dart';
import 'base_protocol_adapter.dart';
import 'protocol_message.dart';
import 'tool_policy.dart' as tool_policy;

typedef _Usage = ({int input, int output, int cacheRead, int cacheWrite});

const _Usage _zeroUsage = (input: 0, output: 0, cacheRead: 0, cacheWrite: 0);

/// Claude-specific implementation of [ProtocolAdapter].
class ClaudeProtocolAdapter extends BaseProtocolAdapter {
  static final _log = Logger('ClaudeProtocolAdapter');

  static const _ownMcpPrefix = 'mcp__${dartclawMcpServerName}__';

  final Map<String, CanonicalTool> _ownMcpToolCanonicals;

  /// Latest usage frame per subagent API message this turn. The `result`
  /// line's usage covers the main conversation only (verified on 2.1.270:
  /// it equals the main transcript, deduplicated by message id), so subagent
  /// usage is credited from their `assistant` frames – the last frame per
  /// message id, since earlier frames of a message carry partial counts.
  final Map<String, _Usage> _subagentUsageByMessage = {};

  /// The share of [_subagentUsageByMessage] already folded into an emitted
  /// [TurnComplete]; a held turn sees several `result` lines and each carries
  /// only what accrued since the previous one.
  _Usage _subagentUsageCredited = _zeroUsage;

  new({Map<String, CanonicalTool> ownMcpToolCanonicals = const {}})
    : _ownMcpToolCanonicals = Map.unmodifiable(ownMcpToolCanonicals);

  @override
  ProtocolMessage? parseLine(String line) {
    ProtocolMessage? result;
    for (final message in claude_protocol.parseJsonlLine(line)) {
      if (message is! claude_protocol.AssistantUsage) {
        result = _toProtocolMessage(message);
      } else if (message.isSubagent) {
        _subagentUsageByMessage[message.messageId] = (
          input: message.inputTokens,
          output: message.outputTokens,
          cacheRead: message.cacheReadInputTokens,
          cacheWrite: message.cacheCreationInputTokens,
        );
      }
    }
    return result;
  }

  /// Subagent usage not yet credited to a [TurnComplete]; credits it.
  _Usage _takeUncreditedSubagentUsage() {
    var total = _zeroUsage;
    for (final usage in _subagentUsageByMessage.values) {
      total = _combine(total, usage, 1);
    }
    final credited = _subagentUsageCredited;
    _subagentUsageCredited = total;
    return _combine(total, credited, -1);
  }

  static _Usage _combine(_Usage a, _Usage b, int sign) => (
    input: a.input + sign * b.input,
    output: a.output + sign * b.output,
    cacheRead: a.cacheRead + sign * b.cacheRead,
    cacheWrite: a.cacheWrite + sign * b.cacheWrite,
  );

  ProtocolMessage _toProtocolMessage(claude_protocol.ClaudeMessage message) {
    return switch (message) {
      claude_protocol.AssistantUsage() => throw StateError('usage frames are recorded, not emitted'),
      claude_protocol.StreamTextDelta(:final text) => TextDelta(text),
      claude_protocol.ToolUseBlock(:final name, :final id, :final input) => ToolUse(name: name, id: id, input: input),
      claude_protocol.ToolResultBlock(:final toolId, :final output, :final isError) => ToolResultMessage(
        toolId: toolId,
        output: output,
        isError: isError,
      ),
      claude_protocol.ControlRequest(:final requestId, :final subtype, :final data) => ControlRequest(
        requestId: requestId,
        subtype: subtype,
        data: data,
      ),
      claude_protocol.TerminalResult() => _turnComplete(message),
      claude_protocol.SystemInit(:final sessionId, :final toolCount, :final contextWindow) => SystemInit(
        sessionId: sessionId,
        toolCount: toolCount,
        contextWindow: contextWindow,
      ),
      claude_protocol.CompactBoundary(:final trigger, :final preTokens) => CompactBoundary(
        trigger: trigger,
        preTokens: preTokens,
      ),
      claude_protocol.BackgroundTasksChanged(:final tasks) => BackgroundTasksChanged(tasks: tasks),
    };
  }

  /// The `result` usage plus the subagent usage accrued since the previous
  /// `result`. Buckets stay null only when neither side reported anything.
  TurnComplete _turnComplete(claude_protocol.TerminalResult result) {
    final subagent = _takeUncreditedSubagentUsage();
    int? fold(int? reported, int accrued) =>
        reported == null && subagent == _zeroUsage ? null : (reported ?? 0) + accrued;
    return TurnComplete(
      stopReason: result.stopReason,
      subtype: result.subtype,
      structuredOutput: result.structuredOutput,
      finalText: result.finalText,
      costUsd: result.costUsd,
      durationMs: result.durationMs,
      inputTokens: fold(result.inputTokens, subagent.input),
      outputTokens: fold(result.outputTokens, subagent.output),
      cacheReadTokens: fold(result.cacheReadInputTokens, subagent.cacheRead),
      cacheWriteTokens: fold(result.cacheCreationInputTokens, subagent.cacheWrite),
    );
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
  }) {
    // A new turn: subagent frames of the previous turn are all credited (a
    // held turn completes only once no background task is outstanding).
    _subagentUsageByMessage.clear();
    _subagentUsageCredited = _zeroUsage;
    final payload = <String, dynamic>{
      'type': 'user',
      'message': {'role': 'user', 'content': message},
    };
    if (systemPrompt != null) {
      payload['system_prompt'] = systemPrompt;
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
  ///
  /// Only hooks and SDK MCP servers travel here. Tool policy, turn caps, model
  /// and effort are spawn flags: the SDK protocol has no initialize field for
  /// them and the CLI ignores unknown ones.
  Map<String, dynamic> buildInitializeRequest({
    required String requestId,
    required Map<String, dynamic> hooks,
    Map<String, dynamic>? sdkMcpServers,
  }) {
    final request = <String, dynamic>{'subtype': 'initialize', 'hooks': hooks, ...?sdkMcpServers};
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

  /// The Claude-native spelling of a canonical tool name, for `--disallowedTools`.
  ///
  /// The inverse of [mapToolName] for the built-ins it maps; a name that is
  /// not a canonical stable name is already native (or an MCP tool) and passes
  /// through. `file_edit` names two built-ins, so it expands to both.
  static List<String> nativeToolNames(String name) => switch (name) {
    'shell' => const ['Bash'],
    'file_read' => const ['Read'],
    'file_write' => const ['Write'],
    'file_edit' => const ['Edit', 'NotebookEdit'],
    'web_fetch' => const ['WebFetch'],
    'web_search' => const ['WebSearch'],
    _ => [name],
  };

  @override
  CanonicalTool? mapToolName(String providerToolName, {String? kind}) {
    final canonical = switch (providerToolName) {
      'Bash' => CanonicalTool.shell,
      'Read' => CanonicalTool.fileRead,
      'Write' || 'write_file' => CanonicalTool.fileWrite,
      'Edit' || 'NotebookEdit' || 'edit_file' => CanonicalTool.fileEdit,
      'WebFetch' || 'web_fetch' => CanonicalTool.webFetch,
      'WebSearch' => CanonicalTool.webSearch,
      _ when providerToolName.startsWith(_ownMcpPrefix) =>
        _ownMcpToolCanonicals[providerToolName.substring(_ownMcpPrefix.length)] ?? CanonicalTool.mcpCall,
      _ when providerToolName.startsWith('mcp_') => CanonicalTool.mcpCall,
      _ => null,
    };

    return warnOnUnmappedToolName(_log, 'Claude', providerToolName, canonical);
  }
}
