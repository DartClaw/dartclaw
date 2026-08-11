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
  Future<void> release();
}

/// Creates a container authority whose required bridge surfaces are ready.
///
/// Implementations must not return until mediation is usable — a turn that
/// starts against a half-established surface would fail mid-conversation with
/// no way to distinguish it from a provider outage.
typedef ContainerAuthorityProvider = Future<ContainerAuthorityLease> Function(GatewayPrincipal principal);
