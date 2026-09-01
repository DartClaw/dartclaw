import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_core/dartclaw_core.dart' show ProjectService, Task, TaskStatus, TurnManager;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import '../task/task_file_guard.dart';
import '../task/task_project_ref.dart';
import '../task/task_service.dart';
import '../task/worktree_cleanup.dart';
import '../task/worktree_manager.dart';
import 'project_auth_support.dart';

final _log = Logger('ProjectMutations');

/// A project create request, already decoded from whichever encoding carried it.
///
/// Values are the caller's, trimmed: `null` means the field was absent, so the
/// service applies its own default rather than treating a blank control as an
/// empty value.
typedef ProjectCreateRequest = ({
  String? name,
  String? remoteUrl,
  String? localPath,
  String? defaultBranch,
  String? credentialsRef,
  CloneStrategy cloneStrategy,
  PrConfig pr,
});

/// A project update request. Every `null` field means "leave unchanged".
typedef ProjectUpdateRequest = ({
  String? name,
  String? remoteUrl,
  String? defaultBranch,
  String? credentialsRef,
  PrConfig? pr,
});

/// A refused project mutation, in the one shape both tiers publish.
///
/// [status], [code], [message] and [details] are the JSON tier's error envelope
/// verbatim. [field] names the form control the message belongs to, or is
/// `null` when the refusal has no control to land on — the web tier then
/// reports it as a toast instead of a field error.
final class ProjectMutationRefusal {
  const new({required this.status, required this.code, required this.message, this.details, this.field});

  final int status;
  final String code;
  final String message;
  final Map<String, dynamic>? details;
  final String? field;
}

/// The outcome of a [ProjectMutationService] call.
sealed class ProjectMutationResult {
  const new();
}

/// The mutation was applied; [project] is the resulting project, `null` for a delete.
final class ProjectMutationApplied extends ProjectMutationResult {
  const new(this.project);

  final Project? project;
}

/// The mutation was refused; nothing was written.
final class ProjectMutationRefused extends ProjectMutationResult {
  const new(this.refusal);

  final ProjectMutationRefusal refusal;
}

/// The one authority deciding every project mutation.
///
/// `/api/projects*` and the `/projects` page's own mutating routes both call
/// this, so a change either tier refuses is refused for the same reason with
/// the same code. Nothing here builds an HTTP response: each tier renders
/// [ProjectMutationRefusal] in its own encoding.
final class ProjectMutationService {
  new({
    required this.projects,
    this.projectConfig = const ProjectConfig.defaults(),
    this.containerEnabled = false,
    this.containerMountRoots = const [],
    this.tasks,
    this.worktreeManager,
    this.taskFileGuard,
    this.turns,
  });

  final ProjectService projects;
  final ProjectConfig projectConfig;
  final bool containerEnabled;
  final List<String> containerMountRoots;
  final TaskService? tasks;
  final WorktreeManager? worktreeManager;
  final TaskFileGuard? taskFileGuard;
  final TurnManager? turns;

