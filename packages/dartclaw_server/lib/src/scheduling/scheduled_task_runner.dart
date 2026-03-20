import 'dart:math';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:logging/logging.dart';

import 'cron_parser.dart';
import 'scheduled_job.dart';
import '../task/task_service.dart';

final _log = Logger('ScheduledTaskRunner');

/// Bridges [ScheduledTaskDefinition] entries into [ScheduledJob] instances
/// for registration with [ScheduleService].
///
/// Each enabled definition becomes a callback-based [ScheduledJob] that:
/// 1. Checks for existing non-terminal tasks with the same scheduleId (dedup)
/// 2. Creates a new task via [TaskService] if no open task exists
class ScheduledTaskRunner {
  final TaskService _taskService;
  final List<ScheduledTaskDefinition> _definitions;
  final EventBus? _eventBus;

  ScheduledTaskRunner({
    required TaskService taskService,
    required List<ScheduledTaskDefinition> definitions,
    EventBus? eventBus,
  }) : _taskService = taskService,
       _definitions = definitions,
       _eventBus = eventBus;

  /// Converts each enabled [ScheduledTaskDefinition] into a [ScheduledJob].
  List<ScheduledJob> buildJobs() {
    final jobs = <ScheduledJob>[];
    for (final def in _definitions) {
      if (!def.enabled) continue;

      CronExpression cronExpr;
      try {
        cronExpr = CronExpression.parse(def.cronExpression);
      } on FormatException catch (e) {
        _log.warning('Scheduled task "${def.id}" has invalid cron expression: $e — skipping');
        continue;
      }

      jobs.add(
        ScheduledJob(
          id: 'auto-task-${def.id}',
          scheduleType: ScheduleType.cron,
          cronExpression: cronExpr,
          onExecute: () => _executeScheduledTask(def),
        ),
      );
    }
    return jobs;
  }

  Future<String> _executeScheduledTask(ScheduledTaskDefinition def) async {
    // Dedup check: find non-terminal tasks with matching scheduleId
    final allTasks = await _taskService.list();
    final openTasks = allTasks.where((t) => !t.status.terminal && t.configJson['scheduleId'] == def.id);

    if (openTasks.isNotEmpty) {
      final openTask = openTasks.first;
      _log.info(
        'Skipping scheduled task "${def.id}" — '
        'open task ${openTask.id} exists (status: ${openTask.status.name})',
      );
      return 'Skipped: open task ${openTask.id} exists';
    }

    // Generate a unique task ID
    final taskId = _generateTaskId(def.id);

    final task = await _taskService.create(
      id: taskId,
      title: def.title,
      description: def.description,
      type: def.type,
      acceptanceCriteria: def.acceptanceCriteria,
      autoStart: def.autoStart,
      configJson: {
        'scheduleId': def.id,
        if (def.model != null) 'model': def.model,
        if (def.effort != null) 'effort': def.effort,
        if (def.tokenBudget != null) 'tokenBudget': def.tokenBudget,
      },
    );
    _fireTaskCreatedEvent(task, trigger: 'system');

    _log.info('Created scheduled task "${task.id}" from schedule "${def.id}"');
    return 'Created task ${task.id} from schedule "${def.id}"';
  }

  void _fireTaskCreatedEvent(Task task, {required String trigger}) {
    final eventBus = _eventBus;
    if (eventBus == null) return;
    eventBus.fire(
      TaskStatusChangedEvent(
        taskId: task.id,
        oldStatus: TaskStatus.draft,
        newStatus: task.status,
        trigger: trigger,
        timestamp: DateTime.now(),
      ),
    );
  }

  static String _generateTaskId(String scheduleId) {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final random = Random().nextInt(0xFFFF).toRadixString(16).padLeft(4, '0');
    return 'sched-$scheduleId-$timestamp-$random';
  }
}
