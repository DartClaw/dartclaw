import 'dart:async';

import 'agent_execution.dart';

/// Storage-agnostic contract for [AgentExecution] persistence.
abstract class AgentExecutionRepository {
  /// Inserts a new execution.
  Future<void> create(AgentExecution execution);

  /// Returns the execution with [id], or null when missing.
  Future<AgentExecution?> get(String id);

  /// Lists executions ordered by newest start time first.
  Future<List<AgentExecution>> list({String? sessionId, String? provider});

  /// Persists an update to an existing execution.
  Future<void> update(AgentExecution execution, {String trigger = 'system', DateTime? timestamp});

  /// Deletes an execution by id.
  Future<void> delete(String id);
}
