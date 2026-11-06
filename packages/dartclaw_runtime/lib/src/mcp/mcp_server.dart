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
  const new({
    required this.authorityId,
    this.sessionId,
    this.taskId,
    this.agentId,
    this.knowledgeScope = McpKnowledgeScope.privateAndShared,
    this.deployment = false,
  });

  final String authorityId;
  final String? sessionId;
  final String? taskId;
  final String? agentId;
  final McpKnowledgeScope knowledgeScope;

  /// Whether this is the deployment itself ([McpCaller.deployment]), which reaches owner scope. Only that caller sets
  /// it, so no transport's authority id can be mistaken for the deployment.
  final bool deployment;
}

/// Host-selected knowledge boundary for an authenticated MCP caller.
enum McpKnowledgeScope { privateAndShared, sharedOnly }

/// Trusted caller identity plus one host-generated MCP call event.
final class McpCallerContext {
  const new({
    required this.authorityId,
    required this.sourceEvent,
    this.sessionId,
    this.taskId,
    this.agentId,
    this.knowledgeScope = McpKnowledgeScope.privateAndShared,
    this.deployment = false,
    this.turn,
  });

  final String authorityId;
  final String sourceEvent;
  final String? sessionId;
  final String? taskId;
  final String? agentId;
  final McpKnowledgeScope knowledgeScope;

  /// Copied from [McpCallerIdentity.deployment].
  final bool deployment;

  /// The turn the calling harness is executing, resolved by the host at call time. Null for a caller that is not
  /// running a turn. A turn with no sender is not a channel turn, and each reader gates it by its own rule.
  final TurnProvenance? turn;
}

/// MCP tool that runs as the transport-authenticated caller.
///
/// Dispatch calls [callWithContext] with the caller's identity and the turn it is running, and refuses the call when
/// the transport has no identity to give. Nothing in the call's arguments can set either.
abstract class ContextualMcpTool implements McpTool {
  Future<ToolResult> callWithContext(Map<String, dynamic> args, McpCallerContext context);

  /// Never reached through dispatch; present because [McpTool] declares it, and refuses like a caller with no identity.
  @override
  Future<ToolResult> call(Map<String, dynamic> args) async => const ToolResult.error(_callerContextRequired);
}

const _callerContextRequired = 'Tool requires authenticated caller context';

/// One authenticated `/mcp` caller, as the transport that authenticated it resolves it at each call.
final class McpCaller {
  const new({required this.identity, this.turn = _noTurn, this.policy, this.guardsAsCaller = false});

  /// The deployment itself: the shared gateway token, or the bearerless loopback endpoint.
  static const deployment = McpCaller(identity: _steward);

  static McpCallerIdentity? _steward() => const McpCallerIdentity(authorityId: mcpStewardPrincipal, deployment: true);
  static TurnProvenance? _noTurn() => null;

  /// Whom the call serves; null when the transport has no caller to name (a harness between turns), which refuses
  /// every [ContextualMcpTool].
  final McpCallerIdentity? Function() identity;

  /// The turn the caller is running, or null.
  final TurnProvenance? Function() turn;

  /// Narrows `tools/list` and `tools/call`; null admits every registered tool.
  final McpCallerPolicy? policy;

  /// Whether the dispatch guard chain evaluates a call under this caller's session and agent.
  ///
  /// Only a container caller's: a host harness's own `ToolPolicyGuard` has already decided the call under the names
  /// its provider presents, and a second decision here under this seam's names could only disagree with it.
  final bool guardsAsCaller;
}

/// MCP protocol handler implementing JSON-RPC 2.0 over Streamable HTTP.
///
/// Handles `initialize`, `notifications/initialized`, `tools/list`, and
/// `tools/call` methods. Tools are registered at startup via [registerTool].
class McpProtocolHandler {
  /// The handler for the deployment caller ([McpCaller.deployment]), and the root every [forCaller] view shares.
  ///
  /// [toolCanonicals] maps registered tool names to the canonical taxonomy the guard chain evaluates, so an allowlist
  /// written in canonical names (`web_search`) matches the tool serving it (`brave_search`).
  new({
    ResultTrimmer? resultTrimmer,
    GuardChain? guardChain,
    GuardAuditLogger? auditLogger,
    Map<String, CanonicalTool> toolCanonicals = const {},
  }) : _tools = {},
       _caller = McpCaller.deployment,
       _guardChain = guardChain,
       _auditLogger = auditLogger,
       toolCanonicals = Map.unmodifiable(toolCanonicals),
       _resultTrimmer = resultTrimmer ?? ResultTrimmer();

