part of 'service_wiring.dart';

/// A headless composition paused after base-service assembly.
///
/// The workflow registry and the persisted runs are already usable, so a caller
/// can resolve the definition it is about to run, derive the providers that
/// definition references, and gate their auth — all before any execution
/// capacity exists. That ordering is the point: an unreferenced logged-out
/// provider must not block a run, and a referenced one must abort it before a
/// step dispatches.
///
/// Exactly one completion may run. Until one does, this object owns teardown of
/// the base services; afterwards the returned [DartclawRuntime] does.
final class HeadlessRuntimeStaging {
  new _(this._assembly);

  final _RuntimeAssembly _assembly;
  var _started = false;
  var _completed = false;

  /// The loaded workflow definitions, usable before execution capacity exists.
  WorkflowRegistry get workflowRegistry => _assembly._workflowRegistry;

  /// The event bus every service in this composition shares.
  EventBus get eventBus => _assembly._ctx.eventBus;

  /// Loads a persisted workflow run, so a lifecycle verb can derive the
  /// providers its definition references before committing to execution.
  Future<WorkflowRun?> loadWorkflowRun(String runId) => _assembly._storage.workflowRunRepository.getById(runId);

  /// Gates [providers] through the configured provider-auth preflight, raising
  /// [WorkflowPreflightException] with the provider-named remediation on the
  /// first unauthenticated one.
  Future<void> preflightProviderAuth(Set<String> providers) => _assembly.preflightProviderAuth(providers);

  /// Completes the assembly with execution capacity for [providers] only.
  Future<DartclawRuntime> completeForExecution(Set<String> providers) =>
      _complete(() => _assembly.completeWithExecution(providers));

  /// Completes the assembly with a lifecycle-only workflow service: persisted
  /// run state is mutable, and no execution capacity, task executor or workflow
  /// CLI runner exists. The turn seam stays absent, so an agent step refuses
  /// rather than spawning.
  Future<DartclawRuntime> completeForLifecycle() => _complete(_assembly.completeLifecycleOnly);

  /// Tears the base services down, unless a completion produced a runtime that
  /// now owns them.
  ///
  /// A completion that *threw* leaves no runtime, so teardown stays here — the
  /// caller's `finally` is the only thing that can still close the databases.
  Future<void> dispose() async {
    if (_completed) return;
    await _assembly.disposeBase();
  }

  Future<DartclawRuntime> _complete(Future<DartclawRuntime> Function() completion) async {
    if (_started) throw StateError('This headless staging was already completed');
    _started = true;
    final runtime = await completion();
    _completed = true;
    return runtime;
  }
}
