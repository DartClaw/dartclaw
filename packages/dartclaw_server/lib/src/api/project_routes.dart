import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' show ProjectService, Task, TaskStatus;
import 'package:dartclaw_models/dartclaw_models.dart' show CloneStrategy, PrConfig, PrStrategy, Project, ProjectStatus;
import 'package:logging/logging.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../task/task_file_guard.dart';
import '../task/task_project_ref.dart';
import '../task/task_service.dart';
import '../task/worktree_manager.dart';
import '../turn_manager.dart';
import 'api_helpers.dart';

final _log = Logger('ProjectRoutes');

/// Creates a [Router] exposing project CRUD and lifecycle API endpoints.
Router projectRoutes(
  ProjectService projects, {
  TaskService? tasks,
  WorktreeManager? worktreeManager,
  TaskFileGuard? taskFileGuard,
  TurnManager? turns,
}) {
  final router = Router();

  // POST /api/projects — create a new project (initiates clone)
  router.post('/api/projects', (Request request) async {
    try {
      final body = await _readJsonObject(request);
      if (body.error != null) return body.error!;

      final nameValue = body.value!['name'];
      final remoteUrlValue = body.value!['remoteUrl'];

      if (nameValue != null && nameValue is! String) {
        return errorResponse(400, 'INVALID_INPUT', 'name must be a string', {'field': 'name'});
      }
      if (remoteUrlValue != null && remoteUrlValue is! String) {
        return errorResponse(400, 'INVALID_INPUT', 'remoteUrl must be a string', {'field': 'remoteUrl'});
      }

      final name = _trimmedStringOrNull(nameValue);
      final remoteUrl = _trimmedStringOrNull(remoteUrlValue);

      if (name == null || name.isEmpty) {
        return errorResponse(400, 'INVALID_INPUT', 'name must not be empty', {'field': 'name'});
      }
      if (remoteUrl == null || remoteUrl.isEmpty) {
        return errorResponse(400, 'INVALID_INPUT', 'remoteUrl must not be empty', {'field': 'remoteUrl'});
      }

      final defaultBranch = _trimmedStringOrNull(body.value!['defaultBranch']) ?? 'main';
      final credentialsRef = _trimmedStringOrNull(body.value!['credentialsRef']);
      final cloneStrategy = _parseCloneStrategy(body.value!['cloneStrategy']);
      final pr = _parsePrConfig(body.value!['pr']);

      try {
        final project = await projects.create(
          name: name,
          remoteUrl: remoteUrl,
          defaultBranch: defaultBranch,
          credentialsRef: credentialsRef,
          cloneStrategy: cloneStrategy,
          pr: pr,
        );
        return jsonResponse(201, project.toJson());
      } on ArgumentError catch (e) {
        return errorResponse(409, 'PROJECT_ID_CONFLICT', '${e.message}');
      }
    } catch (e, st) {
      _log.warning('Failed to create project: $e', e, st);
      return errorResponse(500, 'INTERNAL_ERROR', 'Failed to create project');
    }
  });

  // GET /api/projects — list all projects
  router.get('/api/projects', (Request request) async {
    try {
      final list = await projects.getAll();
      return jsonResponse(200, list.map((p) => p.toJson()).toList());
    } catch (e, st) {
      _log.warning('Failed to list projects: $e', e, st);
      return errorResponse(500, 'INTERNAL_ERROR', 'Failed to list projects');
    }
  });

  // GET /api/projects/<id> — get a specific project
  router.get('/api/projects/<id>', (Request request, String id) async {
    try {
      final project = await projects.get(id);
      if (project == null) return _projectNotFound();
      return jsonResponse(200, project.toJson());
    } catch (e, st) {
      _log.warning('Failed to get project $id: $e', e, st);
      return errorResponse(500, 'INTERNAL_ERROR', 'Failed to get project');
    }
  });

  // PATCH /api/projects/<id> — update a runtime-created project
  router.patch('/api/projects/<id>', (Request request, String id) async {
    try {
      if (id == '_local') return _projectNotFound();

      final project = await projects.get(id);
      if (project == null) return _projectNotFound();
      if (project.configDefined) {
        return errorResponse(403, 'CONFIG_DEFINED', 'Config-defined projects cannot be modified via API');
      }

      final body = await _readJsonObject(request);
      if (body.error != null) return body.error!;

      // Check for active-task conflict when changing remote coordinates.
      final newRemoteUrl = _trimmedStringOrNull(body.value!['remoteUrl']);
      final newDefaultBranch = _trimmedStringOrNull(body.value!['defaultBranch']);
      final remoteUrlChanging = newRemoteUrl != null && newRemoteUrl != project.remoteUrl;
      final branchChanging = newDefaultBranch != null && newDefaultBranch != project.defaultBranch;

      if (remoteUrlChanging || branchChanging) {
        if (project.status == ProjectStatus.cloning) {
          return errorResponse(409, 'CLONE_IN_PROGRESS', 'Cannot change remote coordinates while clone is in progress');
        }
        final activeTasks = await _getActiveTasksForProject(tasks, id);
        if (activeTasks.isNotEmpty) {
          return errorResponse(
            409,
            'ACTIVE_TASKS',
            'Cannot change remote coordinates while active tasks exist for this project',
            {'activeTaskCount': activeTasks.length},
          );
        }
      }

      final updated = await projects.update(
        id,
        name: _trimmedStringOrNull(body.value!['name']),
        remoteUrl: newRemoteUrl,
        defaultBranch: newDefaultBranch,
        credentialsRef: _trimmedStringOrNull(body.value!['credentialsRef']),
        pr: body.value!.containsKey('pr') ? _parsePrConfig(body.value!['pr']) : null,
      );
      return jsonResponse(200, updated.toJson());
    } catch (e, st) {
      _log.warning('Failed to update project $id: $e', e, st);
      return errorResponse(500, 'INTERNAL_ERROR', 'Failed to update project');
    }
  });

  // DELETE /api/projects/<id> — delete with cascade
  router.delete('/api/projects/<id>', (Request request, String id) async {
    try {
      if (id == '_local') return _projectNotFound();

      final project = await projects.get(id);
      if (project == null) return _projectNotFound();
      if (project.configDefined) {
        return errorResponse(403, 'CONFIG_DEFINED', 'Config-defined projects cannot be deleted via API');
      }

      await _cascadeDeleteProject(project, projects, tasks, worktreeManager, taskFileGuard, turns);
      return jsonResponse(200, {'deleted': id});
    } catch (e, st) {
      _log.warning('Failed to delete project $id: $e', e, st);
      return errorResponse(500, 'INTERNAL_ERROR', 'Failed to delete project');
    }
  });

  // POST /api/projects/<id>/fetch — force-fetch from remote
  router.post('/api/projects/<id>/fetch', (Request request, String id) async {
    try {
      final project = await projects.get(id);
      if (project == null) return _projectNotFound();
      if (project.status == ProjectStatus.cloning) {
        return errorResponse(400, 'CLONE_IN_PROGRESS', 'Cannot fetch while clone is in progress');
      }
      if (project.remoteUrl.isEmpty) {
        return errorResponse(400, 'LOCAL_PROJECT', 'Cannot fetch the local project');
      }

      final updated = await projects.fetch(id);
      return jsonResponse(200, updated.toJson());
    } catch (e, st) {
      _log.warning('Failed to fetch project $id: $e', e, st);
      return errorResponse(500, 'INTERNAL_ERROR', 'Failed to fetch project');
    }
  });

  // GET /api/projects/<id>/status — clone health status
  router.get('/api/projects/<id>/status', (Request request, String id) async {
    try {
      final project = await projects.get(id);
      if (project == null) return _projectNotFound();

      final cloneExists = project.localPath.isNotEmpty && Directory(project.localPath).existsSync();

      return jsonResponse(200, {
        'id': project.id,
        'status': project.status.name,
        'lastFetchAt': project.lastFetchAt?.toIso8601String(),
        'errorMessage': project.errorMessage,
        'cloneExists': cloneExists,
      });
    } catch (e, st) {
      _log.warning('Failed to get status for project $id: $e', e, st);
      return errorResponse(500, 'INTERNAL_ERROR', 'Failed to get project status');
    }
  });

  return router;
}

