import 'package:logging/logging.dart';

import 'canonical_tool.dart';
import 'base_protocol_adapter.dart';
import 'codex_protocol_utils.dart';
import 'protocol_message.dart';

part 'codex_protocol_adapter_messages.dart';

enum _ApprovalResponseKind { decision, elicitation, permissions, unsupported }

enum _CommandDenial { decline, cancel, error }

/// Codex app-server implementation of [ProtocolAdapter].
class CodexProtocolAdapter extends BaseProtocolAdapter {
  static const String _clientName = 'dartclaw';
  static const String _clientVersion = '0.9.0';

  final Map<String, CanonicalTool> _ownMcpToolCanonicals;
  final Map<String, _ApprovalResponseKind> _approvalResponseKinds = {};
  final Map<String, _CommandDenial> _commandDenials = {};
  final Map<String, Object> _approvalWireIds = {};
  final Map<String, Map<String, dynamic>> _startedItems = {};

  /// Usage from the most recent `thread/tokenUsage/updated`, awaiting the
  /// `turn/completed` it belongs to. Cleared when that turn settles.
  Map<String, dynamic>? _lastTokenUsage;

  static final _log = Logger('CodexProtocolAdapter');

  new({Map<String, CanonicalTool> ownMcpToolCanonicals = const {}})
    : _ownMcpToolCanonicals = Map.unmodifiable(ownMcpToolCanonicals);

  @override
  ProtocolMessage? parseLine(String line) {
    final decoded = decodeJsonObject(line);
    if (decoded == null) return null;

    final method = stringValue(decoded['method']);
    final Object? id = decoded['id'];

    if (id != null && (method == 'control/approval' || method == 'approval/request')) {
      final requestId = _registerApproval(id);
      return ControlRequest(
        requestId: requestId,
        subtype: 'approval',
        data: mapValue(decoded['params']) ?? const <String, dynamic>{},
      );
    }

    if (id != null && method != null) {
      final params = mapValue(decoded['params']) ?? const <String, dynamic>{};
      switch (method) {
        case 'item/commandExecution/requestApproval':
          final requestId = _registerApproval(id, _ApprovalResponseKind.decision);
          return _extractCommandApproval(requestId, params);
        case 'item/fileChange/requestApproval':
          final requestId = _registerApproval(id, _ApprovalResponseKind.decision);
          return _extractFileChangeApproval(requestId, params);
        case 'item/permissions/requestApproval':
          final requestId = _registerApproval(id, _ApprovalResponseKind.permissions);
          return ControlRequest(requestId: requestId, subtype: 'unsupported_permission_request', data: params);
        case 'mcpServer/elicitation/request':
          final requestId = _registerApproval(id, _ApprovalResponseKind.elicitation);
          if (stringValue(mapValue(params['_meta'])?['codex_approval_kind']) != 'mcp_tool_call') {
            return ControlRequest(requestId: requestId, subtype: 'unsupported_elicitation', data: params);
          }
          return _extractMcpApproval(requestId, params);
        default:
          final requestId = _registerApproval(id, _ApprovalResponseKind.unsupported);
          return ControlRequest(
            requestId: requestId,
            subtype: 'unsupported_server_request',
            data: {'method': method, 'params': params},
          );
      }
    }

    if (method != null) {
      final params = mapValue(decoded['params']) ?? const <String, dynamic>{};
      return switch (method) {
        'item/agentMessage/delta' => _extractAgentMessageDelta(params),
        'item/started' => _handleStartedItem(mapValue(params['item'])),
        'item/completed' => _handleCompletedItem(mapValue(params['item'])),
        'turn/completed' => _handleTurnComplete(params),
        'thread/tokenUsage/updated' => _handleTokenUsage(params),
        'turn/failed' => _handleTurnFailed(),
        'configWarning' => _extractConfigWarning(params),
        'mcpServer/startupStatus/updated' => _extractMcpStartupStatus(params),
        'turn/started' => null,
        // Deprecated by Codex — suppressed as explicit no-op (still emitted for backward compat)
        'thread/compactedNotification' => null,
        // Unhandled, but never silent: usage moved to its own notification at
        // codex-cli 0.146.0 and vanished here for a whole milestone because
        // this arm said nothing.
        _ => _logUnhandledNotification(method),
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
        switch (entry.key) {
          // Per Codex app-server protocol: turn/start uses sandboxPolicy object
          // form {type: "..."}, not flat sandbox string.
          case 'sandbox':
            params['sandboxPolicy'] = {'type': entry.value};
          case 'approval_policy':
            params['approvalPolicy'] = entry.value;
          default:
            params[entry.key] = entry.value;
        }
      }
    }
    if (threadId != null) {
      params['threadId'] = threadId;
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
    final responseKind = _approvalResponseKinds.remove(requestId);
    final commandDenial = _commandDenials.remove(requestId) ?? _CommandDenial.decline;
    final wireId = _approvalWireIds.remove(requestId) ?? requestId;
    if (responseKind == _ApprovalResponseKind.decision) {
      if (!allow && commandDenial == _CommandDenial.error) {
        return {
          'jsonrpc': '2.0',
          'id': wireId,
          'error': {'code': -32602, 'message': 'No safe approval decision was offered'},
        };
      }
      return {
        'jsonrpc': '2.0',
        'id': wireId,
        'result': {'decision': allow ? 'accept' : (commandDenial == _CommandDenial.cancel ? 'cancel' : 'decline')},
      };
    }
    if (responseKind == _ApprovalResponseKind.elicitation) {
      return {
        'jsonrpc': '2.0',
        'id': wireId,
        'result': {'action': allow ? 'accept' : 'decline', 'content': null, '_meta': null},
      };
    }
    if (responseKind == _ApprovalResponseKind.permissions) {
      return {
        'jsonrpc': '2.0',
        'id': wireId,
        'result': {'permissions': <String, dynamic>{}},
      };
    }
    if (responseKind == _ApprovalResponseKind.unsupported) {
      return {
        'jsonrpc': '2.0',
        'id': wireId,
        'error': {'code': -32601, 'message': 'Method not supported by DartClaw'},
      };
    }
    return {
      'jsonrpc': '2.0',
      'id': wireId,
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

  /// Builds a `thread/resume` request.
  Map<String, dynamic> buildThreadResumeRequest({required Object id, required String threadId}) {
    return {
      'id': id,
      'method': 'thread/resume',
      'params': {'threadId': threadId},
    };
  }

  @override
  CanonicalTool? mapToolName(String providerToolName, {String? kind, String? mcpServer, String? mcpTool}) {
    if (providerToolName == 'mcp_tool_call' && mcpServer == dartclawMcpServerName) {
      return _ownMcpToolCanonicals[mcpTool] ?? CanonicalTool.mcpCall;
    }
    return switch (providerToolName) {
      'web_search' => CanonicalTool.webSearch,
      _ => codexMapToolName(providerToolName, kind: kind),
    };
  }
}