  /// Creates a project, initiating the clone for a remote-backed one.
  Future<ProjectMutationResult> create(ProjectCreateRequest request) async {
    try {
      final name = request.name;
      final remoteUrl = request.remoteUrl;
      final localPath = request.localPath;

      if (name == null || name.isEmpty) {
        return _refused(400, 'INVALID_INPUT', 'name must not be empty', details: {'field': 'name'}, field: 'name');
      }

      final hasRemote = remoteUrl != null && remoteUrl.isNotEmpty;
      final hasLocalPath = localPath != null && localPath.isNotEmpty;
      if (!hasRemote && !hasLocalPath) {
        return _refused(
          400,
          'MISSING_INPUT',
          'Exactly one of remoteUrl or localPath must be provided',
          details: {
            'fields': ['remoteUrl', 'localPath'],
          },
          field: 'remoteUrl',
        );
      }
      if (hasRemote && hasLocalPath) {
        return _refused(
          400,
          'XOR_INPUT',
          'Exactly one of remoteUrl or localPath must be provided',
          details: {
            'fields': ['remoteUrl', 'localPath'],
          },
          field: 'remoteUrl',
        );
      }
      if (hasLocalPath && !projectConfig.allowApiLocalPath) {
        return _refused(
          403,
          'LOCAL_PATH_DISABLED',
          'API localPath project creation is disabled',
          details: {'field': 'localPath'},
        );
      }

      String? normalizedLocalPath;
      if (hasLocalPath) {
        // Shape validation only (absolute, no traversal). Allowlist containment
        // is enforced below via symlink-aware canonicalization; passing the
        // allowlist here too would add a weaker, lexical-only second check that
        // can drift from the canonicalizing one.
        final validation = validateProjectLocalPath(localPath);
        if (!validation.isValid) {
          return _refused(
            400,
            'INVALID_LOCAL_PATH',
            validation.errorMessage ?? 'Invalid localPath',
            details: {'field': 'localPath', 'reason': validation.errorCode},
          );
        }
        normalizedLocalPath = validation.normalizedPath;
        if (projectConfig.localPathAllowlist.isNotEmpty &&
            !_isPathWithinRoots(normalizedLocalPath, projectConfig.localPathAllowlist)) {
          return _refused(
            400,
            'INVALID_LOCAL_PATH',
            'localPath is outside the configured allowlist',
            details: {'field': 'localPath', 'reason': 'outside-allowlist'},
          );
        }
        if (containerEnabled && !_isPathWithinRoots(normalizedLocalPath, containerMountRoots)) {
          return _refused(
            400,
            'LOCAL_PATH_NOT_MOUNTABLE',
            'Runtime localPath projects are not mountable in container mode unless the path is inside an existing mounted root',
            details: {
              'field': 'localPath',
              'localPath': normalizedLocalPath,
              'mountRoots': _normalizedRoots(containerMountRoots),
            },
          );
        }
      }

      try {
        final project = await projects.create(
          name: name,
          remoteUrl: remoteUrl,
          localPath: normalizedLocalPath,
          defaultBranch: request.defaultBranch ?? 'main',
          credentialsRef: request.credentialsRef,
          cloneStrategy: request.cloneStrategy,
          pr: request.pr,
        );
        return ProjectMutationApplied(project);
      } on ProjectAuthException catch (e) {
        return _refused(422, e.code, e.message, details: e.details, field: 'credentialsRef');
      } on ArgumentError catch (e) {
        return _refused(409, 'PROJECT_ID_CONFLICT', '${e.message}', field: 'name');
      }
    } catch (e, st) {
      _log.warning('Failed to create project: $e', e, st);
      return _refused(500, 'INTERNAL_ERROR', 'Failed to create project');
    }
  }

  /// Updates a runtime-created project's mutable fields.
  Future<ProjectMutationResult> update(String id, ProjectUpdateRequest request) async {
    try {
      if (id == '_local') return _notFound();

      final project = await projects.get(id);
      if (project == null) return _notFound();
      if (project.configDefined) {
        return _refused(403, 'CONFIG_DEFINED', 'Config-defined projects cannot be modified via API');
      }

      // Check for active-task conflict when changing remote coordinates.
      final newRemoteUrl = request.remoteUrl;
      final newDefaultBranch = request.defaultBranch;
      final remoteUrlChanging = newRemoteUrl != null && newRemoteUrl != project.remoteUrl;
      final branchChanging = newDefaultBranch != null && newDefaultBranch != project.defaultBranch;

      if (remoteUrlChanging || branchChanging) {
        if (project.status == ProjectStatus.cloning) {
          return _refused(
            409,
            'CLONE_IN_PROGRESS',
            'Cannot change remote coordinates while clone is in progress',
            field: 'remoteUrl',
          );
        }
        final activeTasks = await _activeTasksForProject(id);
        if (activeTasks.isNotEmpty) {
          return _refused(
            409,
            'ACTIVE_TASKS',
            'Cannot change remote coordinates while active tasks exist for this project',
            details: {'activeTaskCount': activeTasks.length},
            field: 'remoteUrl',
          );
        }
      }

      final updated = await projects.update(
        id,
        name: request.name,
        remoteUrl: newRemoteUrl,
        defaultBranch: newDefaultBranch,
        credentialsRef: request.credentialsRef,
        pr: request.pr,
      );
      return ProjectMutationApplied(updated);
    } on ProjectAuthException catch (e) {
      return _refused(422, e.code, e.message, details: e.details, field: 'credentialsRef');
    } catch (e, st) {
      _log.warning('Failed to update project $id: $e', e, st);
      return _refused(500, 'INTERNAL_ERROR', 'Failed to update project');
    }
  }

  /// Deletes a runtime-created project, cascading to the tasks that target it.
  Future<ProjectMutationResult> delete(String id) async {
    try {
      if (id == '_local') return _notFound();

      final project = await projects.get(id);
      if (project == null) return _notFound();
      if (project.configDefined) {
        return _refused(403, 'CONFIG_DEFINED', 'Config-defined projects cannot be deleted via API');
      }

      await _cascadeDelete(project);
      return const ProjectMutationApplied(null);
    } catch (e, st) {
      _log.warning('Failed to delete project $id: $e', e, st);
      return _refused(500, 'INTERNAL_ERROR', 'Failed to delete project');
    }
  }

