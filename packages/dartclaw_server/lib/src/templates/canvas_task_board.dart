import 'package:dartclaw_core/dartclaw_core.dart';

import 'helpers.dart';
import 'loader.dart';

/// Renders the workshop task-board fragment for the canvas view.
String canvasTaskBoardFragment(List<Task> tasks) {
  final queuedTasks = _sortByNewest(
    tasks.where((task) => const {TaskStatus.draft, TaskStatus.queued, TaskStatus.interrupted}.contains(task.status)),
  );
  final runningTasks = _sortByNewest(tasks.where((task) => task.status == TaskStatus.running));
  final reviewTasks = _sortByNewest(tasks.where((task) => task.status == TaskStatus.review));
  final doneTasks = _sortByNewest(
    tasks.where(
      (task) => const {
        TaskStatus.accepted,
        TaskStatus.rejected,
        TaskStatus.cancelled,
        TaskStatus.failed,
      }.contains(task.status),
    ),
  );

  final columns = [
    _columnData(id: 'queued', title: 'Queued', tasks: queuedTasks, showDoneIcon: false),
    _columnData(id: 'running', title: 'Running', tasks: runningTasks, showDoneIcon: false, isRunningColumn: true),
    _columnData(id: 'review', title: 'Review', tasks: reviewTasks, showDoneIcon: false),
    _columnData(id: 'done', title: 'Done', tasks: doneTasks, showDoneIcon: true),
  ];

  return templateLoader.trellis.renderFragment(
    templateLoader.source('canvas_task_board'),
    fragment: 'taskBoard',
    context: {'columns': columns},
  );
}

Map<String, dynamic> _columnData({
  required String id,
  required String title,
  required List<Task> tasks,
  required bool showDoneIcon,
  bool isRunningColumn = false,
}) {
  final cards = tasks
      .map(
        (task) => {
          'title': truncate(task.title, 40),
          'createdBy': _creatorName(task.createdBy),
          'timeInState': formatRelativeTime(_stateTimestamp(task)),
          'isRunning': isRunningColumn,
          'doneIcon': showDoneIcon ? _doneStatusIcon(task.status) : null,
        },
      )
      .toList(growable: false);

  return {'id': id, 'title': title, 'count': cards.length, 'hasTasks': cards.isNotEmpty, 'tasks': cards};
}

List<Task> _sortByNewest(Iterable<Task> tasks) {
  final list = tasks.toList();
  list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
  return list;
}

String _creatorName(String? raw) {
  final trimmed = raw?.trim();
  if (trimmed == null || trimmed.isEmpty) return 'System';
  return trimmed;
}

DateTime _stateTimestamp(Task task) {
  return switch (task.status) {
    TaskStatus.draft || TaskStatus.queued || TaskStatus.interrupted => task.createdAt,
    TaskStatus.running || TaskStatus.review => task.startedAt ?? task.createdAt,
    TaskStatus.accepted ||
    TaskStatus.rejected ||
    TaskStatus.cancelled ||
    TaskStatus.failed => task.completedAt ?? task.startedAt ?? task.createdAt,
  };
}

String? _doneStatusIcon(TaskStatus status) {
  return switch (status) {
    TaskStatus.accepted => 'OK',
    TaskStatus.rejected => 'NO',
    TaskStatus.cancelled => 'X',
    TaskStatus.failed => '!',
    _ => null,
  };
}
