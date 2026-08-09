part of 'execution_coordinator.dart';

extension _ExecutionCoordinatorValidation on ExecutionCoordinator {
  ExecutionRequest _routeRequest(ExecutionRequest request, ExecutionLane lane) {
    if (lane != ExecutionLane.primary) return request;
    final primary = _primary;
    if (primary == null) return request;
    return request._route(
      providerId: primary.providerId,
      fingerprint: fingerprintFor(primary.providerId, primary.profileId),
    );
  }

  void _validateRequest(ExecutionRequest request, ExecutionLane lane) {
    if (request.providerId.trim().isEmpty) {
      throw ArgumentError.value(request.providerId, 'providerId', 'must not be blank');
    }
    if (request.profileId.trim().isEmpty) {
      throw ArgumentError.value(request.profileId, 'profileId', 'must not be blank');
    }
    if (request.providerId != request.fingerprint.providerId) {
      throw ArgumentError('Execution provider must match its fingerprint');
    }

    switch (lane) {
      case ExecutionLane.primary:
        final primary = _primary;
        if (primary == null) {
          throw StateError('Primary execution is unavailable in this composition');
        }
        if (request.providerId != primary.providerId || request.profileId != primary.profileId) {
          throw StateError('Primary execution must match the primary provider and security profile');
        }
        final interactive =
            request.surface == ExecutionSurface.interactive || request.surface == ExecutionSurface.channel;
        final sdkBackground =
            allowsPrimaryBackgroundFallback &&
            (request.surface == ExecutionSurface.task ||
                request.surface == ExecutionSurface.scheduler ||
                request.surface == ExecutionSurface.system);
        if (!interactive && !sdkBackground) {
          throw StateError('${request.surface.name} execution cannot use the primary lane');
        }
      case ExecutionLane.worker:
        if (request.surface == ExecutionSurface.interactive ||
            request.surface == ExecutionSurface.channel ||
            request.surface == ExecutionSurface.workflow) {
          throw StateError('${request.surface.name} execution cannot use a worker lane');
        }
      case ExecutionLane.capacityOnly:
        if (request.surface != ExecutionSurface.workflow) {
          throw StateError('Only workflow execution may use a capacity-only lane');
        }
    }
  }
}
