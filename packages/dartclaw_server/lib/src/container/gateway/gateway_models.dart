import 'dart:async';
import 'dart:convert';

import 'package:dartclaw_bridge/dartclaw_bridge.dart';
import 'package:dartclaw_models/dartclaw_models.dart' show ExecutionPolicy;

/// Loopback port the provider bridge listens on inside its container.
///
/// Each container owns its network namespace, so fixed ports stay unique per
/// authority and keep the harness environment deterministic.
const int providerBridgePort = 8080;

/// Loopback port the MCP bridge listens on inside its container.
const int mcpBridgePort = 8081;

/// The loopback port [surface]'s bridge listens on inside the container.
int bridgePortFor(BridgeSurface surface) => switch (surface) {
  BridgeSurface.provider => providerBridgePort,
  BridgeSurface.mcp => mcpBridgePort,
};

/// The execution identity one container authority's pipes are bound to.
///
/// This is S01's worker identity: provider plus effective policy, narrowed to
/// the session and (for logical-agent work) the agent that owns the turn.
/// Nothing here is a credential — it is the subject an authorization decision
/// is made about.
final class GatewayPrincipal {
  const new({
    required this.sessionId,
    required this.providerId,
    required this.policy,
    this.sourceSessionId,
    this.logicalAgentId,
    this.taskId,
  });

  final String sessionId;
  final String providerId;

  /// The effective policy; container profile included.
  final ExecutionPolicy policy;

  /// Real source session known to the host, when [sessionId] is not merely an
  /// execution-authority key such as the primary lane or a workflow fallback.
  final String? sourceSessionId;

  final String? logicalAgentId;
  final String? taskId;

  /// The container profile this authority runs under, or `null` on the host.
  ///
  /// Every profile runs under `network:none`, so a non-null value is what makes
  /// an execution subject to the provider-side network-tool refusal.
  String? get containerProfile => policy.containerProfile;

  /// A stable, secret-free identifier for logs and audit entries.
  String describe() {
    final agent = logicalAgentId;
    return 'session=$sessionId provider=$providerId policy=${policy.describe()}'
        '${agent == null ? '' : ' agent=$agent'}';
  }
}

/// One request arriving from a container over a bound pipe.
final class GatewayRequest {
  const new({
    required this.principal,
    required this.method,
    required this.path,
    required this.headers,
    required this.body,
  });

  final GatewayPrincipal principal;
  final String method;

  /// Request target as the container sent it. Advisory only: the host binds
  /// the destination, so this may not select one.
  final String path;

  final Map<String, List<String>> headers;

  /// Untrusted streaming request body, already bounded by the pipe.
  final Stream<List<int>> body;

  /// Collects the body into a string, refusing anything beyond [maxBytes].
  ///
  /// Decoded as UTF-8, the wire encoding both bridge surfaces use: a byte-wise
  /// decode would silently mangle every non-ASCII argument into text that still
  /// parses as JSON.
  Future<String> readBody({required int maxBytes}) async {
    final builder = <int>[];
    await for (final chunk in body) {
      builder.addAll(chunk);
      if (builder.length > maxBytes) {
        throw const GatewayDenied(status: 413, reason: 'request body exceeds the bridge limit');
      }
    }
    try {
      return utf8.decode(builder);
    } on FormatException {
      throw const GatewayDenied(status: 400, reason: 'request body is not valid UTF-8');
    }
  }
}

/// A host answer streamed back over the pipe.
final class GatewayResponse {
  const new({required this.status, this.headers = const {}, required this.body});

  new empty(this.status, {this.headers = const {}}) : body = const Stream<List<int>>.empty();

  final int status;
  final Map<String, List<String>> headers;
  final Stream<List<int>> body;
}

/// A refusal made on the host before any outbound request or tool dispatch.
///
/// [reason] is written to logs and audit entries, so it must never carry a
/// credential, a request body, or an authority identifier.
final class GatewayDenied implements Exception {
  const new({required this.status, required this.reason});

  final int status;
  final String reason;

  @override
  String toString() => 'GatewayDenied($status): $reason';
}

/// The host-held credential for [providerId] can no longer be presented, and no
/// retry or refresh will repair it.
///
/// Distinct from [GatewayDenied], which refuses one request and leaves the
/// authority live: this ends the authority. A rate or usage limit is *not* this
/// — those are transient conditions the operator waits out, and tearing an
/// authority down over one would turn a wait into a lost turn.
///
/// [remediation] is operator-facing and names a command, never a credential.
final class GatewayCredentialUnusable implements Exception {
  const new({required this.providerId, required this.remediation});

  final String providerId;
  final String remediation;

  @override
  String toString() => 'GatewayCredentialUnusable($providerId): $remediation';
}

/// One host-enforced service a pipe can be bound to.
abstract interface class GatewaySurfaceHandler {
  /// The surface this handler serves. A pipe accepts only its own.
  BridgeSurface get surface;

  Future<GatewayResponse> handle(GatewayRequest request);
}

/// Bidirectional byte channel to one in-container bridge process.
///
/// Abstracted so the gateway can be driven by a fake in tests and by
/// `docker exec -i` in production without either knowing about the other.
abstract interface class BridgeChannel {
  Stream<List<int>> get incoming;

  /// Completes once the bytes have been handed to the far end, so the OS pipe
  /// rather than an unbounded buffer carries host-to-container backpressure.
  Future<void> send(List<int> bytes);

  /// Terminates the underlying process and releases the pipe. Idempotent.
  Future<void> close();
}
