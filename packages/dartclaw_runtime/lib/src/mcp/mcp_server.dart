import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'dart:async';
import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:logging/logging.dart';
import 'package:uuid/uuid.dart';

import '../context/result_trimmer.dart';
import '../version.dart';

/// Principal audited for a dispatch that arrived without a caller identity.
///
/// The fallback for a transport that authenticates the *deployment* rather than
/// an individual caller — the loopback `/mcp` surface, or a client presenting
/// the shared gateway token — not a claim that the caller was local.
const mcpStewardPrincipal = 'system';

/// Authorization for one MCP caller, applied before discovery and dispatch.
///
/// The caller's identity is established by the transport that owns this policy
/// — for containerized executions, the host-owned bridge pipe — never by
/// anything in the request.
abstract interface class McpCallerPolicy {
  /// Whether [toolName] is visible and callable for this caller.
  bool allows(String toolName);

  /// Records a refused `tools/call`. Discovery filtering is not a refusal.
  void onDenied(String toolName);
}

/// Trusted identity supplied by the transport that authenticated an MCP caller.
final class McpCallerIdentity {
  const new({required this.authorityId, this.sessionId, this.taskId, this.agentId});

  final String authorityId;
  final String? sessionId;
  final String? taskId;
  final String? agentId;
}

/// Trusted caller identity plus one host-generated MCP call event.
final class McpCallerContext {
  const new({required this.authorityId, required this.sourceEvent, this.sessionId, this.taskId, this.agentId});

  final String authorityId;
  final String sourceEvent;
  final String? sessionId;
  final String? taskId;
  final String? agentId;
}

/// MCP tool that consumes transport-authenticated caller identity.
abstract interface class ContextualMcpTool implements McpTool {
  Future<ToolResult> callWithContext(Map<String, dynamic> args, McpCallerContext context);
}

/// MCP protocol handler implementing JSON-RPC 2.0 over Streamable HTTP.
///
/// Handles `initialize`, `notifications/initialized`, `tools/list`, and
/// `tools/call` methods. Tools are registered at startup via [registerTool].
class McpProtocolHandler {
  new({ResultTrimmer? resultTrimmer, GuardChain? guardChain, GuardAuditLogger? auditLogger})
    : _tools = {},
      _policy = null,
      _callerIdentity = null,
      _guardChain = guardChain,
      _auditLogger = auditLogger,
      _toolCanonicals = const {},
      _resultTrimmer = resultTrimmer ?? ResultTrimmer();

  new _scoped(
    this._tools,
    this._policy,
    this._callerIdentity,
    this._resultTrimmer,
    this._guardChain,
    this._auditLogger,
    this._toolCanonicals,
  ) : _started = true;

  static final _log = Logger('McpProtocolHandler');
  static const _uuid = Uuid();

  static const _protocolVersion = '2025-03-26';
  static const _serverName = dartclawMcpServerName;
  static const _dispatchGuardName = 'McpDispatchGuard';

  final Map<String, McpTool> _tools;
  final McpCallerPolicy? _policy;
  final McpCallerIdentity? _callerIdentity;
  final GuardChain? _guardChain;
  final GuardAuditLogger? _auditLogger;
  final Map<String, CanonicalTool> _toolCanonicals;
  final ResultTrimmer _resultTrimmer;
  bool _started = false;

  /// A handler over the same registered tools, authorized for one caller.
  ///
  /// The tool map is shared by reference so late registrations stay visible;
  /// the scoped view is read-only and cannot register. The guard chain and
  /// audit sink carry over too — a scoped view that lost them would be an
  /// unenforced path reachable from exactly the least-trusted caller.
  ///
  /// [toolCanonicals] maps registered tool names to the canonical taxonomy the
  /// guard chain evaluates. Without it a scoped caller's `agentId` reaches
  /// `ToolPolicyGuard` keyed on a provider-native name, so an allowlist written
  /// in canonical names (`web_search`) misses the tool serving it
  /// (`brave_search`) and refuses a call the caller policy already authorized.
  McpProtocolHandler scopedTo(
    McpCallerPolicy policy, {
    McpCallerIdentity? callerIdentity,
    Map<String, CanonicalTool> toolCanonicals = const {},
  }) => McpProtocolHandler._scoped(
    _tools,
    policy,
    callerIdentity,
    _resultTrimmer,
    _guardChain,
    _auditLogger,
    toolCanonicals,
  );

