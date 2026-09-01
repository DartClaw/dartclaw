part of 'execution_coordinator.dart';

/// The execution resource selected by the coordinator for a request surface.
enum ExecutionLane { primary, worker }

/// Whether worker-capacity acquisition queues or returns immediately.
enum ExecutionAdmission { wait, failFast }

/// Identifies the product surface requesting execution.
enum ExecutionSurface { interactive, channel, task, workflow, logicalAgent, scheduler }

/// Describes one post-governance execution allocation.
final class ExecutionRequest {
  const new({
    required this.surface,
    required this.providerId,
    required this.policy,
    required this.sessionId,
    this.admission = ExecutionAdmission.wait,
    this.isHumanInput = false,
    this.taskId,
    this.logicalAgentId,
    this.allowedTools,
    this.artifactsDir,
    this.spawnEnvironment,
  });

  final ExecutionSurface surface;
  final String providerId;

  /// The complete effective policy resolved for this request.
  ///
  /// Together with [providerId] this is the worker compatibility identity: a
  /// host worker and a container worker are never interchangeable, and neither
  /// are two container workers built from different profiles.
  final ExecutionPolicy policy;
  final String sessionId;
  final ExecutionAdmission admission;
  final bool isHumanInput;
  final String? taskId;

  /// The logical agent this execution runs as, when one owns the turn.
  ///
  /// Part of the execution principal: an agent's authorized capabilities are
  /// derived from its definition, so the identity has to reach whatever grants
  /// them.
  final String? logicalAgentId;

  /// The tool policy already in force for this execution, when it carries one
  /// of its own rather than a logical agent's.
  ///
  /// Background work has no agent definition to derive capability from, so this
  /// is what a container authority's host-tool grant is resolved against.
  final List<String>? allowedTools;

  /// Host-owned directory and process variables fixed when this worker is built.
  ///
  /// Either value makes the worker execution-scoped: a later execution cannot
  /// safely reuse a harness whose process environment or mounts were fixed for
  /// this request.
  final String? artifactsDir;
  final Map<String, String>? spawnEnvironment;

  bool get hasExecutionScopedConstructionInputs => artifactsDir != null || spawnEnvironment != null;

  ExecutionRequest _route({String? providerId, ExecutionPolicy? policy}) {
    return ExecutionRequest(
      surface: surface,
      providerId: providerId ?? this.providerId,
      policy: policy ?? this.policy,
      sessionId: sessionId,
      admission: admission,
      isHumanInput: isHumanInput,
      taskId: taskId,
      logicalAgentId: logicalAgentId,
      allowedTools: allowedTools,
      artifactsDir: artifactsDir,
      spawnEnvironment: spawnEnvironment,
    );
  }
}

/// Builds an unstarted worker. The coordinator exclusively owns its lifecycle.
typedef CreateExecutionWorker = Future<TurnRunner> Function(ExecutionRequest request);

/// Identifies a container authority being released.
final class ExecutionReleaseContext {
  const new({required this.request, required this.runner});

  /// The request the released authority was created for.
  final ExecutionRequest request;

  /// The runner whose harness has already terminated.
  final TurnRunner runner;

  /// The released authority's effective policy.
  ExecutionPolicy get policy => runner.executionPolicy;
}

/// Runs during container-authority release, after the harness process has
/// terminated and before the container is destroyed.
///
/// The seam exists so authority-scoped resources granted to a container (pipes,
/// bridge authorizations) are revoked while the container still exists but can
/// no longer run anything. Hooks complete before capacity is returned.
typedef ExecutionReleaseHook = Future<void> Function(ExecutionReleaseContext context);

/// Destroys the dedicated container backing a released container authority.
typedef DestroyContainerAuthority = Future<void> Function(ExecutionReleaseContext context);

/// Reserves a logical session before capacity or a runner is acquired.
typedef AdmitExecution = Future<void> Function(ExecutionRequest request);

/// Releases a logical-session reservation previously made by [AdmitExecution].
typedef ReleaseExecutionAdmission = void Function(String sessionId);

final class WorkerCreationException implements Exception {
  const new(this.message);

  final String message;

  @override
  String toString() => 'WorkerCreationException: $message';
}

enum ExecutionEventKind { capacityChanged, acquired, released, disposed, quarantined, runnerCreated, turnSettled }

final class ExecutionEvent {
  const new({required this.kind, required this.request, required this.lane, this.runnerId, this.runner, this.outcome});

  final ExecutionEventKind kind;
  final ExecutionRequest request;
  final ExecutionLane lane;
  final int? runnerId;
  final TurnRunner? runner;
  final TurnOutcome? outcome;
}

/// Immutable capacity state for one provider.
final class ProviderCapacitySnapshot {
  const new({
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
  const new({required this.primaryActive, required this.providers});

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
