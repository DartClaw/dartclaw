import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import 'diff_generator.dart';
import 'task_config_view.dart';
import 'task_service.dart';
import 'task_project_ref.dart';
import 'worktree_manager.dart';

/// Collects task artifacts into `<dataDir>/tasks/<taskId>/artifacts/`.
class ArtifactCollector {
  new({
    required TaskService tasks,
    required String sessionsDir,
    required String dataDir,
    DiffGenerator? diffGenerator,
    ProjectService? projectService,
    String? baseRef,
    Uuid? uuid,
  }) : _tasks = tasks,
       _sessionsDir = sessionsDir,
       _dataDir = dataDir,
       _diffGenerator = diffGenerator,
       _projectService = projectService,
       _baseRef = baseRef,
       _uuid = uuid ?? const Uuid();

  static final _log = Logger('ArtifactCollector');

  final TaskService _tasks;
  final String _sessionsDir;
  final String _dataDir;
  final DiffGenerator? _diffGenerator;
  final ProjectService? _projectService;
  final String? _baseRef;
  final Uuid _uuid;

  Future<List<TaskArtifact>> collect(Task task, {required String executionDirectory}) async {
    await _clearExistingArtifacts(task.id);

    final artifactsDir = Directory(p.join(_dataDir, 'tasks', task.id, 'artifacts'));
    await artifactsDir.create(recursive: true);

    if (task.worktreeJson != null) return _collectWorktreeArtifacts(task);
    return _copyMatchingFiles(
      task: task,
      artifactsDir: artifactsDir,
      executionDirectory: executionDirectory,
      extensions: TaskConfigView(task, log: _log).artifactExtensions,
      modifiedSince: task.startedAt,
      kindForFile: _inferArtifactKind,
    );
  }

  Future<List<TaskArtifact>> _copyMatchingFiles({
    required Task task,
    required Directory artifactsDir,
    required String executionDirectory,
    required Set<String>? extensions,
    required DateTime? modifiedSince,
    required ArtifactKind Function(File file) kindForFile,
  }) async {
    final workspaceDir = Directory(executionDirectory);
    if (!workspaceDir.existsSync()) {
      _log.info('Execution directory $executionDirectory is missing; nothing to collect for task ${task.id}');
      return const <TaskArtifact>[];
    }

    final artifacts = <TaskArtifact>[];
    await for (final entity in workspaceDir.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      if (_isExcludedWorkspaceFile(entity, workspaceDir.path)) continue;

      final stat = await entity.stat();
      if (modifiedSince != null && stat.modified.isBefore(modifiedSince)) continue;

      final relativePath = p.relative(entity.path, from: workspaceDir.path);

      final extension = p.extension(entity.path).toLowerCase();
      if (extensions != null && !extensions.contains(extension)) continue;

      final destination = File(p.join(artifactsDir.path, relativePath));
      await destination.parent.create(recursive: true);
      await entity.copy(destination.path);

      artifacts.add(
        await _tasks.addArtifact(
          id: _uuid.v4(),
          taskId: task.id,
          name: relativePath,
          kind: kindForFile(entity),
          path: destination.path,
        ),
      );
    }

    return artifacts;
  }

  Future<List<TaskArtifact>> _collectWorktreeArtifacts(Task task) async {
    final diffGen = _diffGenerator;
    if (diffGen == null) {
      _log.info('DiffGenerator not available; worktree artifact skipped for task ${task.id}');
      return const <TaskArtifact>[];
    }

    final worktreeData = task.worktreeJson;
    if (worktreeData == null) {
      _log.info('Task ${task.id} has no worktree info; worktree artifact skipped');
      return const <TaskArtifact>[];
    }

    try {
      final worktreeInfo = WorktreeInfo.fromJson(worktreeData);
      var effectiveBaseRef = _taskBaseRef(task) ?? _baseRef ?? 'main';
      final projectDir = worktreeInfo.path;
      final projectId = taskProjectId(task);
      if (projectId != null && projectId != '_local') {
        final project = await _projectService?.get(projectId);
        if (project != null) {
          effectiveBaseRef = _effectiveProjectBaseRef(project, effectiveBaseRef);
        }
      }
      final diffResult = await diffGen.generate(
        baseRef: effectiveBaseRef,
        branch: worktreeInfo.branch,
        projectDir: projectDir,
      );

      final artifactsDir = Directory(p.join(_dataDir, 'tasks', task.id, 'artifacts'));
      await artifactsDir.create(recursive: true);
      final diffFile = File(p.join(artifactsDir.path, 'diff.json'));
      await diffFile.writeAsString(jsonEncode(diffResult.toJson()));

      return [
        await _tasks.addArtifact(
          id: _uuid.v4(),
          taskId: task.id,
          name: 'diff.json',
          kind: ArtifactKind.diff,
          path: diffFile.path,
        ),
      ];
    } catch (e) {
      _log.warning('Failed to generate diff for task ${task.id}: $e');
      return const <TaskArtifact>[];
    }
  }

  String? _taskBaseRef(Task task) {
    final raw = task.configJson['_baseRef'] ?? task.configJson['baseRef'];
    if (raw is! String) return null;
    final trimmed = raw.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  String _effectiveProjectBaseRef(Project project, String currentBaseRef) {
    final trimmed = currentBaseRef.trim();
    if (trimmed.startsWith('dartclaw/workflow/')) {
      return trimmed;
    }
    if (project.remoteUrl.isEmpty) {
      if (trimmed.isNotEmpty) {
        return trimmed;
      }
      final configured = project.defaultBranch.trim();
      return configured.isNotEmpty ? configured : 'main';
    }
    final configured = project.defaultBranch.trim();
    if (configured.isNotEmpty) {
      return 'origin/$configured';
    }
    if (trimmed.isNotEmpty) {
      if (trimmed.startsWith('origin/') || trimmed.startsWith('refs/')) {
        return trimmed;
      }
      return 'origin/$trimmed';
    }
    return 'main';
  }

  Future<void> _clearExistingArtifacts(String taskId) async {
    final existing = await _tasks.listArtifacts(taskId);
    for (final artifact in existing) {
      await _tasks.deleteArtifact(artifact.id);
    }

    final artifactsDir = Directory(p.join(_dataDir, 'tasks', taskId, 'artifacts'));
    if (artifactsDir.existsSync()) {
      await artifactsDir.delete(recursive: true);
    }
  }

  bool _isExcludedWorkspaceFile(File file, String executionDirectory) {
    final absolutePath = p.normalize(p.absolute(file.path));
    final workspaceRoot = p.normalize(p.absolute(executionDirectory));
    final relativePath = p.relative(absolutePath, from: workspaceRoot);
    final segments = p.split(relativePath);

    if (segments.contains('.git')) return true;
    if (_isWithinPath(absolutePath, _dataDir)) return true;
    if (_isWithinPath(absolutePath, _sessionsDir)) return true;

    return false;
  }

  bool _isWithinPath(String absolutePath, String rootPath) {
    final normalizedRoot = p.normalize(p.absolute(rootPath));
    return absolutePath == normalizedRoot || p.isWithin(normalizedRoot, absolutePath);
  }

  ArtifactKind _inferArtifactKind(File file) {
    final extension = p.extension(file.path).toLowerCase();
    if (extension == '.diff' || extension == '.patch') return ArtifactKind.diff;
    if (const {'.json', '.csv', '.yaml', '.yml', '.xml', '.txt'}.contains(extension)) {
      return ArtifactKind.data;
    }
    return ArtifactKind.document;
  }
}
