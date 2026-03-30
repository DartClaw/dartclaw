import '../task/task.dart';
import '../task/task_status.dart';
import '../task/task_type.dart';

/// Callback for creating a task from a channel-originated trigger.
///
/// The [trigger] parameter identifies the originating subsystem (e.g.
/// `'channel'`, `'slash_command'`, `'system'`). Defaults to `'system'` when
/// not supplied.
typedef TaskCreator =
    Future<Task> Function({
      required String id,
      required String title,
      required String description,
      required TaskType type,
      bool autoStart,
      String? goalId,
      String? acceptanceCriteria,
      String? createdBy,
      String? projectId,
      Map<String, dynamic> configJson,
      DateTime? now,
      String trigger,
    });

/// Callback for listing tasks for channel review resolution.
typedef TaskLister = Future<List<Task>> Function({TaskStatus? status, TaskType? type});
