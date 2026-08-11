import 'dart:convert';

import 'package:dartclaw_bridge/dartclaw_bridge.dart';
import 'package:dartclaw_core/dartclaw_core.dart' show CanonicalTool;

import '../../mcp/mcp_server.dart';
import 'gateway_models.dart';

/// Host-enforced MCP for one container authority.
///
/// The authority's tool policy is bound here, at pipe registration, so a
/// container calling `tools/call` directly is authorized exactly as one that
/// respected the filtered `tools/list`. Client-side suppression is not part of
/// the decision.
final class McpBridgeSurface implements GatewaySurfaceHandler {
  McpBridgeSurface({
    required McpProtocolHandler handler,
    required this.principal,
    required Set<String> allowedCanonicalTools,
    required Map<String, CanonicalTool> toolCanonicals,
    void Function(GatewayPrincipal principal, String toolName)? onDenied,
    this.maxRequestBytes = 1024 * 1024,
  }) : _policy = _BridgeToolPolicy(
         principal: principal,
         allowedCanonicalTools: allowedCanonicalTools,
         toolCanonicals: toolCanonicals,
         onDenied: onDenied,
       ) {
    _scoped = handler.scopedTo(_policy);
  }

  final GatewayPrincipal principal;
  final int maxRequestBytes;

  final _BridgeToolPolicy _policy;
  late final McpProtocolHandler _scoped;

  /// Canonical tool names this authority may reach. Empty means no MCP access.
  Set<String> get allowedCanonicalTools => _policy.allowedCanonicalTools;

  @override
  BridgeSurface get surface => BridgeSurface.mcp;

  @override
  Future<GatewayResponse> handle(GatewayRequest request) async {
    if (request.method.toUpperCase() != 'POST') {
      throw const GatewayDenied(status: 405, reason: 'MCP accepts POST only');
    }
    final body = await request.readBody(maxBytes: maxRequestBytes);
    final response = await _scoped.handleRequest(body);
    if (response == null) {
      return GatewayResponse.empty(202);
    }
    final encoded = utf8.encode(response);
    return GatewayResponse(
      status: 200,
      headers: {
        'content-type': const ['application/json'],
      },
      body: Stream<List<int>>.value(encoded),
    );
  }
}

/// Deny-by-default tool policy for one authority.
///
/// Allowlists are written in canonical tool names; the host maps each
/// registered implementation to its canonical name at dispatch. An authority
/// with no configured allowlist reaches no tools at all — the host MCP surface
/// was previously unreachable from a container, so exposure is opt-in.
final class _BridgeToolPolicy implements McpCallerPolicy {
  _BridgeToolPolicy({
    required this.principal,
    required Set<String> allowedCanonicalTools,
    required Map<String, CanonicalTool> toolCanonicals,
    void Function(GatewayPrincipal principal, String toolName)? onDenied,
  }) : allowedCanonicalTools = Set.unmodifiable(allowedCanonicalTools),
       _toolCanonicals = Map.unmodifiable(toolCanonicals),
       _onDenied = onDenied;

  final GatewayPrincipal principal;
  final Set<String> allowedCanonicalTools;
  final Map<String, CanonicalTool> _toolCanonicals;
  final void Function(GatewayPrincipal principal, String toolName)? _onDenied;

  @override
  bool allows(String toolName) {
    if (allowedCanonicalTools.isEmpty) return false;
    // A tool with no explicit canonical mapping is not exposed at all. The
    // generic `mcp_call` canonical covers every unmapped tool at once —
    // including outbound third-party MCP adapters — so treating it as a grant
    // would turn one allowlist entry into a wildcard over the whole registry.
    final canonical = _toolCanonicals[toolName];
    if (canonical == null || canonical == CanonicalTool.mcpCall) return false;
    return allowedCanonicalTools.contains(canonical.stableName);
  }

  @override
  void onDenied(String toolName) => _onDenied?.call(principal, toolName);
}
