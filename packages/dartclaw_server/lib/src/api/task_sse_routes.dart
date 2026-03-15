import 'dart:async';
import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../task/agent_observer.dart';

/// Creates a [Router] with the task SSE endpoint.
///
/// `GET /api/tasks/events` streams [TaskStatusChangedEvent] and
/// [AgentStateChangedEvent] updates to connected clients via Server-Sent Events.
Router taskSseRoutes(TaskService tasks, EventBus eventBus, {AgentObserver? observer}) {
  final router = Router();

  router.get('/api/tasks/events', (Request request) async {
    final controller = StreamController<List<int>>();

    // Send initial connected message with current review count and agent snapshot.
    final reviewTasks = await tasks.list(status: TaskStatus.review);
    final connectedPayload = <String, dynamic>{'type': 'connected', 'reviewCount': reviewTasks.length};
    if (observer != null) {
      final pool = observer.poolStatus;
      connectedPayload['agents'] = {
        'runners': observer.metrics.map((m) => m.toJson()).toList(),
        'pool': {
          'size': pool.size,
          'activeCount': pool.activeCount,
          'availableCount': pool.availableCount,
          'maxConcurrentTasks': pool.maxConcurrentTasks,
        },
      };
    }
    controller.add(utf8.encode('data: ${jsonEncode(connectedPayload)}\n\n'));

    // Subscribe to task status change events.
    final taskSub = eventBus.on<TaskStatusChangedEvent>().listen((event) async {
      final reviewCount = (await tasks.list(status: TaskStatus.review)).length;
      final data = jsonEncode({
        'type': 'task_status_changed',
        'taskId': event.taskId,
        'oldStatus': event.oldStatus.name,
        'newStatus': event.newStatus.name,
        'trigger': event.trigger,
        'reviewCount': reviewCount,
      });
      if (!controller.isClosed) {
        controller.add(utf8.encode('data: $data\n\n'));
      }
    });

    // Subscribe to agent state change events.
    final agentSub = eventBus.on<AgentStateChangedEvent>().listen((event) {
      final data = jsonEncode({
        'type': 'agent_state',
        'runnerId': event.runnerId,
        'state': event.state,
        'currentTaskId': event.currentTaskId,
      });
      if (!controller.isClosed) {
        controller.add(utf8.encode('data: $data\n\n'));
      }
    });

    // Clean up on client disconnect.
    controller.onCancel = () {
      taskSub.cancel();
      agentSub.cancel();
    };

    return Response.ok(
      controller.stream,
      headers: {
        'Content-Type': 'text/event-stream',
        'Cache-Control': 'no-cache',
        'Connection': 'keep-alive',
        'X-Accel-Buffering': 'no',
      },
    );
  });

  return router;
}