// ---------------------------------------------------------------------------
// Private helpers
// ---------------------------------------------------------------------------

Response _projectNotFound() => errorResponse(404, 'PROJECT_NOT_FOUND', 'Project not found');

/// Returns tasks targeting [projectId] in active states (queued, running, review, interrupted).
Future<List<Task>> _getActiveTasksForProject(TaskService? tasks, String projectId) async {
  if (tasks == null) return const [];
  final all = await tasks.list();
  return all
      .where(
        (t) =>
            _taskTargetsProject(t, projectId) &&
            (t.status == TaskStatus.queued ||
                t.status == TaskStatus.running ||
                t.status == TaskStatus.review ||
                t.status == TaskStatus.interrupted),
      )
      .toList();
}

/// Returns all tasks targeting [projectId] regardless of status.
Future<List<Task>> _getTasksForProject(TaskService? tasks, String projectId) async {
  if (tasks == null) return const [];
  final all = await tasks.list();
  return all.where((t) => _taskTargetsProject(t, projectId)).toList();
}

/// Checks if a task targets the given project.
bool _taskTargetsProject(Task task, String projectId) {
  return taskProjectId(task) == projectId;
}

Future<void> _cascadeDeleteProject(
  Project project,
  ProjectService projects,
  TaskService? tasks,
  WorktreeManager? worktreeManager,
  TaskFileGuard? taskFileGuard,
  TurnManager? turns,
) async {
  final projectId = project.id;
  if (tasks != null) {
    final projectTasks = await _getTasksForProject(tasks, projectId);
    for (final task in projectTasks) {
      switch (task.status) {
        case TaskStatus.running:
          if (task.sessionId != null) {
            await turns?.cancelTurn(task.sessionId!);
          }
          try {
            await tasks.transition(task.id, TaskStatus.cancelled);
          } catch (e) {
            _log.warning('Version conflict cancelling task ${task.id} during project delete: $e');
          }
          await _cleanupWorktree(task.id, worktreeManager, taskFileGuard, project: project);
          break;
        case TaskStatus.queued:
          await _failTaskForProjectDelete(
            tasks,
            task,
            message: 'Project "$projectId" was deleted before task execution started.',
          );
          await _cleanupWorktree(task.id, worktreeManager, taskFileGuard, project: project);
          break;
        case TaskStatus.interrupted:
          try {
            await tasks.transition(task.id, TaskStatus.cancelled);
          } catch (e) {
            _log.warning('Version conflict cancelling task ${task.id} during project delete: $e');
          }
          await _cleanupWorktree(task.id, worktreeManager, taskFileGuard, project: project);
          break;
        case TaskStatus.review:
          await _failTaskForProjectDelete(
            tasks,
            task,
            message: 'Project "$projectId" was deleted while the task was awaiting review.',
          );
          await _cleanupWorktree(task.id, worktreeManager, taskFileGuard, project: project);
          break;
        case TaskStatus.draft:
          try {
            await tasks.transition(task.id, TaskStatus.cancelled);
          } catch (e) {
            _log.warning('Version conflict cancelling task ${task.id} during project delete: $e');
          }
          break;
        default:
          // completed, accepted, rejected, cancelled, failed — no action
          break;
      }
    }
  }

  await projects.delete(projectId);
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

Future<void> _failTaskForProjectDelete(TaskService tasks, Task task, {required String message}) async {
  try {
    await tasks.transition(
      task.id,
      TaskStatus.failed,
      configJson: Map<String, dynamic>.from(task.configJson)..['errorSummary'] = message,
      trigger: 'system',
    );
  } catch (e) {
    _log.warning('Version conflict failing task ${task.id} during project delete: $e');
  }
}

PrConfig _parsePrConfig(Object? value) {
  if (value is! Map) return const PrConfig.defaults();
  final map = Map<String, dynamic>.from(value);
  return PrConfig(
    strategy: PrStrategy.fromYaml(map['strategy']),
    draft: map['draft'] == true,
    labels: (map['labels'] as List?)?.cast<String>() ?? const [],
  );
}

CloneStrategy _parseCloneStrategy(Object? value) {
  if (value is! String) return CloneStrategy.shallow;
  return switch (value) {
    'shallow' => CloneStrategy.shallow,
    'full' => CloneStrategy.full,
    'sparse' => CloneStrategy.sparse,
    _ => CloneStrategy.shallow,
  };
}

Future<({Map<String, dynamic>? value, Response? error})> _readJsonObject(Request request) async {
  try {
    final body = await request.readAsString();
    final decoded = jsonDecode(body);
    if (decoded is! Map) {
      return (value: null, error: errorResponse(400, 'INVALID_INPUT', 'JSON body must be an object'));
    }
    return (value: Map<String, dynamic>.from(decoded), error: null);
  } on FormatException {
    return (value: null, error: errorResponse(400, 'INVALID_INPUT', 'Invalid JSON body'));
  } on TypeError {
    return (value: null, error: errorResponse(400, 'INVALID_INPUT', 'Invalid JSON structure'));
  }
}

String? _stringOrNull(Object? value) => value is String ? value : null;

String? _trimmedStringOrNull(Object? value) => _stringOrNull(value)?.trim();
