import 'package:logging/logging.dart';

import 'agent_harness.dart' show ModelCatalogue, ModelCatalogueEntry;
import 'canonical_tool.dart';
import 'base_protocol_adapter.dart';
import 'codex_protocol_utils.dart';
import 'protocol_message.dart';

part 'codex_protocol_adapter_messages.dart';

enum _ApprovalResponseKind { decision, elicitation, permissions, unsupported }

enum _CommandDenial { decline, cancel, error }

typedef _CodexUsage = ({int input, int cached, int cacheWrite, int output});

const _CodexUsage _zeroCodexUsage = (input: 0, cached: 0, cacheWrite: 0, output: 0);

/// Codex app-server implementation of [ProtocolAdapter].
class CodexProtocolAdapter extends BaseProtocolAdapter {
  static const String _clientName = 'dartclaw';
  static const String _clientVersion = '0.9.0';

  final Map<String, CanonicalTool> _ownMcpToolCanonicals;
  final Map<String, _ApprovalResponseKind> _approvalResponseKinds = {};
  final Map<String, _CommandDenial> _commandDenials = {};
  final Map<String, Object> _approvalWireIds = {};
  final Map<String, Map<String, dynamic>> _startedItems = {};

  /// Latest cumulative `tokenUsage.total` per thread from
  /// `thread/tokenUsage/updated`, and the share of each already credited to a
  /// settled turn. A turn's usage is the sum over threads of the difference:
  /// several model requests per turn overwrite `total`, several turns share a
  /// thread, and a subagent the turn spawns reports under its own `threadId`
  /// (the app server attaches every client to every new thread).
  final Map<String, _CodexUsage> _threadUsageTotals = {};
  final Map<String, _CodexUsage> _threadUsageCredited = {};

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
        case 'item/tool/requestUserInput':
          final requestId = _registerApproval(id, _ApprovalResponseKind.unsupported);
          return ControlRequest(requestId: requestId, subtype: 'unsupported_user_input_request', data: params);
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

  /// [outputSchema] extends the [ProtocolAdapter] signature: the app server
  /// constrains the final assistant message to it, and no other provider takes
  /// a schema on the turn request.
  @override
  Map<String, dynamic> buildTurnRequest({
    required String message,
    String? systemPrompt,
    String? threadId,
    List<Map<String, dynamic>>? history,
    Map<String, dynamic>? settings,
    Map<String, dynamic>? outputSchema,
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
            params['sandboxPolicy'] = {
              'type': entry.value,
              if (entry.value == 'workspaceWrite' && settings['writable_roots'] != null)
                'writableRoots': settings['writable_roots'],
            };
          case 'writable_roots':
            break;
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
    if (outputSchema != null) {
      params['outputSchema'] = outputSchema;
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

  /// Builds a `model/list` request for the page after [cursor].
  Map<String, dynamic> buildModelListRequest({required Object id, String? cursor}) => {
    'id': id,
    'method': 'model/list',
    'params': {'cursor': ?cursor},
  };

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

/// The cursor of the `model/list` page after [result], or `null` on the last.
String? codexModelListNextCursor(Map<String, dynamic> result) => switch (result['nextCursor']) {
  null => null,
  final String cursor => cursor,
  _ => throw const FormatException('Codex model/list nextCursor is not a string'),
};

/// Builds the account's model catalogue from every `model/list` result page
/// and the `thread/start` result that names the model a thread resolves to.
///
/// A missing or mistyped field this reads throws [FormatException] rather
/// than yielding a partial list. Hidden models are not offered; the default
/// resolves by matching the thread's `model` against an offered entry's.
ModelCatalogue codexModelCatalogue({
  required List<Map<String, dynamic>> pages,
  required Map<String, dynamic> threadStart,
}) {
  final resolved = threadStart['model'];
  if (resolved is! String) throw const FormatException('Codex thread/start result carries no model');
  final entries = <ModelCatalogueEntry>[];
  String? defaultId;
  for (final page in pages) {
    final data = page['data'];
    if (data is! List) throw const FormatException('Codex model/list result carries no data list');
    for (final model in data) {
      if (model is! Map<String, dynamic>) throw const FormatException('Codex model/list entry is not an object');
      final id = model['id'];
      final slug = model['model'];
      final label = model['displayName'];
      final hidden = model['hidden'];
      final efforts = model['supportedReasoningEfforts'];
      if (id is! String || slug is! String || label is! String || hidden is! bool || efforts is! List) {
        throw FormatException('Codex model/list entry lacks id, model, displayName, hidden or efforts: $model');
      }
      final effortNames = [
        for (final effort in efforts)
          switch (effort) {
            {'reasoningEffort': final String name} => name,
            _ => throw FormatException('Codex model "$id" carries a malformed supportedReasoningEfforts entry'),
          },
      ];
      if (hidden) continue;
      entries.add(ModelCatalogueEntry(id: id, label: label, efforts: List.unmodifiable(effortNames)));
      if (defaultId == null && slug == resolved) defaultId = id;
    }
  }
  return ModelCatalogue(entries: List.unmodifiable(entries), defaultId: defaultId);
}
