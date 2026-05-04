import 'package:dartclaw_core/dartclaw_core.dart';

/// In-memory [WorkflowStepExecutionRepository] used by tests.
class InMemoryWorkflowStepExecutionRepository implements WorkflowStepExecutionRepository {
  final Map<String, WorkflowStepExecution> _executions = <String, WorkflowStepExecution>{};

  bool disposed = false;

  @override
  Future<void> create(WorkflowStepExecution execution) async {
    if (_executions.containsKey(execution.taskId)) {
      throw ArgumentError('WorkflowStepExecution already exists: ${execution.taskId}');
    }
    _executions[execution.taskId] = execution;
  }

  @override
  Future<WorkflowStepExecution?> getByTaskId(String taskId) async => _executions[taskId];

  @override
  Future<List<WorkflowStepExecution>> listByRunId(String workflowRunId) async {
    final executions = _executions.values.where((execution) => execution.workflowRunId == workflowRunId).toList()
      ..sort((a, b) {
        final byStep = a.stepIndex.compareTo(b.stepIndex);
        if (byStep != 0) return byStep;
        return a.taskId.compareTo(b.taskId);
      });
    return executions;
  }

  @override
  Future<void> update(WorkflowStepExecution execution) async {
    if (!_executions.containsKey(execution.taskId)) {
      throw ArgumentError('WorkflowStepExecution not found: ${execution.taskId}');
    }
    _executions[execution.taskId] = execution;
  }

  @override
  Future<void> delete(String taskId) async {
    _executions.remove(taskId);
  }

  Future<void> dispose() async {
    disposed = true;
  }
}
