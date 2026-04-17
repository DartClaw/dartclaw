import 'dart:async';
import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart'
    show
        AgentStateChangedEvent,
        ArtifactCreated,
        Compaction,
        EventBus,
        ProjectService,
        ProjectStatusChangedEvent,
        PushBack,
        StatusChanged,
        StructuredOutputFallbackUsed,
        TaskErrorEvent,
        TaskEventCreatedEvent,
        TaskEventKind,
        TaskStatus,
        TaskStatusChangedEvent,
        TokenUpdate,
        ToolCalled,
        WorkflowRunStatus,
        WorkflowRunStatusChangedEvent,
        WorkflowStepCompletedEvent;
import 'package:dartclaw_workflow/dartclaw_workflow.dart' show WorkflowService;
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../task/agent_observer.dart';
import '../task/task_progress_tracker.dart';
import '../task/task_service.dart';
import '../task/tool_call_summary.dart';
import '../sidebar_live_state.dart';
import '../templates/helpers.dart';
import '../templates/task_event_display.dart';

/// Creates a [Router] with the task SSE endpoint.
///
/// `GET /api/tasks/events` streams [TaskStatusChangedEvent],
/// [AgentStateChangedEvent], [ProjectStatusChangedEvent],
/// [TaskProgressSnapshot] (task_progress), [TaskEventCreatedEvent]
/// (task_event), and workflow sidebar updates to connected clients via
/// Server-Sent Events.
///
/// When [workflows] is provided, the SSE stream also includes
/// `activeWorkflows` in the `connected` payload and sends
/// `workflow_sidebar_update` events on workflow state changes.
Router taskSseRoutes(
  TaskService tasks,
  EventBus eventBus, {
  AgentObserver? observer,
  ProjectService? projects,
  TaskProgressTracker? progressTracker,
  WorkflowService? workflows,
}) {
  final router = Router();

  router.get('/api/tasks/sidebar-state', (Request request) async {
    final reviewTasks = await tasks.list(status: TaskStatus.review);
    final payload = <String, dynamic>{
      'reviewCount': reviewTasks.length,
      'activeTasks': (await buildActiveSidebarTasks(tasks)).map(sidebarActiveTaskToJson).toList(),
      if (workflows != null)
        'activeWorkflows': (await buildActiveSidebarWorkflows(
          workflows,
          tasks,
        )).map(sidebarActiveWorkflowToJson).toList(),
    };

    return Response.ok(jsonEncode(payload), headers: {'Content-Type': 'application/json'});
  });

  router.get('/api/tasks/events', (Request request) async {
    final controller = StreamController<List<int>>();

    // Send initial connected message with current review count and agent snapshot.
    final reviewTasks = await tasks.list(status: TaskStatus.review);
    final connectedPayload = <String, dynamic>{
      'type': 'connected',
      'reviewCount': reviewTasks.length,
      'activeTasks': (await buildActiveSidebarTasks(tasks)).map(sidebarActiveTaskToJson).toList(),
      if (workflows != null)
        'activeWorkflows': (await buildActiveSidebarWorkflows(
          workflows,
          tasks,
        )).map(sidebarActiveWorkflowToJson).toList(),
    };
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
    if (projects != null) {
      final projectList = await projects.getAll();
      connectedPayload['projects'] = projectList
          .map((p) => {'id': p.id, 'name': p.name, 'status': p.status.name})
          .toList();
    }
    controller.add(utf8.encode('data: ${jsonEncode(connectedPayload)}\n\n'));

    // Subscribe to task status change events.
    final taskSub = eventBus.on<TaskStatusChangedEvent>().listen((event) async {
      final reviewCount = (await tasks.list(status: TaskStatus.review)).length;
      final activeTasks = (await buildActiveSidebarTasks(tasks)).map(sidebarActiveTaskToJson).toList();
      final payload = <String, dynamic>{
        'type': 'task_status_changed',
        'taskId': event.taskId,
        'oldStatus': event.oldStatus.name,
        'newStatus': event.newStatus.name,
        'trigger': event.trigger,
        'reviewCount': reviewCount,
        'activeTasks': activeTasks,
        if (workflows != null)
          'activeWorkflows': (await buildActiveSidebarWorkflows(
            workflows,
            tasks,
          )).map(sidebarActiveWorkflowToJson).toList(),
      };
      final data = jsonEncode(payload);
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

    // Subscribe to project status change events.
    final projectSub = eventBus.on<ProjectStatusChangedEvent>().listen((event) {
      final data = jsonEncode({
        'type': 'project_status',
        'projectId': event.projectId,
        'oldStatus': event.oldStatus?.name,
        'newStatus': event.newStatus.name,
      });
      if (!controller.isClosed) {
        controller.add(utf8.encode('data: $data\n\n'));
      }
    });

    // Subscribe to task progress updates.
    final progressSub = progressTracker?.onProgress.listen((snapshot) {
      final data = jsonEncode(snapshot.toJson());
      if (!controller.isClosed) {
        controller.add(utf8.encode('data: $data\n\n'));
      }
    });

    // Forward raw task events for live timeline and dashboard consumers (S09, S11).
    // No throttle — events are low-frequency relative to task_progress.
    final taskEventSub = eventBus.on<TaskEventCreatedEvent>().listen((event) {
      TaskEventKind? kind;
      try {
        kind = TaskEventKind.fromName(event.kind);
      } catch (_) {
        // Unknown kind — forward the event without compact preview fields.
      }
      final data = jsonEncode({
        'type': 'task_event',
        'taskId': event.taskId,
        'eventId': event.eventId,
        'kind': event.kind,
        'details': event.details,
        'timestamp': event.timestamp.toIso8601String(),
        // Dashboard compact preview fields (S11):
        if (kind != null) 'iconClass': compactEventIconClass(kind),
        if (kind != null) 'iconChar': compactEventIconChar(kind),
        if (kind != null) 'text': _compactEventText(kind, event.details),
      });
      if (!controller.isClosed) {
        controller.add(utf8.encode('data: $data\n\n'));
      }
    });

    // Subscribe to workflow run status changes for sidebar updates.
    StreamSubscription<WorkflowRunStatusChangedEvent>? workflowStatusSub;
    if (workflows != null) {
      workflowStatusSub = eventBus.on<WorkflowRunStatusChangedEvent>().listen((event) async {
        final activeWorkflows = (await buildActiveSidebarWorkflows(
          workflows,
          tasks,
        )).map(sidebarActiveWorkflowToJson).toList();
        final isTerminal =
            event.newStatus == WorkflowRunStatus.completed ||
            event.newStatus == WorkflowRunStatus.failed ||
            event.newStatus == WorkflowRunStatus.cancelled;
        final data = jsonEncode({
          'type': 'workflow_sidebar_update',
          'activeWorkflows': activeWorkflows,
          'notification': isTerminal,
          'runId': event.runId,
          'newStatus': event.newStatus.name,
        });
        if (!controller.isClosed) {
          controller.add(utf8.encode('data: $data\n\n'));
        }
      });
    }

    // Subscribe to workflow step completions for sidebar step progress updates.
    StreamSubscription<WorkflowStepCompletedEvent>? workflowStepSub;
    if (workflows != null) {
      workflowStepSub = eventBus.on<WorkflowStepCompletedEvent>().listen((event) async {
        final activeWorkflows = (await buildActiveSidebarWorkflows(
          workflows,
          tasks,
        )).map(sidebarActiveWorkflowToJson).toList();
        final data = jsonEncode({
          'type': 'workflow_sidebar_update',
          'activeWorkflows': activeWorkflows,
          'notification': false,
        });
        if (!controller.isClosed) {
          controller.add(utf8.encode('data: $data\n\n'));
        }
      });
    }

    // Clean up on client disconnect.
    controller.onCancel = () {
      taskSub.cancel();
      agentSub.cancel();
      projectSub.cancel();
      progressSub?.cancel();
      taskEventSub.cancel();
      workflowStatusSub?.cancel();
      workflowStepSub?.cancel();
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

// === S11: Dashboard compact event view-model helpers ===

/// Brief display text for compact dashboard event preview.
String _compactEventText(TaskEventKind kind, Map<String, dynamic> details) {
  return switch (kind) {
    StatusChanged() => truncate('Status \u2192 ${details['newStatus']?.toString() ?? 'unknown'}', 80),
    ToolCalled() => formatToolEventText(
      details['name']?.toString() ?? '(tool)',
      context: details['context']?.toString(),
      maxLength: 80,
    ),
    ArtifactCreated() => truncate(details['name']?.toString() ?? '(artifact)', 80),
    StructuredOutputFallbackUsed() => truncate(
      'Structured fallback: ${details['outputKey']?.toString() ?? '(output)'}',
      80,
    ),
    PushBack() => truncate(details['comment']?.toString() ?? 'Push-back', 80),
    TokenUpdate() => () {
      final input = (details['inputTokens'] as num?)?.toInt() ?? 0;
      final output = (details['outputTokens'] as num?)?.toInt() ?? 0;
      final total = input + output;
      if (total >= 1000) return '${(total / 1000).toStringAsFixed(1)}K tokens';
      return '$total tokens';
    }(),
    TaskErrorEvent() => truncate(details['message']?.toString() ?? 'Error', 80),
    Compaction() => truncate('Compaction (trigger: ${details['trigger'] ?? 'auto'})', 80),
  };
}