  /// Force-fetches a project from its remote, bypassing the cooldown.
  Future<ProjectMutationResult> fetch(String id) async {
    try {
      final project = await projects.get(id);
      if (project == null) return _notFound();
      if (project.status == ProjectStatus.cloning) {
        return _refused(400, 'CLONE_IN_PROGRESS', 'Cannot fetch while clone is in progress');
      }
      if (project.remoteUrl.isEmpty) {
        return _refused(400, 'LOCAL_PROJECT', 'Cannot fetch the local project');
      }

      final updated = await projects.fetch(id);
      return ProjectMutationApplied(updated);
    } on ProjectAuthException catch (e) {
      return _refused(422, e.code, e.message, details: e.details);
    } catch (e, st) {
      _log.warning('Failed to fetch project $id: $e', e, st);
      return _refused(500, 'INTERNAL_ERROR', 'Failed to fetch project');
    }
  }

  ProjectMutationResult _notFound() => _refused(404, 'PROJECT_NOT_FOUND', 'Project not found');

  ProjectMutationResult _refused(
    int status,
    String code,
    String message, {
    Map<String, dynamic>? details,
    String? field,
  }) => ProjectMutationRefused(
    ProjectMutationRefusal(status: status, code: code, message: message, details: details, field: field),
  );

  /// Returns tasks targeting [projectId] in active states (queued, running, review, interrupted).
  Future<List<Task>> _activeTasksForProject(String projectId) async {
    final all = await _tasksForProject(projectId);
    return all
        .where(
          (t) =>
              t.status == TaskStatus.queued ||
              t.status == TaskStatus.running ||
              t.status == TaskStatus.review ||
              t.status == TaskStatus.interrupted,
        )
        .toList();
  }

  /// Returns all tasks targeting [projectId] regardless of status.
  Future<List<Task>> _tasksForProject(String projectId) async {
    final service = tasks;
    if (service == null) return const [];
    final all = await service.list();
    return all.where((t) => taskProjectId(t) == projectId).toList();
  }

  Future<void> _cascadeDelete(Project project) async {
    final projectId = project.id;
    final taskService = tasks;
    if (taskService != null) {
      final projectTasks = await _tasksForProject(projectId);
      for (final task in projectTasks) {
        switch (task.status) {
          case TaskStatus.running:
            if (task.sessionId != null) {
              await turns?.cancelTurn(task.sessionId!);
            }
            continue cancelTask;
          case TaskStatus.queued:
            await _failTaskForDelete(
              taskService,
              task,
              message: 'Project "$projectId" was deleted before task execution started.',
            );
            await cleanupWorktree(worktreeManager, taskFileGuard, task.id, project: project);
          case TaskStatus.interrupted:
            continue cancelTask;
          case TaskStatus.review:
            await _failTaskForDelete(
              taskService,
              task,
              message: 'Project "$projectId" was deleted while the task was awaiting review.',
            );
            await cleanupWorktree(worktreeManager, taskFileGuard, task.id, project: project);
          cancelTask:
          case TaskStatus.draft:
            try {
              await taskService.transition(task.id, TaskStatus.cancelled);
            } catch (e) {
              _log.warning('Version conflict cancelling task ${task.id} during project delete: $e');
            }
            if (task.status != TaskStatus.draft) {
              await cleanupWorktree(worktreeManager, taskFileGuard, task.id, project: project);
            }
          default:
            // completed, accepted, rejected, cancelled, failed — no action
            break;
        }
      }
    }

    await projects.delete(projectId);
  }

  Future<void> _failTaskForDelete(TaskService taskService, Task task, {required String message}) async {
    try {
      await taskService.transition(
        task.id,
        TaskStatus.failed,
        configJson: Map<String, dynamic>.from(task.configJson)..['errorSummary'] = message,
        trigger: 'system',
      );
    } catch (e) {
      _log.warning('Version conflict failing task ${task.id} during project delete: $e');
    }
  }
}

List<String> _normalizedRoots(List<String> roots) {
  return roots
      .map((root) => root.trim())
      .where((root) => root.isNotEmpty)
      .map(canonicalizePathWithExistingAncestors)
      .toList(growable: false);
}

bool _isPathWithinRoots(String hostPath, List<String> roots) {
  final normalizedHostPath = canonicalizePathWithExistingAncestors(hostPath);
  for (final root in _normalizedRoots(roots)) {
    if (p.equals(normalizedHostPath, root) || p.isWithin(root, normalizedHostPath)) {
      return true;
    }
  }
  return false;
}
