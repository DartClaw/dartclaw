import 'package:dartclaw_core/dartclaw_core.dart';

import 'task_service.dart';

/// Fires task lifecycle events: [TaskStatusChangedEvent] always, plus
/// [TaskReviewReadyEvent] when the new status is [TaskStatus.review].
///
/// Shared across [TaskExecutor], [TaskReviewService], and task API routes
/// to avoid duplicating the event firing + artifact enumeration logic.
Future<void> fireTaskLifecycleEvents({
  required TaskService tasks,
  required EventBus eventBus,
  required String taskId,
  required TaskStatus oldStatus,
  required TaskStatus newStatus,
  required String trigger,
}) async {
  eventBus.fire(
    TaskStatusChangedEvent(
      taskId: taskId,
      oldStatus: oldStatus,
      newStatus: newStatus,
      trigger: trigger,
      timestamp: DateTime.now(),
    ),
  );

  if (newStatus != TaskStatus.review) return;

  final artifacts = await tasks.listArtifacts(taskId);
  final artifactKinds = artifacts.map((artifact) => artifact.kind.name).toSet().toList()..sort();
  eventBus.fire(
    TaskReviewReadyEvent(
      taskId: taskId,
      artifactCount: artifacts.length,
      artifactKinds: artifactKinds,
      timestamp: DateTime.now(),
    ),
  );
}
