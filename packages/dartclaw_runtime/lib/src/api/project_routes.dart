import 'dart:io';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_core/dartclaw_core.dart' show ProjectService, TurnManager;
import 'package:logging/logging.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../project/project_mutation_service.dart';
import '../task/task_file_guard.dart';
import '../task/task_service.dart';
import '../task/worktree_manager.dart';
import 'api_helpers.dart';

final _log = Logger('ProjectRoutes');

/// Creates a [Router] exposing project CRUD and lifecycle API endpoints.
///
/// [mutations] is the shared [ProjectMutationService]; when omitted one is
/// built from the parameters above it, so a caller that only wires the JSON
/// tier needs no separate construction.
Router projectRoutes(
  ProjectService projects, {
  ProjectConfig projectConfig = const ProjectConfig.defaults(),
  bool containerEnabled = false,
  List<String> containerMountRoots = const [],
  TaskService? tasks,
  WorktreeManager? worktreeManager,
  TaskFileGuard? taskFileGuard,
  TurnManager? turns,
  ProjectMutationService? mutations,
}) {
  final router = Router();
  final projectMutations =
      mutations ??
      ProjectMutationService(
        projects: projects,
        projectConfig: projectConfig,
        containerEnabled: containerEnabled,
        containerMountRoots: containerMountRoots,
        tasks: tasks,
        worktreeManager: worktreeManager,
        taskFileGuard: taskFileGuard,
        turns: turns,
      );

  // POST /api/projects — create a new project (initiates clone)
  router.post('/api/projects', (Request request) async {
    // The decode runs inside the guard: a body whose shape survives the type
    // checks can still throw in the cast (`pr.labels` as a string), and this
    // route publishes a JSON error envelope for every rejection.
    try {
      final body = await readJsonObject(request);
      if (body.error != null) return body.error!;
      final decoded = _decodeCreateBody(body.value!);
      if (decoded.error != null) return decoded.error!;

      final result = await projectMutations.create(decoded.request!);
      return switch (result) {
        ProjectMutationApplied(:final project) => jsonResponse(201, project!.toJson()),
        ProjectMutationRefused(:final refusal) => _refusalResponse(refusal),
      };
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
      if (project == null) return errorResponse(404, 'PROJECT_NOT_FOUND', 'Project not found');
      return jsonResponse(200, project.toJson());
    } catch (e, st) {
      _log.warning('Failed to get project $id: $e', e, st);
      return errorResponse(500, 'INTERNAL_ERROR', 'Failed to get project');
    }
  });

  // PATCH /api/projects/<id> — update a runtime-created project
  router.patch('/api/projects/<id>', (Request request, String id) async {
    try {
      final body = await readJsonObject(request);
      if (body.error != null) return body.error!;

      final result = await projectMutations.update(id, _decodeUpdateBody(body.value!));
      return switch (result) {
        ProjectMutationApplied(:final project) => jsonResponse(200, project!.toJson()),
        ProjectMutationRefused(:final refusal) => _refusalResponse(refusal),
      };
    } catch (e, st) {
      _log.warning('Failed to update project $id: $e', e, st);
      return errorResponse(500, 'INTERNAL_ERROR', 'Failed to update project');
    }
  });

  // DELETE /api/projects/<id> — delete with cascade
  router.delete('/api/projects/<id>', (Request request, String id) async {
    final result = await projectMutations.delete(id);
    return switch (result) {
      ProjectMutationApplied() => jsonResponse(200, {'deleted': id}),
      ProjectMutationRefused(:final refusal) => _refusalResponse(refusal),
    };
  });

  // POST /api/projects/<id>/fetch — force-fetch from remote
  router.post('/api/projects/<id>/fetch', (Request request, String id) async {
    final result = await projectMutations.fetch(id);
    return switch (result) {
      ProjectMutationApplied(:final project) => jsonResponse(200, project!.toJson()),
      ProjectMutationRefused(:final refusal) => _refusalResponse(refusal),
    };
  });

  // GET /api/projects/<id>/status — clone health status
  router.get('/api/projects/<id>/status', (Request request, String id) async {
    try {
      final project = await projects.get(id);
      if (project == null) return errorResponse(404, 'PROJECT_NOT_FOUND', 'Project not found');

      final cloneExists = project.localPath.isNotEmpty && Directory(project.localPath).existsSync();

      return jsonResponse(200, {
        'id': project.id,
        'status': project.status.name,
        'lastFetchAt': project.lastFetchAt?.toIso8601String(),
        'errorMessage': project.errorMessage,
        'cloneExists': cloneExists,
        'auth': project.auth?.toJson(),
      });
    } catch (e, st) {
      _log.warning('Failed to get status for project $id: $e', e, st);
      return errorResponse(500, 'INTERNAL_ERROR', 'Failed to get project status');
    }
  });

  return router;
}

// ---------------------------------------------------------------------------
// JSON decoding — shape only; every domain rule lives in ProjectMutationService
// ---------------------------------------------------------------------------

Response _refusalResponse(ProjectMutationRefusal refusal) =>
    errorResponse(refusal.status, refusal.code, refusal.message, refusal.details);

({ProjectCreateRequest? request, Response? error}) _decodeCreateBody(Map<String, dynamic> body) {
  for (final field in const ['name', 'remoteUrl', 'localPath']) {
    final value = body[field];
    if (value != null && value is! String) {
      return (request: null, error: errorResponse(400, 'INVALID_INPUT', '$field must be a string', {'field': field}));
    }
  }
  return (
    request: (
      name: trimmedStringOrNull(body['name']),
      remoteUrl: trimmedStringOrNull(body['remoteUrl']),
      localPath: trimmedStringOrNull(body['localPath']),
      defaultBranch: trimmedStringOrNull(body['defaultBranch']),
      credentialsRef: trimmedStringOrNull(body['credentialsRef']),
      cloneStrategy: _parseCloneStrategy(body['cloneStrategy']),
      pr: _parsePrConfig(body['pr']),
    ),
    error: null,
  );
}

ProjectUpdateRequest _decodeUpdateBody(Map<String, dynamic> body) => (
  name: trimmedStringOrNull(body['name']),
  remoteUrl: trimmedStringOrNull(body['remoteUrl']),
  defaultBranch: trimmedStringOrNull(body['defaultBranch']),
  credentialsRef: trimmedStringOrNull(body['credentialsRef']),
  pr: body.containsKey('pr') ? _parsePrConfig(body['pr']) : null,
);

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