  /// Register a tool. Must be called before the server starts handling requests.
  void registerTool(McpTool tool) {
    if (_started) {
      throw StateError('Cannot register tools after server has started handling requests');
    }
    if (_tools.containsKey(tool.name)) {
      _log.warning('Tool "${tool.name}" already registered — skipping duplicate');
      return;
    }
    _tools[tool.name] = tool;
  }

  /// Mark the handler as started (called when first request arrives or server starts).
  void markStarted() {
    _started = true;
  }

  /// List of registered tool names (for diagnostics).
  List<String> get toolNames => _tools.keys.toList();

  /// Read/write classification of every registered tool, by tool name.
  Map<String, McpToolAccess> get toolAccess => {for (final tool in _tools.values) tool.name: tool.access};

  /// Handle a JSON-RPC request string and return a JSON-RPC response string.
  /// Returns null for notifications (no response needed).
  Future<String?> handleRequest(String body) async {
    _started = true;

    Object? parsed;
    try {
      parsed = jsonDecode(body);
    } on FormatException {
      return _errorResponse(null, -32700, 'Parse error');
    }

    if (parsed is! Map<String, dynamic>) {
      return _errorResponse(null, -32600, 'Invalid Request');
    }

    final jsonrpc = parsed['jsonrpc'];
    if (jsonrpc != '2.0') {
      return _errorResponse(parsed['id'], -32600, 'Invalid Request: missing jsonrpc "2.0"');
    }

    final method = parsed['method'];
    if (method is! String) {
      return _errorResponse(parsed['id'], -32600, 'Invalid Request: missing method');
    }

    final id = parsed['id']; // null for notifications
    final params = parsed['params'] as Map<String, dynamic>? ?? {};

    // Notifications (no id) — handle but don't respond
    if (id == null) {
      await _handleNotification(method, params);
      return null;
    }

    return _handleMethod(method, params, id as Object);
  }

  Future<void> _handleNotification(String method, Map<String, dynamic> params) async {
    switch (method) {
      case 'notifications/initialized':
        _log.fine('Client initialized notification received');
      default:
        _log.fine('Unknown notification: $method');
    }
  }

  Future<String> _handleMethod(String method, Map<String, dynamic> params, Object id) async {
    switch (method) {
      case 'initialize':
        return _handleInitialize(id);
      case 'tools/list':
        return _handleToolsList(id);
      case 'tools/call':
        return _handleToolsCall(params, id);
      default:
        return _errorResponse(id, -32601, 'Method not found: $method');
    }
  }

  String _handleInitialize(Object id) {
    final result = {
      'protocolVersion': _protocolVersion,
      'capabilities': {
        'tools': {'listChanged': false},
      },
      'serverInfo': {'name': _serverName, 'version': dartclawVersion},
    };
    return _successResponse(id, result);
  }

  String _handleToolsList(Object id) {
    final policy = _policy;
    final tools = _tools.values
        .where((t) => policy == null || policy.allows(t.name))
        .map((t) => {'name': t.name, 'description': t.description, 'inputSchema': t.inputSchema})
        .toList();
    return _successResponse(id, {'tools': tools});
  }

  Future<String> _handleToolsCall(Map<String, dynamic> params, Object id) async {
    final name = params['name'] as String?;
    if (name == null) {
      return _errorResponse(id, -32602, 'Invalid params: missing "name"');
    }

    // Authorization precedes the registry lookup, and denied and unregistered
    // names answer identically — a scoped caller learns nothing about tools it
    // may not use, whether or not they exist.
    final policy = _policy;
    if (policy != null && !policy.allows(name)) {
      policy.onDenied(name);
      return _errorResponse(id, -32601, 'Tool not available: $name');
    }

    final tool = _tools[name];
    if (tool == null) {
      return _errorResponse(
        id,
        policy == null ? -32602 : -32601,
        policy == null ? 'Unknown tool: $name' : 'Tool not available: $name',
      );
    }

    final args = params['arguments'] as Map<String, dynamic>? ?? {};
    final validationError = _validateToolArguments(tool, args);
    if (validationError != null) {
      return _errorResponse(id, -32602, validationError);
    }

    final refusal = await _evaluateDispatch(tool, args);
    ToolResult result;
    if (refusal != null) {
      result = refusal;
    } else {
      try {
        final callerIdentity = _callerIdentity;
        result = await switch (tool) {
          ContextualMcpTool() when callerIdentity != null => tool.callWithContext(
            args,
            McpCallerContext(
              authorityId: callerIdentity.authorityId,
              sourceEvent: 'mcp-call:${callerIdentity.authorityId}:${_uuid.v4()}',
              sessionId: callerIdentity.sessionId,
              taskId: callerIdentity.taskId,
              agentId: callerIdentity.agentId,
            ),
          ),
          ContextualMcpTool() when _policy != null => Future<ToolResult>.value(
            const ToolResult.error('Tool requires authenticated caller context'),
          ),
          _ => tool.call(args),
        }.timeout(const Duration(seconds: 120));
      } on TimeoutException {
        _log.warning('Tool "$name" timed out');
        result = ToolResult.error('Tool "$name" timed out after 120 seconds');
      } catch (e) {
        _log.warning('Tool "$name" threw exception: $e');
        result = ToolResult.error('Tool execution failed: $e');
      }
    }

    return switch (result) {
      ToolResultText(:final content) => _successResponse(id, {
        'content': [
          {'type': 'text', 'text': _resultTrimmer.trim(content)},
        ],
      }),
      ToolResultError(:final message) => _successResponse(id, {
        'content': [
          {'type': 'text', 'text': message},
        ],
        'isError': true,
      }),
    };
  }

