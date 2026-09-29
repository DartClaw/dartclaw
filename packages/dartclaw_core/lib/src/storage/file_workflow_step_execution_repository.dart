import 'package:dartclaw_kernel/dartclaw_kernel.dart' show WorkflowStepExecution, WorkflowStepExecutionRepository;

import 'file_execution_store.dart';

/// Workflow step persistence over a standalone execution checkpoint.
final class FileWorkflowStepExecutionRepository implements WorkflowStepExecutionRepository {
  /// Binds step executions to [store].
  new(this.store);

  /// Shared checkpoint authority.
  final FileExecutionStore store;

  @override
  Future<void> create(WorkflowStepExecution execution) => store.update((state) {
    final rows = state['workflowSteps'] as Map<String, dynamic>;
    if (rows.containsKey(execution.taskId)) {
      throw StateError('WorkflowStepExecution already exists: ${execution.taskId}');
    }
    _requireReferences(state, execution);
    rows[execution.taskId] = execution.toJson();
  });

  @override
  Future<WorkflowStepExecution?> getByTaskId(String taskId) => store.read((state) {
    final row = (state['workflowSteps'] as Map<String, dynamic>)[taskId];
    return row == null ? null : WorkflowStepExecution.fromJson(Map<String, dynamic>.from(row as Map));
  });

  @override
  Future<List<WorkflowStepExecution>> listByRunId(String workflowRunId) => store.read((state) {
    final rows = (state['workflowSteps'] as Map<String, dynamic>).values
        .map((row) => WorkflowStepExecution.fromJson(Map<String, dynamic>.from(row as Map)))
        .where((execution) => execution.workflowRunId == workflowRunId)
        .toList();
    rows.sort((a, b) {
      final byStep = a.stepIndex.compareTo(b.stepIndex);
      return byStep == 0 ? a.taskId.compareTo(b.taskId) : byStep;
    });
    return rows;
  });

  @override
  Future<void> update(WorkflowStepExecution execution) => store.update((state) {
    final rows = state['workflowSteps'] as Map<String, dynamic>;
    if (!rows.containsKey(execution.taskId)) {
      throw ArgumentError('WorkflowStepExecution not found: ${execution.taskId}');
    }
    _requireReferences(state, execution);
    rows[execution.taskId] = execution.toJson();
  });

  @override
  Future<void> delete(String taskId) => store.update((state) {
    (state['workflowSteps'] as Map<String, dynamic>).remove(taskId);
  });

  void _requireReferences(Map<String, dynamic> state, WorkflowStepExecution execution) {
    if (!(state['tasks'] as Map<String, dynamic>).containsKey(execution.taskId)) {
      throw ArgumentError('Task not found: ${execution.taskId}');
    }
    if (!(state['agentExecutions'] as Map<String, dynamic>).containsKey(execution.agentExecutionId)) {
      throw ArgumentError('AgentExecution not found: ${execution.agentExecutionId}');
    }
  }
}
