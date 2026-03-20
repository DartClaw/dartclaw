import '../task/task.dart';
import '../task/task_status.dart';
import '../task/task_type.dart';

/// Callback for creating a task from a channel-originated trigger.
typedef TaskCreator =
    Future<Task> Function({
      required String id,
      required String title,
      required String description,
      required TaskType type,
      bool autoStart,
      String? goalId,
      String? acceptanceCriteria,
      Map<String, dynamic> configJson,
      DateTime? now,
    });

/// Callback for listing tasks for channel review resolution.
typedef TaskLister = Future<List<Task>> Function({TaskStatus? status, TaskType? type});