  new _view(this._tools, this._caller, this._resultTrimmer, this._guardChain, this._auditLogger, this.toolCanonicals)
    : _started = true;

  static final _log = Logger('McpProtocolHandler');
  static const _uuid = Uuid();

  static const _protocolVersion = '2025-03-26';
  static const _serverName = dartclawMcpServerName;
  static const _dispatchGuardName = 'McpDispatchGuard';

  final Map<String, McpTool> _tools;
  final McpCaller _caller;
  final GuardChain? _guardChain;
  final GuardAuditLogger? _auditLogger;
  final ResultTrimmer _resultTrimmer;

  /// Registered tool names mapped to the canonical taxonomy the guard chain and caller policies evaluate.
  final Map<String, CanonicalTool> toolCanonicals;
  bool _started = false;

  /// A handler over the same registered tools, serving [caller].
  ///
  /// The tool map is shared by reference so late registrations stay visible; the view is read-only and cannot
  /// register. The guard chain, audit sink, result trimmer and tool canonicals carry over too: a view that lost them
  /// would be an unenforced path reachable from exactly the least-trusted caller.
  McpProtocolHandler forCaller(McpCaller caller) =>
      McpProtocolHandler._view(_tools, caller, _resultTrimmer, _guardChain, _auditLogger, toolCanonicals);

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
    final policy = _caller.policy;
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
    final policy = _caller.policy;
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

    // Both read now, together: across the guard's await the harness could move to another turn, pairing one turn's
    // session with the next turn's provenance.
    final identity = _caller.identity();
    final turn = _caller.turn();
    final refusal = await _evaluateDispatch(tool, args, identity);
    ToolResult result;
    if (refusal != null) {
      result = refusal;
    } else {
      try {
        result = await switch (tool) {
          ContextualMcpTool() when identity == null => Future<ToolResult>.value(
            const ToolResult.error(_callerContextRequired),
          ),
          ContextualMcpTool() => tool.callWithContext(args, _callerContext(identity!, turn)),
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

  McpCallerContext _callerContext(McpCallerIdentity identity, TurnProvenance? turn) => McpCallerContext(
    authorityId: identity.authorityId,
    sourceEvent: 'mcp-call:${identity.authorityId}:${_uuid.v4()}',
    sessionId: identity.sessionId,
    taskId: identity.taskId,
    agentId: identity.agentId,
    knowledgeScope: identity.knowledgeScope,
    deployment: identity.deployment,
    turn: turn,
  );

  /// Guard-evaluates and audits one dispatch; non-null refuses the call.
  ///
  /// Runs after caller-policy authorization and schema validation, so a policy
  /// denial, an unknown name and a schema rejection reach neither the guard nor
  /// the sink. The entry records that the dispatch was *authorized*, not that
  /// the tool ran.
  ///
  /// [identity] attributes the audit entry. The guard chain sees it only for a caller that
  /// [McpCaller.guardsAsCaller].
  Future<ToolResult?> _evaluateDispatch(McpTool tool, Map<String, dynamic> args, McpCallerIdentity? identity) async {
    final chain = _guardChain;
    final principal = identity?.authorityId ?? mcpStewardPrincipal;
    final guarded = _caller.guardsAsCaller ? identity : null;

    if (chain != null) {
      GuardVerdict verdict;
      try {
        verdict = await chain.evaluateBeforeToolCall(
          toolCanonicals[tool.name]?.stableName ?? tool.name,
          args,
          sessionId: guarded?.sessionId,
          agentId: guarded?.agentId,
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
