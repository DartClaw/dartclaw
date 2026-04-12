import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:logging/logging.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:uuid/uuid.dart';

import '../task/merge_executor.dart';
import '../task/task_file_guard.dart';
import '../task/task_project_ref.dart';
import '../task/task_review_service.dart';
import '../task/task_service.dart';
import '../task/worktree_manager.dart';
import '../turn_manager.dart';
import 'api_helpers.dart';

final _log = Logger('TaskRoutes');

/// Creates a [Router] exposing task CRUD and lifecycle API endpoints.
Router taskRoutes(
  TaskService tasks, {
  // eventBus is accepted for API compatibility but events are now fired by TaskService.
  @Deprecated('Events are now centralized in TaskService. Pass eventBus to TaskService instead.') EventBus? eventBus,
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

  router.post('/api/tasks', (Request request) async {
    try {
      final body = await readJsonObject(request);
      if (body.error != null) return body.error!;

      final titleFieldError = _validateStringFieldType(body.value!, 'title');
      if (titleFieldError != null) return titleFieldError;
      final descriptionFieldError = _validateStringFieldType(body.value!, 'description');
      if (descriptionFieldError != null) return descriptionFieldError;
      final typeFieldError = _validateStringFieldType(body.value!, 'type');
      if (typeFieldError != null) return typeFieldError;
      final goalIdFieldError = _validateStringFieldType(body.value!, 'goalId');
      if (goalIdFieldError != null) return goalIdFieldError;
      final acceptanceCriteriaFieldError = _validateStringFieldType(body.value!, 'acceptanceCriteria');
      if (acceptanceCriteriaFieldError != null) return acceptanceCriteriaFieldError;
      final providerFieldError = _validateStringFieldType(body.value!, 'provider');
      if (providerFieldError != null) return providerFieldError;
      final projectIdFieldError = _validateStringFieldType(body.value!, 'projectId');
      if (projectIdFieldError != null) return projectIdFieldError;

      final title = trimmedStringOrNull(body.value!['title']);
      final description = trimmedStringOrNull(body.value!['description']);
      final typeName = _stringOrNull(body.value!['type']);
      final type = typeName == null ? null : TaskType.values.asNameMap()[typeName];
      final autoStart = body.value!['autoStart'] == true;
      final goalId = _stringOrNull(body.value!['goalId']);
      final acceptanceCriteria = _stringOrNull(body.value!['acceptanceCriteria']);
      final provider = trimmedStringOrNull(body.value!['provider']);
      final projectId = trimmedStringOrNull(body.value!['projectId']);

      if (projectId != null && projectService != null) {
        final project = await projectService.get(projectId);
        if (project == null) {
          return errorResponse(400, 'INVALID_INPUT', 'projectId must reference an existing project', {
            'field': 'projectId',
          });
        }
      }

      if (title == null || title.isEmpty) {
        return errorResponse(400, 'INVALID_INPUT', 'title must not be empty', {'field': 'title'});
      }
      if (description == null || description.isEmpty) {
        return errorResponse(400, 'INVALID_INPUT', 'description must not be empty', {'field': 'description'});
      }
      if (type == null) {
        return errorResponse(400, 'INVALID_INPUT', 'type must be a valid task type', {'field': 'type'});
      }
      if (body.value!.containsKey('autoStart') && body.value!['autoStart'] is! bool) {
        return errorResponse(400, 'INVALID_INPUT', 'autoStart must be a boolean', {'field': 'autoStart'});
      }
      if (body.value!.containsKey('configJson') &&
          body.value!['configJson'] != null &&
          body.value!['configJson'] is! Map) {
        return errorResponse(400, 'INVALID_INPUT', 'configJson must be a JSON object', {'field': 'configJson'});
      }
      final configJson = _jsonMapOrEmpty(body.value!['configJson']);
      final internalConfigKey = configJson.keys.cast<String?>().firstWhere(
        (key) => key != null && key.startsWith('_'),
        orElse: () => null,
      );
      if (internalConfigKey != null) {
        return errorResponse(
          400,
          'INVALID_INPUT',
          'configJson keys starting with "_" are reserved for internal system use',
          {'field': 'configJson', 'key': internalConfigKey},
        );
      }

      final createdByRaw = _stringOrNull(body.value!['createdBy']);
      final createdBy = (createdByRaw != null && createdByRaw.trim().isNotEmpty) ? createdByRaw.trim() : 'operator';
      final task = await tasks.create(
        id: const Uuid().v4(),
        title: title,
        description: description,
        type: type,
        autoStart: autoStart,
        goalId: goalId,
        acceptanceCriteria: acceptanceCriteria,
        createdBy: createdBy,
        provider: provider,
        projectId: projectId,
        configJson: configJson,
        trigger: 'user',
      );

      return jsonResponse(201, task.toJson());
    } catch (e, st) {
      _log.warning('Failed to create task: $e', e, st);
      return errorResponse(500, 'INTERNAL_ERROR', 'Failed to create task');
    }
  });

  router.get('/api/tasks', (Request request) async {
    try {
      final status = TaskStatus.values.asNameMap()[request.url.queryParameters['status']];
      final type = TaskType.values.asNameMap()[request.url.queryParameters['type']];
      final list = await tasks.list(status: status, type: type);
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
    return _transitionTask(
      tasks: tasks,
      taskId: id,
      targetStatus: TaskStatus.queued,
      errorCode: 'INVALID_TRANSITION',
      trigger: 'user',
      actionLabel: 'start task',
    );
  });

  router.post('/api/tasks/<id>/checkout', (Request request, String id) async {
    return _transitionTask(
      tasks: tasks,
      taskId: id,
      targetStatus: TaskStatus.running,
      errorCode: 'CHECKOUT_CONFLICT',
      trigger: 'system',
      actionLabel: 'checkout task',
    );
  });

  router.post('/api/tasks/<id>/cancel', (Request request, String id) async {
    final task = await tasks.get(id);
    final response = await _transitionTask(
      tasks: tasks,
      taskId: id,
      targetStatus: TaskStatus.cancelled,
      errorCode: 'INVALID_TRANSITION',
      trigger: 'user',
      actionLabel: 'cancel task',
    );
    // Cleanup worktree on cancel
    if (response.statusCode == 200 && task?.worktreeJson != null) {
      final cleanupProject = await _cleanupProjectForTask(task, projectService);
      await _cleanupWorktree(id, worktreeManager, taskFileGuard, project: cleanupProject);
    }
    if (response.statusCode == 200 && task?.sessionId != null && task?.status == TaskStatus.running) {
      await turns?.cancelTurn(task!.sessionId!);
    }
    return response;
  });

  router.post('/api/tasks/<id>/review', (Request request, String id) async {
    try {
      final body = await readJsonObject(request);
      if (body.error != null) return body.error!;

      final actionFieldError = _validateStringFieldType(body.value!, 'action');
      if (actionFieldError != null) return actionFieldError;
      final commentFieldError = _validateStringFieldType(body.value!, 'comment');
      if (commentFieldError != null) return commentFieldError;

      final action = trimmedStringOrNull(body.value!['action']);
      final comment = trimmedStringOrNull(body.value!['comment']);
      final targetStatus = switch (action) {
        'accept' => TaskStatus.accepted,
        'reject' => TaskStatus.rejected,
        'push_back' => TaskStatus.queued,
        _ => null,
      };
      if (action == null || action.isEmpty) {
        return errorResponse(400, 'INVALID_INPUT', 'action must not be empty', {'field': 'action'});
      }
      if (targetStatus == null) {
        return errorResponse(400, 'INVALID_INPUT', 'action must be one of: accept, reject, push_back', {
          'field': 'action',
        });
      }
      if (targetStatus == TaskStatus.queued && (comment == null || comment.isEmpty)) {
        return errorResponse(400, 'INVALID_INPUT', 'comment must not be empty for push_back', {'field': 'comment'});
      }

      final result = await effectiveReviewService.review(id, action, comment: comment, trigger: 'user');
      return switch (result) {
        ReviewSuccess(:final task) => jsonResponse(200, task.toJson()),
        ReviewMergeConflict(:final conflictingFiles, :final details) => errorResponse(
          409,
          'MERGE_CONFLICT',
          'Merge conflict detected',
          {'conflictingFiles': conflictingFiles, 'details': details},
        ),
        ReviewNotFound() => _taskNotFound(),
        ReviewInvalidTransition(:final taskId, :final oldStatus, :final targetStatus, :final currentStatus) =>
          _invalidTransition(taskId, oldStatus, targetStatus, currentStatus: currentStatus),
        ReviewInvalidRequest(:final message) => errorResponse(400, 'INVALID_INPUT', message),
        ReviewActionFailed(:final message) => errorResponse(
          500,
          'INTERNAL_ERROR',
          _sanitizeReviewFailureMessage(message),
        ),
      };
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

      final existing = store.lookupByThread(channelType, threadId);
      if (existing != null) {
        return errorResponse(
          409,
          'CONFLICT',
          existing.taskId == id
              ? 'Binding already exists for this thread/group'
              : 'Thread/group already bound to task ${existing.taskId}',
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

Future<Response> _transitionTask({
  required TaskService tasks,
  required String taskId,
  required TaskStatus targetStatus,
  required String errorCode,
  required String trigger,
  required String actionLabel,
}) async {
  try {
    final task = await tasks.get(taskId);
    if (task == null) return _taskNotFound();

    final oldStatus = task.status;
    try {
      final updated = await tasks.transition(taskId, targetStatus, trigger: trigger);
      return jsonResponse(200, updated.toJson());
    } on ArgumentError {
      return _taskNotFound();
    } on VersionConflictException catch (e) {
      return errorResponse(409, 'VERSION_CONFLICT', 'Task was modified concurrently. Refresh and retry.', {
        'currentVersion': e.currentVersion,
      });
    } on StateError {
      final current = await tasks.get(taskId);
      return errorResponse(409, errorCode, 'Cannot transition from ${oldStatus.name} to ${targetStatus.name}', {
        'currentStatus': current?.status.name ?? task.status.name,
      });
    }
  } catch (e, st) {
    _log.warning('Failed to $actionLabel $taskId: $e', e, st);
    return errorResponse(500, 'INTERNAL_ERROR', 'Failed to $actionLabel');
  }
}

Response _taskNotFound() => errorResponse(404, 'TASK_NOT_FOUND', 'Task not found');

Response _invalidTransition(String taskId, TaskStatus oldStatus, TaskStatus targetStatus, {TaskStatus? currentStatus}) {
  return errorResponse(409, 'INVALID_TRANSITION', 'Cannot transition from ${oldStatus.name} to ${targetStatus.name}', {
    'currentStatus': currentStatus?.name ?? oldStatus.name,
    'taskId': taskId,
  });
}

Map<String, dynamic> _jsonMapOrEmpty(Object? value) {
  if (value == null) return <String, dynamic>{};
  return Map<String, dynamic>.from(value as Map);
}

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

String? _stringOrNull(Object? value) => value is String ? value : null;

Response? _validateStringFieldType(Map<String, dynamic> body, String field) {
  if (!body.containsKey(field)) return null;
  final value = body[field];
  if (value == null || value is String) return null;
  return errorResponse(400, 'INVALID_INPUT', '$field must be a string', {'field': field});
}

String _sanitizeReviewFailureMessage(String message) {
  final trimmed = message.trim();
  final lower = trimmed.toLowerCase();
  if (lower.startsWith('could not accept task:') ||
      lower.startsWith('could not reject task:') ||
      lower.startsWith('could not push back task:')) {
    return 'Review action failed. Please try again or use the web UI.';
  }
  return trimmed;
}

Future<void> _cleanupWorktree(
  String taskId,
  WorktreeManager? worktreeManager,
  TaskFileGuard? taskFileGuard, {
  Project? project,
}) async {
  try {
    await worktreeManager?.cleanup(taskId, project: project);
  } catch (e) {
    _log.warning('Failed to cleanup worktree for task $taskId: $e');
  }
  taskFileGuard?.deregister(taskId);
}

Future<Project?> _cleanupProjectForTask(Task? task, ProjectService? projectService) async {
  if (task == null || projectService == null) {
    return null;
  }
  final projectId = taskProjectId(task);
  if (projectId == null || projectId == '_local') {
    return null;
  }
  return projectService.get(projectId);
}
