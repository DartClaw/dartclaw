import 'dart:async';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:logging/logging.dart';

import 'task_service.dart';

/// Fails running tasks whose execution profile crashed.
class ContainerTaskFailureSubscriber {
  static final _log = Logger('ContainerTaskFailureSubscriber');

  final TaskService _tasks;
  StreamSubscription<ContainerCrashedEvent>? _subscription;

  ContainerTaskFailureSubscriber({required TaskService tasks}) : _tasks = tasks;

  void subscribe(EventBus eventBus) {
    _subscription ??= eventBus.on<ContainerCrashedEvent>().listen((event) {
      unawaited(_failAffectedTasks(event));
    });
  }

  Future<void> dispose() async {
    await _subscription?.cancel();
    _subscription = null;
  }

  Future<void> _failAffectedTasks(ContainerCrashedEvent event) async {
    final runningTasks = await _tasks.list(status: TaskStatus.running);
    for (final task in runningTasks) {
      if (resolveProfile(task.type) != event.profileId) continue;
      try {
        // TaskService.transition() fires TaskStatusChangedEvent automatically.
        await _tasks.transition(
          task.id,
          TaskStatus.failed,
          configJson: _withErrorSummary(task.configJson, event.error),
          trigger: 'system',
        );
      } on StateError catch (error, stackTrace) {
        _log.warning('Failed to transition task ${task.id} after container crash', error, stackTrace);
      }
    }
  }

  Map<String, dynamic> _withErrorSummary(Map<String, dynamic> configJson, String error) =>
      Map<String, dynamic>.from(configJson)..['errorSummary'] = _sanitizeErrorSummary(error);

  String _sanitizeErrorSummary(String message) {
    final firstLine = message
        .split('\n')
        .map((line) => line.trim())
        .firstWhere((line) => line.isNotEmpty, orElse: () => 'Execution profile crashed');
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
    if (normalized.isEmpty) {
      normalized = 'Execution profile crashed';
    }
    if (normalized.length <= 200) {
      return normalized;
    }
    return '${normalized.substring(0, 197).trimRight()}...';
  }
}
