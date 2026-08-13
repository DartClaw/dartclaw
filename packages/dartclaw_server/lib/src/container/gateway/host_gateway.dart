import 'dart:async';

import 'package:dartclaw_bridge/dartclaw_bridge.dart';
import 'package:dartclaw_core/dartclaw_core.dart' show CanonicalTool;
import 'package:logging/logging.dart';

import '../../mcp/mcp_server.dart';
import 'gateway_models.dart';
import 'gateway_pipe.dart';
import 'mcp_bridge_surface.dart';
import 'provider_adapter.dart';

/// Reports a host-side refusal for auditing. Carries no request content.
typedef GatewayDenialSink = void Function(GatewayPrincipal principal, String reason);

/// One live container authority's host-side registration.
///
/// Created before its container's bridges start and revoked when the authority
/// is released. Revocation is permanent: nothing re-registers an authority, so
/// a captured pipe or request ID cannot be revived by a later execution.
final class GatewayAuthority {
  new _({
    required this.id,
    required this.principal,
    required this.requiredSurfaces,
    required Set<String> allowedMcpTools,
  }) : allowedMcpTools = Set.unmodifiable(allowedMcpTools);

  final String id;
  final GatewayPrincipal principal;

  /// Surfaces whose bridges must be ready before a turn is admitted.
  final Set<BridgeSurface> requiredSurfaces;

  /// Canonical MCP tool names this authority may reach; empty means none.
  final Set<String> allowedMcpTools;

  final Map<BridgeSurface, GatewayPipe> _pipes = {};
  bool _revoked = false;

  bool get isRevoked => _revoked;

  /// Completes once every required surface has handshaked and is listening.
  Future<void> get ready async {
    final missing = requiredSurfaces.difference(_pipes.keys.toSet());
    if (missing.isNotEmpty) {
      throw StateError('Bridge surfaces not attached: ${missing.map((s) => s.name).join(', ')}');
    }
    await Future.wait([for (final surface in requiredSurfaces) _pipes[surface]!.ready]);
  }
}

/// Owns every live bridge pipe and the host services they reach.
///
/// The gateway is the only place a container's traffic acquires an identity:
/// the pipe it arrived on determines the principal, the surface, the upstream,
/// the credential, and the tool policy. No frame contributes to that decision.
final class HostGateway {
  new({
    required Map<String, ProviderMediator> providerAdapters,
    McpProtocolHandler Function()? mcpHandler,
    Map<String, CanonicalTool> Function()? mcpToolCanonicals,
    GatewayDenialSink? onDenied,
    this.limits = BridgeLimits.defaults,
  }) : _providerAdapters = Map.unmodifiable(providerAdapters),
       _mcpHandler = mcpHandler,
       _mcpToolCanonicals = mcpToolCanonicals,
       _onDenied = onDenied;

  static final _log = Logger('HostGateway');

  final BridgeLimits limits;

  final Map<String, ProviderMediator> _providerAdapters;

  /// Resolved lazily: the MCP registry is built after this gateway, while
  /// authorities are created later still.
  final McpProtocolHandler Function()? _mcpHandler;
  final Map<String, CanonicalTool> Function()? _mcpToolCanonicals;
  final GatewayDenialSink? _onDenied;

  final Map<String, GatewayAuthority> _authorities = {};
  int _nextAuthorityId = 1;
  bool _disposed = false;

  int get liveAuthorityCount => _authorities.length;

  /// Registers a new authority. The returned handle owns its pipes' lifetime.
  ///
  /// [allowedMcpTools] holds canonical tool names derived host-side from the
  /// effective agent definition. An empty set is the default and exposes no
  /// tools, so the MCP surface is not started at all.
  GatewayAuthority register({required GatewayPrincipal principal, Set<String> allowedMcpTools = const {}}) {
    if (_disposed) {
      throw StateError('Host gateway is shut down');
    }
    final adapter = _providerAdapters[principal.providerId];
    if (adapter == null) {
      throw StateError(
        'Provider "${principal.providerId}" has no host mediation adapter, so it cannot run in a container',
      );
    }
    // Admission-time, not request-time: an execution must never be started on
    // mediation the host already knows it cannot perform.
    final unavailable = adapter.unavailableReason;
    if (unavailable != null) {
      throw StateError(unavailable);
    }
    if (allowedMcpTools.isNotEmpty && _mcpHandler == null) {
      throw StateError('Host gateway has no MCP registry, so bridged MCP tools cannot be authorized');
    }
    final surfaces = <BridgeSurface>{BridgeSurface.provider, if (allowedMcpTools.isNotEmpty) BridgeSurface.mcp};
    final authority = GatewayAuthority._(
      id: 'authority-${_nextAuthorityId++}',
      principal: principal,
      requiredSurfaces: surfaces,
      allowedMcpTools: allowedMcpTools,
    );
    _authorities[authority.id] = authority;
    _log.fine('Registered gateway authority ${authority.id} for ${principal.describe()}');
    return authority;
  }

  /// Binds one bridge process to [authority] and [surface].
  ///
  /// Returns once the pipe exists; use [GatewayAuthority.ready] to wait for the
  /// handshake and listener. Attaching to a revoked authority, or attaching a
  /// second pipe for the same surface, is refused.
  GatewayPipe attach(GatewayAuthority authority, BridgeSurface surface, BridgeChannel channel) {
    if (authority.isRevoked || !_authorities.containsKey(authority.id)) {
      throw StateError('Gateway authority ${authority.id} is revoked');
    }
    if (authority._pipes.containsKey(surface)) {
      throw StateError('Gateway authority ${authority.id} already owns a ${surface.name} pipe');
    }
    final pipe = GatewayPipe(
      surface: surface,
      principal: authority.principal,
      channel: channel,
      handler: _handlerFor(authority, surface),
      limits: limits,
      onDenied: _onDenied,
    );
    authority._pipes[surface] = pipe;
    return pipe;
  }

  /// Permanently revokes an authority and closes its pipes.
  ///
  /// Idempotent, and safe on a partially-attached authority: release must work
  /// identically on success, failure, cancellation, and quarantine.
  Future<void> revoke(GatewayAuthority authority) async {
    if (authority._revoked) return;
    authority._revoked = true;
    _authorities.remove(authority.id);
    for (final pipe in authority._pipes.values) {
      try {
        await pipe.revoke();
      } catch (error, stackTrace) {
        _log.warning('Failed to revoke ${pipe.surface.name} pipe for ${authority.id}', error, stackTrace);
      }
    }
    authority._pipes.clear();
    _log.fine('Revoked gateway authority ${authority.id}');
  }

  /// Revokes every authority and releases the adapters' upstream clients.
  Future<void> dispose() async {
    _disposed = true;
    for (final authority in _authorities.values.toList()) {
      await revoke(authority);
    }
    for (final adapter in _providerAdapters.values) {
      await adapter.dispose();
    }
  }

  GatewaySurfaceHandler _handlerFor(GatewayAuthority authority, BridgeSurface surface) => switch (surface) {
    BridgeSurface.provider => _providerAdapters[authority.principal.providerId]!,
    BridgeSurface.mcp => McpBridgeSurface(
      handler: _mcpHandler!(),
      principal: authority.principal,
      allowedCanonicalTools: authority.allowedMcpTools,
      toolCanonicals: _mcpToolCanonicals?.call() ?? const {},
      onDenied: (principal, toolName) => _onDenied?.call(principal, 'mcp: tool "$toolName" is not authorized'),
    ),
  };
}
