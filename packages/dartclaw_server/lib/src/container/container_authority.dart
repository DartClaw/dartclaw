import 'package:dartclaw_core/dartclaw_core.dart' show ContainerExecutor;

import 'gateway/gateway_models.dart';

/// A dedicated container authority held for the length of one execution.
///
/// The lease owns the container, its bridge processes, and its host-side
/// registration together: releasing it revokes all three. Nothing survives to
/// be reused by a later execution.
abstract interface class ContainerAuthorityLease {
  ContainerExecutor get container;

  /// Revokes the bridges and destroys the container. Idempotent.
  ///
  /// Throws when destruction cannot be confirmed; callers must quarantine any
  /// capacity reserved for the authority. A failed release remains retryable.
  Future<void> release();
}

/// Creates a container authority whose required bridge surfaces are ready.
///
/// Implementations must not return until mediation is usable — a turn that
/// starts against a half-established surface would fail mid-conversation with
/// no way to distinguish it from a provider outage.
/// [allowedMcpTools] holds canonical tool names, resolved host-side from the
/// execution's effective tool policy. Empty – the default – starts no MCP
/// surface at all, so a container reaches no host tool unless one was granted.
/// [artifactsDir] is the host directory this execution must be able to write
/// its durable outputs to; it is mounted read-write into the container.
typedef ContainerAuthorityProvider =
    Future<ContainerAuthorityLease> Function(
      GatewayPrincipal principal, {
      Set<String> allowedMcpTools,
      String? artifactsDir,
    });
