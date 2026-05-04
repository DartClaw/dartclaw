import 'package:dartclaw_core/dartclaw_core.dart';

/// In-memory [AgentExecutionRepository] used by tests.
class InMemoryAgentExecutionRepository implements AgentExecutionRepository {
  final Map<String, AgentExecution> _executions = <String, AgentExecution>{};

  bool disposed = false;

  @override
  Future<void> create(AgentExecution execution) async {
    if (_executions.containsKey(execution.id)) {
      throw ArgumentError('AgentExecution already exists: ${execution.id}');
    }
    _executions[execution.id] = execution;
  }

  @override
  Future<AgentExecution?> get(String id) async => _executions[id];

  @override
  Future<List<AgentExecution>> list({String? sessionId, String? provider}) async {
    final executions =
        _executions.values.where((execution) {
          if (sessionId != null && execution.sessionId != sessionId) {
            return false;
          }
          if (provider != null && execution.provider != provider) {
            return false;
          }
          return true;
        }).toList()..sort((a, b) {
          final byStartedAt = _compareNullableDateTimes(b.startedAt, a.startedAt);
          if (byStartedAt != 0) {
            return byStartedAt;
          }
          return b.id.compareTo(a.id);
        });
    return executions;
  }

  @override
  Future<void> update(AgentExecution execution, {String trigger = 'system', DateTime? timestamp}) async {
    if (!_executions.containsKey(execution.id)) {
      throw ArgumentError('AgentExecution not found: ${execution.id}');
    }
    _executions[execution.id] = execution;
  }

  @override
  Future<void> delete(String id) async {
    _executions.remove(id);
  }

  Future<void> dispose() async {
    disposed = true;
  }

  int _compareNullableDateTimes(DateTime? left, DateTime? right) {
    if (left == null && right == null) {
      return 0;
    }
    if (left == null) {
      return -1;
    }
    if (right == null) {
      return 1;
    }
    return left.compareTo(right);
  }
}
