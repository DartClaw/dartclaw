import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import 'diff_generator.dart';
import 'task_service.dart';
import 'task_project_ref.dart';
import 'worktree_manager.dart';

/// Collects task artifacts into `<dataDir>/tasks/<taskId>/artifacts/`.
class ArtifactCollector {
  ArtifactCollector({
    required TaskService tasks,
    required MessageService messages,
    required String sessionsDir,
    required String dataDir,
    required String workspaceDir,
    DiffGenerator? diffGenerator,
    ProjectService? projectService,
    String? baseRef,
    Uuid? uuid,
  }) : _tasks = tasks,
       _messages = messages,
       _sessionsDir = sessionsDir,
       _dataDir = dataDir,
       _workspaceDir = workspaceDir,
       _diffGenerator = diffGenerator,
       _projectService = projectService,
       _baseRef = baseRef,
       _uuid = uuid ?? const Uuid();

  static final _log = Logger('ArtifactCollector');

  final TaskService _tasks;
  final MessageService _messages;
  final String _sessionsDir;
  final String _dataDir;
  final String _workspaceDir;
  final DiffGenerator? _diffGenerator;
  final ProjectService? _projectService;
  final String? _baseRef;
  final Uuid _uuid;

  Future<List<TaskArtifact>> collect(Task task) async {
    await _clearExistingArtifacts(task.id);

    final artifactsDir = Directory(p.join(_dataDir, 'tasks', task.id, 'artifacts'));
    await artifactsDir.create(recursive: true);

    return switch (task.type) {
      TaskType.research || TaskType.writing => _copyMatchingFiles(
        task: task,
        artifactsDir: artifactsDir,
        extensions: const {'.md'},
        modifiedSince: task.startedAt,
        kindForFile: (_) => ArtifactKind.document,
      ),
      TaskType.analysis => _copyMatchingFiles(
        task: task,
        artifactsDir: artifactsDir,
        extensions: const {'.json', '.csv', '.yaml', '.yml', '.xml', '.txt'},
        modifiedSince: task.startedAt,
        kindForFile: (_) => ArtifactKind.data,
      ),
      TaskType.automation => _writeTranscriptSummaryArtifact(task, artifactsDir),
      TaskType.coding => _collectCodingArtifacts(task),
      TaskType.custom => _copyMatchingFiles(
        task: task,
        artifactsDir: artifactsDir,
        extensions: null,
        modifiedSince: null,
        kindForFile: _inferArtifactKind,
      ),
    };
  }

  Future<List<TaskArtifact>> _copyMatchingFiles({
    required Task task,
    required Directory artifactsDir,
    required Set<String>? extensions,
    required DateTime? modifiedSince,
    required ArtifactKind Function(File file) kindForFile,
  }) async {
    final workspaceDir = Directory(_workspaceDir);
    if (!workspaceDir.existsSync()) {
      _log.info('Workspace directory $_workspaceDir is missing; nothing to collect for task ${task.id}');
      return const <TaskArtifact>[];
    }

    final artifacts = <TaskArtifact>[];
    await for (final entity in workspaceDir.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      if (_isExcludedWorkspaceFile(entity)) continue;

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

  Future<List<TaskArtifact>> _writeTranscriptSummaryArtifact(Task task, Directory artifactsDir) async {
    final sessionId = task.sessionId;
    if (sessionId == null || sessionId.isEmpty) {
      _log.info('Task ${task.id} has no session; transcript artifact skipped');
      return const <TaskArtifact>[];
    }

    final transcriptFile = File(p.join(artifactsDir.path, 'transcript.md'));
    await transcriptFile.parent.create(recursive: true);
    await transcriptFile.writeAsString(await _buildTranscriptSummary(task, sessionId));

    return [
      await _tasks.addArtifact(
        id: _uuid.v4(),
        taskId: task.id,
        name: 'transcript.md',
        kind: ArtifactKind.document,
        path: transcriptFile.path,
      ),
    ];
  }

  Future<List<TaskArtifact>> _collectCodingArtifacts(Task task) async {
    final diffGen = _diffGenerator;
    if (diffGen == null) {
      _log.info('DiffGenerator not available; coding artifacts skipped for task ${task.id}');
      return const <TaskArtifact>[];
    }

    final worktreeData = task.worktreeJson;
    if (worktreeData == null) {
      _log.info('Task ${task.id} has no worktree info; coding artifact skipped');
      return const <TaskArtifact>[];
    }

    final baseRef = _baseRef ?? 'main';
    try {
      final worktreeInfo = WorktreeInfo.fromJson(worktreeData);
      var effectiveBaseRef = baseRef;
      final projectDir = worktreeInfo.path;
      final projectId = taskProjectId(task);
      if (projectId != null && projectId != '_local') {
        final project = await _projectService?.get(projectId);
        if (project != null) {
          effectiveBaseRef = 'origin/${project.defaultBranch}';
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

  bool _isExcludedWorkspaceFile(File file) {
    final absolutePath = p.normalize(p.absolute(file.path));
    final workspaceRoot = p.normalize(p.absolute(_workspaceDir));
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

  Future<String> _buildTranscriptSummary(Task task, String sessionId) async {
    final messages = await _messages.getMessages(sessionId);
    final userMessages = messages.where((message) => message.role == 'user').toList(growable: false);
    final assistantMessages = messages.where((message) => message.role == 'assistant').toList(growable: false);
    final buffer = StringBuffer()
      ..writeln('# Task Transcript Summary')
      ..writeln()
      ..writeln('## Task')
      ..writeln(task.title)
      ..writeln()
      ..writeln('## Overview')
      ..writeln('- Total messages: ${messages.length}')
      ..writeln('- User messages: ${userMessages.length}')
      ..writeln('- Assistant messages: ${assistantMessages.length}');

    if (messages.isEmpty) {
      buffer.writeln();
      buffer.writeln('## Highlights');
      buffer.writeln();
      buffer.writeln('_No session messages were recorded._');
      return buffer.toString();
    }

    final firstUser = userMessages.isEmpty ? null : userMessages.first;
    final latestUser = userMessages.isEmpty ? null : userMessages.last;
    final latestAssistant = assistantMessages.isEmpty ? null : assistantMessages.last;

    buffer
      ..writeln()
      ..writeln('## Highlights')
      ..writeln()
      ..writeln('- Initial request: ${_summarizeMessage(firstUser?.content)}')
      ..writeln('- Latest user input: ${_summarizeMessage(latestUser?.content)}')
      ..writeln('- Latest assistant output: ${_summarizeMessage(latestAssistant?.content)}');

    return buffer.toString();
  }

  String _summarizeMessage(String? content) {
    if (content == null) return '_None_';
    final normalized = content.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (normalized.isEmpty) return '_Empty message_';
    const maxLength = 120;
    if (normalized.length <= maxLength) return normalized;
    return '${normalized.substring(0, maxLength - 1)}…';
  }
}
