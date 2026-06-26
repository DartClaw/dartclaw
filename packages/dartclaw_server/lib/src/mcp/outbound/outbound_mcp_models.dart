import 'package:dartclaw_config/dartclaw_config.dart' show McpServerEntry;

/// Calling identity propagated through the outbound MCP guard boundary.
final class OutboundMcpCaller {
  final String sessionId;
  final String? principal;

  const OutboundMcpCaller({required this.sessionId, this.principal});
}

/// Request shape passed to the outbound MCP guard hook.
final class OutboundMcpGuardRequest {
  final String serverName;
  final String toolName;
  final Map<String, dynamic> arguments;
  final OutboundMcpCaller caller;

  const OutboundMcpGuardRequest({
    required this.serverName,
    required this.toolName,
    required this.arguments,
    required this.caller,
  });
}

typedef OutboundMcpGuardHook = Future<void> Function(OutboundMcpGuardRequest request);

/// Decision returned by the outbound egress boundary.
final class OutboundMcpGuardDecision {
  final bool allowed;
  final String decision;
  final String? reason;

  const OutboundMcpGuardDecision._({required this.allowed, required this.decision, this.reason});

  const OutboundMcpGuardDecision.allow() : this._(allowed: true, decision: 'allow');

  const OutboundMcpGuardDecision.deny(String reason) : this._(allowed: false, decision: 'deny', reason: reason);
}

typedef OutboundMcpGuardDecisionHook = Future<OutboundMcpGuardDecision> Function(OutboundMcpGuardRequest request);

/// Tool descriptor returned by an external MCP server.
final class OutboundMcpTool {
  final String name;
  final String? description;
  final Map<String, dynamic> inputSchema;

  const OutboundMcpTool({required this.name, this.description, this.inputSchema = const {}});
}

/// Structured caller-visible failure for transport/protocol/lifecycle errors.
final class OutboundMcpError {
  final String code;
  final String message;
  final String serverName;

  const OutboundMcpError({required this.code, required this.message, required this.serverName});

  Map<String, dynamic> toJson() => {'code': code, 'message': message, 'serverName': serverName};
}

/// Result returned to callers for every outbound `tools/call` attempt.
final class OutboundMcpCallResult {
  final String serverName;
  final String toolName;
  final List<Map<String, dynamic>> content;
  final bool isError;
  final int outboundCallTokens;
  final OutboundMcpError? error;
  final String? decision;
  final String? reason;

  const OutboundMcpCallResult({
    required this.serverName,
    required this.toolName,
    required this.content,
    required this.outboundCallTokens,
    this.isError = false,
    this.error,
    this.decision,
    this.reason,
  });

  bool get isSuccess => error == null;

  Map<String, dynamic> toJson() => {
    'serverName': serverName,
    'toolName': toolName,
    'content': content,
    'isError': isError,
    'outboundCallTokens': outboundCallTokens,
    if (error != null) 'error': error!.toJson(),
    if (decision != null) 'decision': decision,
    if (reason != null) 'reason': reason,
  };
}

/// Registry entry plus stable name consumed by the outbound pool.
final class OutboundMcpServerDefinition {
  final String name;
  final McpServerEntry entry;

  const OutboundMcpServerDefinition({required this.name, required this.entry});
}

/// Outbound connection lifecycle and health event.
final class OutboundMcpLifecycleEvent {
  final String serverName;
  final String type;
  final String? detail;
  final DateTime timestamp;
  final int? outboundCallTokens;

  const OutboundMcpLifecycleEvent({
    required this.serverName,
    required this.type,
    required this.timestamp,
    this.detail,
    this.outboundCallTokens,
  });
}

typedef OutboundMcpObserver = void Function(OutboundMcpLifecycleEvent event);

int estimateOutboundCallTokens(Object? result) {
  final bytes = result.toString().length;
  final estimate = (bytes / 4).ceil();
  return estimate < 1 ? 1 : estimate;
}
