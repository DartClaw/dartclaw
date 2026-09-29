import 'package:dartclaw_core/dartclaw_core.dart' show FileExecutionStore;
import 'package:dartclaw_kernel/dartclaw_kernel.dart' show WorkflowRunStatus;

import '../workflow/workflow_run.dart';
import '../workflow/workflow_run_repository.dart';

/// Workflow runs in the standalone execution checkpoint.
class FileWorkflowRunRepository implements WorkflowRunRepository, WorkflowRunChangeSource {
  /// Shares [store] with the task and execution repositories.
  new(this._store);

  final FileExecutionStore _store;

  @override
  Stream<WorkflowRunStatus> watchStatus(String runId) => _pollStatus(runId).distinct();

  Stream<WorkflowRunStatus> _pollStatus(String runId) async* {
    while (true) {
      final run = await getById(runId);
      if (run == null) throw StateError('Workflow run disappeared from the standalone store: $runId');
      yield run.status;
      if (run.status.terminal) return;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
  }

  @override
  Future<void> insert(WorkflowRun run) => _store.update((state) {
    final runs = _runs(state);
    if (runs.containsKey(run.id)) throw ArgumentError('Workflow run already exists: ${run.id}');
    runs[run.id] = run.toJson();
  });

  @override
  Future<WorkflowRun?> getById(String id) => _store.read((state) => _get(state, id));

  @override
  Future<List<WorkflowRun>> list({WorkflowRunStatus? status, String? definitionName}) => _store.read((state) {
    final runs = _runs(state).values
        .map((value) => _decode(value as Map<String, dynamic>))
        .where(
          (run) =>
              (status == null || run.status == status) &&
              (definitionName == null || run.definitionName == definitionName),
        )
        .toList();
    runs.sort((left, right) {
      final byStarted = right.startedAt.compareTo(left.startedAt);
      return byStarted != 0 ? byStarted : right.id.compareTo(left.id);
    });
    return runs;
  });

  @override
  Future<bool> update(WorkflowRun run, {WorkflowRunStatus? expectedStatus, DateTime? expectedUpdatedAt}) =>
      _store.update((state) {
        final existing = _get(state, run.id);
        if (existing == null ||
            (expectedStatus != null && existing.status != expectedStatus) ||
            (expectedUpdatedAt != null && existing.updatedAt != expectedUpdatedAt)) {
          return false;
        }
        _runs(state)[run.id] = run
            .copyWith(
              workflowWorktrees: run.workflowWorktrees.isEmpty ? existing.workflowWorktrees : run.workflowWorktrees,
            )
            .toJson();
        return true;
      });

  @override
  Future<WorkflowRun?> transitionStatus(
    String id, {
    required WorkflowRunStatus expectedStatus,
    required WorkflowRunStatus status,
    DateTime? completedAt,
  }) => _store.update((state) {
    final current = _get(state, id);
    if (current == null || current.status != expectedStatus) return null;
    final updated = current.copyWith(
      status: status,
      completedAt: completedAt,
      errorMessage: null,
      updatedAt: DateTime.now(),
    );
    _runs(state)[id] = updated.toJson();
    return updated;
  });

  @override
  Future<void> delete(String id) => _store.update((state) {
    _runs(state).remove(id);
  });

  @override
  Future<void> setWorktreeBinding(String runId, WorkflowWorktreeBinding binding) => _store.update((state) {
    final run = _get(state, runId);
    if (run == null) throw ArgumentError('Workflow run not found: $runId');
    _runs(state)[runId] = run
        .copyWith(
          workflowWorktrees: [
            for (final current in run.workflowWorktrees)
              if (current.key != binding.key) current,
            binding,
          ],
          updatedAt: DateTime.now(),
        )
        .toJson();
  });

  @override
  Future<WorkflowWorktreeBinding?> getWorktreeBinding(String runId) async =>
      (await getWorktreeBindings(runId)).lastOrNull;

  @override
  Future<List<WorkflowWorktreeBinding>> getWorktreeBindings(String runId) =>
      _store.read((state) => _get(state, runId)?.workflowWorktrees ?? const []);

  Map<String, dynamic> _runs(Map<String, dynamic> state) => state['workflowRuns'] as Map<String, dynamic>;

  WorkflowRun? _get(Map<String, dynamic> state, String id) {
    final value = _runs(state)[id];
    return value == null ? null : _decode(value as Map<String, dynamic>);
  }

  WorkflowRun _decode(Map<String, dynamic> value) {
    final run = WorkflowRun.fromJson(value);
    if (value['executionCursor'] != null && run.executionCursor == null) {
      throw FormatException('Unsupported workflow execution cursor in ${_store.path} for run ${run.id}');
    }
    return run;
  }
}
