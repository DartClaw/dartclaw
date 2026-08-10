part of 'execution_coordinator.dart';

/// The execution resource selected by the coordinator for a request surface.
enum ExecutionLane { primary, worker, capacityOnly }

/// Whether worker-capacity acquisition queues or returns immediately.
enum ExecutionAdmission { wait, failFast }

/// Identifies the product surface requesting execution.
enum ExecutionSurface { interactive, channel, task, workflow, logicalAgent, scheduler, advisor }

/// Describes one post-governance execution allocation.
final class ExecutionRequest {
  const ExecutionRequest({
    required this.surface,
    required this.providerId,
    required this.profileId,
    required this.sessionId,
    this.admission = ExecutionAdmission.wait,
    this.isHumanInput = false,
    this.taskId,
  });

  final ExecutionSurface surface;
  final String providerId;
  final String profileId;
  final String sessionId;
  final ExecutionAdmission admission;
  final bool isHumanInput;
  final String? taskId;

  ExecutionRequest _route({String? providerId, String? profileId}) {
    return ExecutionRequest(
      surface: surface,
      providerId: providerId ?? this.providerId,
      profileId: profileId ?? this.profileId,
      sessionId: sessionId,
      admission: admission,
      isHumanInput: isHumanInput,
      taskId: taskId,
    );
  }
}

/// Builds an unstarted worker. The coordinator exclusively owns its lifecycle.
typedef CreateExecutionWorker = Future<TurnRunner> Function(ExecutionRequest request);

/// Reserves a logical session before capacity or a runner is acquired.
typedef AdmitExecution = Future<void> Function(ExecutionRequest request);

/// Releases a logical-session reservation previously made by [AdmitExecution].
typedef ReleaseExecutionAdmission = void Function(String sessionId);

final class WorkerCreationException implements Exception {
  const WorkerCreationException(this.message);

  final String message;

  @override
  String toString() => 'WorkerCreationException: $message';
}

enum ExecutionEventKind { capacityChanged, acquired, released, disposed, quarantined, runnerCreated, turnSettled }

final class ExecutionEvent {
  const ExecutionEvent({
    required this.kind,
    required this.request,
    required this.lane,
    this.runnerId,
    this.runner,
    this.outcome,
  });

  final ExecutionEventKind kind;
  final ExecutionRequest request;
  final ExecutionLane lane;
  final int? runnerId;
  final TurnRunner? runner;
  final TurnOutcome? outcome;
}

/// Immutable capacity state for one provider.
final class ProviderCapacitySnapshot {
  const ProviderCapacitySnapshot({
    required this.configured,
    required this.effective,
    required this.active,
    required this.queued,
    required this.cached,
    required this.quarantined,
  });

  /// Configured concurrency ceiling.
  final int configured;

  /// Usable ceiling after quarantined slots are removed.
  final int effective;

  /// Currently leased slots.
  final int active;

  /// Requests waiting for a slot.
  final int queued;

  /// Idle reusable workers.
  final int cached;

  /// Slots withheld because process termination could not be confirmed.
  final int quarantined;

  int get available => effective - active;
}

/// Immutable aggregate execution-capacity state.
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
