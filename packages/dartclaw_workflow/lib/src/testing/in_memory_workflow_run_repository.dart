import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import '../workflow/workflow_run.dart';
import '../workflow/workflow_run_repository.dart';

final class InMemoryWorkflowRunRepository implements WorkflowRunRepository {
  final Map<String, WorkflowRun> _runs = {};

  @override
  Future<void> insert(WorkflowRun run) async {
    if (_runs.containsKey(run.id)) throw ArgumentError('WorkflowRun already exists: ${run.id}');
    _runs[run.id] = run;
  }

  @override
  Future<WorkflowRun?> getById(String id) async => _runs[id];

  @override
  Future<List<WorkflowRun>> list({WorkflowRunStatus? status, String? definitionName}) async {
    final runs = _runs.values.where((run) {
      if (status != null && run.status != status) return false;
      return definitionName == null || run.definitionName == definitionName;
    }).toList();
    runs.sort((left, right) {
      final byStarted = right.startedAt.compareTo(left.startedAt);
      return byStarted != 0 ? byStarted : right.id.compareTo(left.id);
    });
    return runs;
  }

  @override
  Future<void> update(WorkflowRun run) async {
    if (!_runs.containsKey(run.id)) throw ArgumentError('WorkflowRun not found: ${run.id}');
    _runs[run.id] = run;
  }

  @override
  Future<void> delete(String id) async {
    _runs.remove(id);
  }

  @override
  Future<void> setWorktreeBinding(String runId, WorkflowWorktreeBinding binding) async {
    final run = _runs[runId];
    if (run == null) throw ArgumentError('Workflow run not found: $runId');
    final bindings = <WorkflowWorktreeBinding>[
      for (final current in run.workflowWorktrees)
        if (current.key != binding.key) current,
      binding,
    ];
    _runs[runId] = run.copyWith(workflowWorktrees: bindings, updatedAt: DateTime.now());
  }

  @override
  Future<WorkflowWorktreeBinding?> getWorktreeBinding(String runId) async {
    final bindings = _runs[runId]?.workflowWorktrees ?? const <WorkflowWorktreeBinding>[];
    return bindings.isEmpty ? null : bindings.last;
  }

  @override
  Future<List<WorkflowWorktreeBinding>> getWorktreeBindings(String runId) async =>
      _runs[runId]?.workflowWorktrees ?? const <WorkflowWorktreeBinding>[];
}