  /// Guard-evaluates and audits one dispatch; non-null refuses the call.
  ///
  /// Runs after caller-policy authorization and schema validation, so a policy
  /// denial, an unknown name and a schema rejection reach neither the guard nor
  /// the sink. The entry records that the dispatch was *authorized*, not that
  /// the tool ran.
  Future<ToolResult?> _evaluateDispatch(McpTool tool, Map<String, dynamic> args) async {
    final chain = _guardChain;
    final identity = _callerIdentity;
    final principal = identity?.authorityId ?? mcpStewardPrincipal;

    if (chain != null) {
      GuardVerdict verdict;
      try {
        verdict = await chain.evaluateBeforeToolCall(
          _toolCanonicals[tool.name]?.stableName ?? tool.name,
          args,
          sessionId: identity?.sessionId,
          agentId: identity?.agentId,
          rawProviderToolName: tool.name,
        );
      } catch (error) {
        return _denyDispatch(tool, principal, identity, 'guard failure: $error');
      }
      if (verdict.isBlock) {
        return _denyDispatch(tool, principal, identity, verdict.message ?? 'MCP tool call denied');
      }
    }

    try {
      await _auditDispatch(tool, principal, identity, decision: 'allow', reason: _accessReason(tool));
    } catch (error) {
      return ToolResult.error('audit failure: $error');
    }
    return null;
  }

  Future<ToolResult> _denyDispatch(McpTool tool, String principal, McpCallerIdentity? identity, String reason) async {
    try {
      await _auditDispatch(tool, principal, identity, decision: 'deny', reason: '${_accessReason(tool)} $reason');
    } catch (error) {
      return ToolResult.error('audit failure: $error');
    }
    return ToolResult.error(reason);
  }

  Future<void> _auditDispatch(
    McpTool tool,
    String principal,
    McpCallerIdentity? identity, {
    required String decision,
    required String reason,
  }) async {
    final sink = _auditLogger;
    if (sink == null) return;
    await sink.writeEntry(
      AuditEntry(
        timestamp: DateTime.now(),
        guard: _dispatchGuardName,
        hook: 'mcp_tool_call',
        verdict: decision == 'allow' ? 'pass' : 'block',
        reason: reason,
        rawProviderToolName: tool.name,
        agentId: identity?.agentId,
        sessionId: identity?.sessionId,
        server: _serverName,
        tool: tool.name,
        decision: decision,
        principal: principal,
      ),
    );
  }

  static String _accessReason(McpTool tool) => 'access=${tool.access.name}';

  String? _validateToolArguments(McpTool tool, Map<String, dynamic> args) {
    final schema = tool.inputSchema;
    if (schema['additionalProperties'] != false) return null;

    final properties = schema['properties'];
    if (properties is! Map) return null;

    for (final key in args.keys) {
      if (!properties.containsKey(key)) {
        return 'Invalid params: unknown argument "$key" for tool "${tool.name}"';
      }
    }
    return null;
  }

  static String _successResponse(Object id, Object result) {
    return jsonEncode({'jsonrpc': '2.0', 'id': id, 'result': result});
  }

  static String _errorResponse(Object? id, int code, String message) {
    return jsonEncode({
      'jsonrpc': '2.0',
      'id': id,
      'error': {'code': code, 'message': message},
    });
  }
}
