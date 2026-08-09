part of 'execution_coordinator.dart';

enum ExecutionLane { primary, worker, capacityOnly }

enum ExecutionAdmission { wait, failFast }

enum ExecutionSurface { interactive, channel, task, workflow, logicalAgent, scheduler, advisor, system }

/// Identifies static construction inputs that may safely share a worker process.
final class ExecutionFingerprint {
  const ExecutionFingerprint({required this.providerId, required this.profileId, required this.configurationId});

  final String providerId;
  final String profileId;
  final String configurationId;

  @override
  bool operator ==(Object other) =>
      other is ExecutionFingerprint &&
      other.providerId == providerId &&
      other.profileId == profileId &&
      other.configurationId == configurationId;

  @override
  int get hashCode => Object.hash(providerId, profileId, configurationId);
}

/// Describes one post-governance execution allocation.
final class ExecutionRequest {
  const ExecutionRequest({
    required this.surface,
    required this.providerId,
    required this.sessionId,
    required this.fingerprint,
    this.admission = ExecutionAdmission.wait,
    this.isHumanInput = false,
    this.taskId,
  });

  final ExecutionSurface surface;
  final String providerId;
  final String sessionId;
  final ExecutionFingerprint fingerprint;
  final ExecutionAdmission admission;
  final bool isHumanInput;
  final String? taskId;

  String get profileId => fingerprint.profileId;

  ExecutionRequest _route({String? providerId, ExecutionFingerprint? fingerprint}) {
    return ExecutionRequest(
      surface: surface,
      providerId: providerId ?? this.providerId,
      sessionId: sessionId,
      fingerprint: fingerprint ?? this.fingerprint,
      admission: admission,
      isHumanInput: isHumanInput,
      taskId: taskId,
    );
  }
}

typedef CreateExecutionWorker = Future<TurnRunner> Function(ExecutionRequest request);
typedef ResolveExecutionFingerprint = ExecutionFingerprint Function(String providerId, String profileId);
typedef AdmitExecution = Future<void> Function(ExecutionRequest request);
typedef ReleaseExecutionAdmission = void Function(String sessionId);

final class WorkerCreationException implements Exception {
  const WorkerCreationException(this.message, {this.quarantineSlot = false});

  final String message;
  final bool quarantineSlot;

  @override
  String toString() => 'WorkerCreationException: $message';
}

enum ExecutionEventKind {
  capacityChanged,
  acquired,
  released,
  cached,
  disposed,
  quarantined,
  runnerCreated,
  turnSettled,
}

final class ExecutionEvent {
  const ExecutionEvent({
    required this.kind,
    required this.request,
    required this.lane,
    required this.executionId,
    this.runnerId,
    this.runner,
    this.outcome,
  });

  final ExecutionEventKind kind;
  final ExecutionRequest request;
  final ExecutionLane lane;
  final int executionId;
  final int? runnerId;
  final TurnRunner? runner;
  final TurnOutcome? outcome;
}

final class ProviderCapacitySnapshot {
  const ProviderCapacitySnapshot({
    required this.configured,
    required this.effective,
    required this.active,
    required this.queued,
    required this.cached,
    required this.quarantined,
  });

  final int configured;
  final int effective;
  final int active;
  final int queued;
  final int cached;
  final int quarantined;

  int get available => effective - active;
}

final class ExecutionSnapshot {
  const ExecutionSnapshot({required this.primaryActive, required this.providers});

  final bool primaryActive;
  final Map<String, ProviderCapacitySnapshot> providers;

  int get configuredWorkers => providers.values.fold(0, (sum, item) => sum + item.configured);
  int get effectiveWorkers => providers.values.fold(0, (sum, item) => sum + item.effective);
  int get activeWorkers => providers.values.fold(0, (sum, item) => sum + item.active);
  int get queuedWorkers => providers.values.fold(0, (sum, item) => sum + item.queued);
  int get cachedWorkers => providers.values.fold(0, (sum, item) => sum + item.cached);
  int get quarantinedWorkers => providers.values.fold(0, (sum, item) => sum + item.quarantined);
  int get availableWorkers => effectiveWorkers - activeWorkers;
}
