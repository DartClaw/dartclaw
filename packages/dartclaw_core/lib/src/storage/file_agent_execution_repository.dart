import 'package:dartclaw_kernel/dartclaw_kernel.dart' show AgentExecution, AgentExecutionRepository;

import '../events/dartclaw_event.dart';
import '../events/event_bus.dart';
import 'file_execution_store.dart';

/// Agent execution persistence over a standalone execution checkpoint.
final class FileAgentExecutionRepository implements AgentExecutionRepository {
  /// Binds executions and optional status events to [store].
  new(this.store, {EventBus? eventBus}) : _eventBus = eventBus;

  /// Shared checkpoint authority.
  final FileExecutionStore store;
  final EventBus? _eventBus;

  @override
  Future<void> create(AgentExecution execution) => store.update((state) {
    final rows = state['agentExecutions'] as Map<String, dynamic>;
    if (rows.containsKey(execution.id)) throw StateError('AgentExecution already exists: ${execution.id}');
    rows[execution.id] = execution.toJson();
  });

  @override
  Future<AgentExecution?> get(String id) => store.read((state) {
    final row = (state['agentExecutions'] as Map<String, dynamic>)[id];
    return row == null ? null : AgentExecution.fromJson(Map<String, dynamic>.from(row as Map));
  });

  @override
  Future<List<AgentExecution>> list({String? sessionId, String? provider}) => store.read((state) {
    final rows = (state['agentExecutions'] as Map<String, dynamic>).values
        .map((row) => AgentExecution.fromJson(Map<String, dynamic>.from(row as Map)))
        .where(
          (execution) =>
              (sessionId == null || execution.sessionId == sessionId) &&
              (provider == null || execution.provider == provider),
        )
        .toList();
    rows.sort((a, b) {
      final byTime = (b.startedAt ?? DateTime(0)).compareTo(a.startedAt ?? DateTime(0));
      return byTime == 0 ? b.id.compareTo(a.id) : byTime;
    });
    return rows;
  });

  @override
  Future<void> update(AgentExecution execution, {String trigger = 'system', DateTime? timestamp}) async {
    final oldStatus = await store.update((state) {
      final rows = state['agentExecutions'] as Map<String, dynamic>;
      final current = rows[execution.id];
      if (current == null) throw ArgumentError('AgentExecution not found: ${execution.id}');
      final previous = AgentExecution.fromJson(Map<String, dynamic>.from(current as Map));
      rows[execution.id] = execution.toJson();
      return _statusOf(previous);
    });
    final newStatus = _statusOf(execution);
    if (oldStatus != newStatus) {
      _eventBus?.fire(
        AgentExecutionStatusChangedEvent(
          agentExecutionId: execution.id,
          oldStatus: oldStatus,
          newStatus: newStatus,
          trigger: trigger,
          timestamp: timestamp ?? DateTime.now(),
        ),
      );
    }
  }

  @override
  Future<void> delete(String id) => store.update((state) {
    final taskReferences = (state['tasks'] as Map<String, dynamic>).values.any(
      (row) => (row as Map<String, dynamic>)['agentExecutionId'] == id,
    );
    final stepReferences = (state['workflowSteps'] as Map<String, dynamic>).values.any(
      (row) => (row as Map<String, dynamic>)['agentExecutionId'] == id,
    );
    if (taskReferences || stepReferences) throw StateError('AgentExecution is referenced: $id');
    (state['agentExecutions'] as Map<String, dynamic>).remove(id);
  });

  String _statusOf(AgentExecution execution) {
    if (execution.completedAt != null) return 'completed';
    if (execution.startedAt != null) return 'running';
    return 'queued';
  }
}
