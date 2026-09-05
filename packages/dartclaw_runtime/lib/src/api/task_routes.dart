import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:logging/logging.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../task/merge_executor.dart';
import '../task/task_action_service.dart';
import '../task/task_creation_service.dart';
import '../task/task_file_guard.dart';
import '../task/task_review_service.dart';
import '../task/task_service.dart';
import '../task/worktree_manager.dart';
import 'api_helpers.dart';

final _log = Logger('TaskRoutes');

/// Creates a [Router] exposing task CRUD and lifecycle API endpoints.
Router taskRoutes(
  TaskService tasks, {
  TurnManager? turns,
  TaskReviewService? reviewService,
  WorktreeManager? worktreeManager,
  TaskFileGuard? taskFileGuard,
  MergeExecutor? mergeExecutor,
  ProjectService? projectService,
  String? dataDir,
  ThreadBindingStore? threadBindingStore,
  String mergeStrategy = 'squash',
  String baseRef = 'main',
  TaskCreationService? creationService,
  TaskActionService? actionService,
}) {
  final router = Router();
  final effectiveReviewService =
      reviewService ??
      TaskReviewService(
        tasks: tasks,
        worktreeManager: worktreeManager,
        taskFileGuard: taskFileGuard,
        mergeExecutor: mergeExecutor,
        dataDir: dataDir,
        mergeStrategy: mergeStrategy,
        baseRef: baseRef,
      );
  final effectiveCreationService = creationService ?? TaskCreationService(tasks: tasks, projects: projectService);
  final effectiveActionService =
      actionService ??
      TaskActionService(
        tasks: tasks,
        reviewService: effectiveReviewService,
        turns: turns,
        worktreeManager: worktreeManager,
        taskFileGuard: taskFileGuard,
        projectService: projectService,
      );

  router.post('/api/tasks', (Request request) async {
    try {
      final body = await readJsonObject(request);
      if (body.error != null) return body.error!;

      final result = await effectiveCreationService.create(body.value!);
      return switch (result) {
        TaskCreated(:final task) => jsonResponse(201, task.toJson()),
        TaskCreationRefused(:final message, :final field, :final key) => errorResponse(400, 'INVALID_INPUT', message, {
          'field': ?field,
          'key': ?key,
        }),
      };
    } catch (e, st) {
      _log.warning('Failed to create task: $e', e, st);
      return errorResponse(500, 'INTERNAL_ERROR', 'Failed to create task');
    }
  });

  router.get('/api/tasks', (Request request) async {
    try {
      final status = TaskStatus.values.asNameMap()[request.url.queryParameters['status']];
      final list = await tasks.list(status: status);
      final payload = await Future.wait(
        list.map((task) async => task.toJson()..['artifactDiskBytes'] = await _artifactDiskBytes(dataDir, task.id)),
      );
      return jsonResponse(200, payload);
    } catch (e, st) {
      _log.warning('Failed to list tasks: $e', e, st);
      return errorResponse(500, 'INTERNAL_ERROR', 'Failed to list tasks');
    }
  });

  router.get('/api/tasks/<id>', (Request request, String id) async {
    try {
      final task = await tasks.get(id);
      if (task == null) return _taskNotFound();
      final artifacts = await tasks.listArtifacts(id);
      final payload = task.toJson()
        ..['artifactDiskBytes'] = await _artifactDiskBytes(dataDir, id)
        ..['artifacts'] = await Future.wait(
          artifacts.map((artifact) => _serializeArtifact(artifact, includeContent: true)),
        );
      return jsonResponse(200, payload);
    } catch (e, st) {
      _log.warning('Failed to get task $id: $e', e, st);
      return errorResponse(500, 'INTERNAL_ERROR', 'Failed to get task');
    }
  });

  router.post('/api/tasks/<id>/start', (Request request, String id) async {
    return _taskActionResponse(await effectiveActionService.start(id));
  });

  router.post('/api/tasks/<id>/checkout', (Request request, String id) async {
    return _taskActionResponse(await effectiveActionService.checkout(id));
  });

  router.post('/api/tasks/<id>/cancel', (Request request, String id) async {
    return _taskActionResponse(await effectiveActionService.cancel(id));
  });

  router.post('/api/tasks/<id>/review', (Request request, String id) async {
    try {
      final body = await readJsonObject(request);
      if (body.error != null) return body.error!;

      return _taskActionResponse(await effectiveActionService.review(id, body.value!));
    } catch (e, st) {
      _log.warning('Failed to review task $id: $e', e, st);
      return errorResponse(500, 'INTERNAL_ERROR', 'Failed to review task');
    }
  });

  router.delete('/api/tasks/<id>', (Request request, String id) async {
    try {
      final task = await tasks.get(id);
      if (task == null) return _taskNotFound();
      if (!task.status.terminal) {
        return errorResponse(409, 'INVALID_STATE', 'Cannot delete non-terminal task', {
          'currentStatus': task.status.name,
        });
      }

      await tasks.delete(id);
      return Response(204);
    } catch (e, st) {
      _log.warning('Failed to delete task $id: $e', e, st);
      return errorResponse(500, 'INTERNAL_ERROR', 'Failed to delete task');
    }
  });

  router.get('/api/tasks/<id>/artifacts', (Request request, String id) async {
    try {
      final task = await tasks.get(id);
      if (task == null) return _taskNotFound();
      final artifacts = await tasks.listArtifacts(id);
      return jsonResponse(200, artifacts.map((artifact) => artifact.toJson()).toList());
    } catch (e, st) {
      _log.warning('Failed to list artifacts for task $id: $e', e, st);
      return errorResponse(500, 'INTERNAL_ERROR', 'Failed to list task artifacts');
    }
  });

  router.get('/api/tasks/<id>/artifacts/<artifactId>', (Request request, String id, String artifactId) async {
    try {
      final artifact = await tasks.getArtifact(artifactId);
      if (artifact == null || artifact.taskId != id) {
        return errorResponse(404, 'ARTIFACT_NOT_FOUND', 'Artifact not found');
      }
      return jsonResponse(200, await _serializeArtifact(artifact, includeContent: true));
    } catch (e, st) {
      _log.warning('Failed to get artifact $artifactId for task $id: $e', e, st);
      return errorResponse(500, 'INTERNAL_ERROR', 'Failed to get task artifact');
    }
  });

  router.get('/api/tasks/<id>/bindings', (Request request, String id) async {
    try {
      final task = await tasks.get(id);
      if (task == null) return _taskNotFound();
      final store = threadBindingStore;
      if (store == null) return jsonResponse(200, const []);
      final bindings = store.lookupByTask(id).map((binding) => binding.toJson()).toList(growable: false);
      return jsonResponse(200, bindings);
    } catch (e, st) {
      _log.warning('Failed to list bindings for task $id: $e', e, st);
      return errorResponse(500, 'INTERNAL_ERROR', 'Failed to list task bindings');
    }
  });

  router.post('/api/tasks/<id>/bindings', (Request request, String id) async {
    try {
      final task = await tasks.get(id);
      if (task == null) return _taskNotFound();
      final store = threadBindingStore;
      if (store == null) {
        return errorResponse(409, 'THREAD_BINDING_DISABLED', 'Thread binding is not enabled');
      }

      final body = await readJsonObject(request);
      if (body.error != null) return body.error!;

      final channelType = trimmedStringOrNull(body.value!['channelType']);
      final threadId = trimmedStringOrNull(body.value!['threadId']);
      if (channelType == null || channelType.isEmpty) {
        return errorResponse(400, 'INVALID_INPUT', 'channelType is required', {'field': 'channelType'});
      }
      if (threadId == null || threadId.isEmpty) {
        return errorResponse(400, 'INVALID_INPUT', 'threadId is required', {'field': 'threadId'});
      }
      if (!supportsThreadBinding(channelType)) {
        return errorResponse(400, 'INVALID_INPUT', 'Channel $channelType carries no thread identity to bind', {
          'field': 'channelType',
        });
      }

      final existing = store.lookupByThread(channelType, threadId);
      if (existing != null) {
        return errorResponse(
          409,
          'CONFLICT',
          existing.taskId == id
              ? 'Binding already exists for this thread'
              : 'Thread already bound to task ${existing.taskId}',
        );
      }

      final now = DateTime.now();
      final binding = ThreadBinding(
        channelType: channelType,
        threadId: threadId,
        taskId: id,
        sessionKey: task.sessionId ?? SessionKey.taskSession(taskId: id),
        createdAt: now,
        lastActivity: now,
      );
      await store.create(binding);
      return jsonResponse(201, binding.toJson());
    } catch (e, st) {
      _log.warning('Failed to create binding for task $id: $e', e, st);
      return errorResponse(500, 'INTERNAL_ERROR', 'Failed to create task binding');
    }
  });

  router.delete('/api/tasks/<id>/bindings/<channelType>/<threadId|.*>', (
    Request request,
    String id,
    String channelType,
    String threadId,
  ) async {
    try {
      final store = threadBindingStore;
      if (store == null) {
        return errorResponse(409, 'THREAD_BINDING_DISABLED', 'Thread binding is not enabled');
      }
      final existing = store.lookupByThread(channelType, threadId);
      if (existing == null || existing.taskId != id) {
        return errorResponse(404, 'NOT_FOUND', 'Binding not found');
      }
      await store.delete(channelType, threadId);
      return jsonResponse(200, {'deleted': true});
    } catch (e, st) {
      _log.warning('Failed to delete binding for task $id: $e', e, st);
      return errorResponse(500, 'INTERNAL_ERROR', 'Failed to delete task binding');
    }
  });

  return router;
}

