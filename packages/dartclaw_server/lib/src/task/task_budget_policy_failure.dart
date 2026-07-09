part of 'task_budget_policy.dart';

/// Handles failure transitions and retry loop prevention for task execution.
final class TaskFailureHandler {
  TaskFailureHandler({required TaskService tasks, TaskEventRecorder? eventRecorder, Logger? log})
    : _tasks = tasks,
      _eventRecorder = eventRecorder,
      _log = log ?? Logger('TaskFailureHandler');

  final TaskService _tasks;
  final TaskEventRecorder? _eventRecorder;
  final Logger _log;

  /// Whether a terminal task may still be overwritten to failed.
  ///
  /// Only a cancelled task, and only when the caller explicitly opts in via
  /// [correctCancelled], is correctable. This keeps the narrow one-shot
  /// dispose-cancel-vs-genuine-failure correction from leaking into generic
  /// cancellation, which must stay cancelled.
  static bool _correctable(TaskStatus status, bool correctCancelled) =>
      correctCancelled && status == TaskStatus.cancelled;

  Future<void> markFailed(
    Task task, {
    String? errorSummary,
    bool recordError = true,
    bool correctCancelled = false,
  }) async {
    if (recordError && errorSummary != null && errorSummary.isNotEmpty) {
      _log.warning('Task ${task.id} failed: $errorSummary');
      _eventRecorder?.recordError(task.id, message: errorSummary);
    }
    try {
      final current = await _tasks.get(task.id);
      if (current == null || (current.status.terminal && !_correctable(current.status, correctCancelled))) return;
      await _tasks.transition(
        task.id,
        TaskStatus.failed,
        configJson: errorSummary == null ? null : _withErrorSummary(current.configJson, errorSummary),
        trigger: 'system',
      );
    } on StateError catch (error, stackTrace) {
      _log.warning('Failed to mark task ${task.id} as failed: $error', error, stackTrace);
    }
  }

  Future<void> markFailedOrRetry(
    Task task, {
    required String errorSummary,
    bool retryable = true,
    bool correctCancelled = false,
  }) async {
    if (errorSummary.isNotEmpty) _eventRecorder?.recordError(task.id, message: errorSummary);
    try {
      final current = await _tasks.get(task.id);
      if (current == null || (current.status.terminal && !_correctable(current.status, correctCancelled))) return;
      if (current.status == TaskStatus.cancelled) {
        await markFailed(task, errorSummary: errorSummary, recordError: false, correctCancelled: true);
        return;
      }
      if (retryable && current.maxRetries > 0 && current.retryCount < current.maxRetries) {
        final lastError = current.configJson['lastError'] as String?;
        if (lastError != null && _extractErrorClass(errorSummary) == _extractErrorClass(lastError)) {
          _log.info(
            'Task ${task.id}: same error class on retry '
            '(${current.retryCount + 1}/${current.maxRetries}), failing permanently',
          );
          await markFailed(task, errorSummary: errorSummary, recordError: false);
          return;
        }
        _log.info('Task ${task.id}: retry ${current.retryCount + 1}/${current.maxRetries}');
        final retryConfigJson = Map<String, dynamic>.from(current.configJson)
          ..['lastError'] = sanitizeErrorSummary(errorSummary);
        await _tasks.updateFields(
          task.id,
          retryCount: current.retryCount + 1,
          sessionId: null,
          configJson: retryConfigJson,
        );
        // Use 'retry-in-progress' so listeners can distinguish this transient
        // failed state from a permanent failure (both otherwise use 'system').
        await _tasks.transition(task.id, TaskStatus.failed, trigger: 'retry-in-progress');
        await _tasks.transition(task.id, TaskStatus.queued, trigger: 'retry');
        return;
      }
      await markFailed(task, errorSummary: errorSummary, recordError: false);
    } on StateError catch (error, stackTrace) {
      _log.warning('Failed to process retry/failure for task ${task.id}: $error', error, stackTrace);
    }
  }

  String sanitizeErrorSummary(String message) {
    final firstLine = message
        .split('\n')
        .map((line) => line.trim())
        .firstWhere((line) => line.isNotEmpty, orElse: () => 'Task execution failed');
    var normalized = firstLine;
    for (final prefix in const [
      'Exception: ',
      'StateError: ',
      'Bad state: ',
      'ArgumentError: ',
      'Invalid argument(s): ',
    ]) {
      if (normalized.startsWith(prefix)) {
        normalized = normalized.substring(prefix.length).trim();
        break;
      }
    }
    normalized = normalized.replaceFirst(RegExp(r'[.]+$'), '').trim();
    if (normalized.isEmpty) normalized = 'Task execution failed';
    if (normalized.length <= 200) return normalized;
    return '${normalized.substring(0, 197).trimRight()}...';
  }

  String _extractErrorClass(String errorSummary) {
    var normalized = errorSummary.toLowerCase().trim();
    for (final prefix in const [
      'exception: ',
      'stateerror: ',
      'bad state: ',
      'argumenterror: ',
      'invalid argument(s): ',
    ]) {
      if (normalized.startsWith(prefix)) {
        normalized = normalized.substring(prefix.length).trim();
        break;
      }
    }
    final classEnd = normalized.indexOf(RegExp(r'[:(\[]'));
    if (classEnd > 0) normalized = normalized.substring(0, classEnd).trim();
    if (normalized.length > 80) normalized = normalized.substring(0, 80);
    return normalized;
  }

  Map<String, dynamic> _withErrorSummary(Map<String, dynamic> configJson, String errorSummary) =>
      Map<String, dynamic>.from(configJson)..['errorSummary'] = sanitizeErrorSummary(errorSummary);
}