Response _taskActionResponse(TaskActionResult result) => switch (result) {
  TaskActionSuccess(:final task) => jsonResponse(200, task.toJson()),
  TaskActionRefused(:final statusCode, :final code, :final message, :final details) => errorResponse(
    statusCode,
    code,
    message,
    details,
  ),
};

Response _taskNotFound() => errorResponse(404, 'TASK_NOT_FOUND', 'Task not found');

Future<Map<String, dynamic>> _serializeArtifact(TaskArtifact artifact, {required bool includeContent}) async {
  final map = artifact.toJson();
  if (!includeContent) return map;

  final file = File(artifact.path);
  if (!await file.exists()) return map;

  final size = await file.length();
  if (size > 256 * 1024) {
    map['contentUnavailableReason'] = 'Artifact too large to inline';
    map['sizeBytes'] = size;
    return map;
  }

  final content = await file.readAsString();
  map['content'] = content;
  if (artifact.kind == ArtifactKind.diff) {
    try {
      map['diff'] = jsonDecode(content);
    } on FormatException {
      map['diffParseError'] = true;
    }
  }
  return map;
}

Future<int> _artifactDiskBytes(String? dataDir, String taskId) async {
  if (dataDir == null) return 0;

  final artifactsDir = Directory('$dataDir/tasks/$taskId/artifacts');
  if (!await artifactsDir.exists()) return 0;

  var total = 0;
  await for (final entity in artifactsDir.list(recursive: true, followLinks: false)) {
    if (entity is File) {
      total += await entity.length();
    }
  }
  return total;
}
