import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:dartclaw_core/dartclaw_core.dart'
    show CredentialsConfig, EventBus, ProjectConfig, ProjectService, ProjectStatusChangedEvent, atomicWriteJson;
import 'package:dartclaw_models/dartclaw_models.dart' show CloneStrategy, PrConfig, Project, ProjectStatus;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import '../task/git_credential_env.dart';

/// Function type for running git commands, injectable for testing.
///
/// Production implementation uses [Isolate.run] with [Process.run].
/// Test implementations return predetermined results.
typedef GitRunner =
    Future<({int exitCode, String stderr, String stdout})> Function(
      List<String> args, {
      Map<String, String>? environment,
      String? workingDirectory,
    });

/// Default [GitRunner] that runs git via [Isolate.run].
Future<({int exitCode, String stderr, String stdout})> _isolateGitRunner(
  List<String> args, {
  Map<String, String>? environment,
  String? workingDirectory,
}) async {
  // Extract values so only primitives cross the isolate boundary.
  final argsCopy = List<String>.unmodifiable(args);
  final envCopy = environment != null ? Map<String, String>.unmodifiable(environment) : null;
  final wdCopy = workingDirectory;

  return Isolate.run(() async {
    final result = await Process.run('git', argsCopy, environment: envCopy, workingDirectory: wdCopy);
    return (exitCode: result.exitCode, stderr: result.stderr as String, stdout: result.stdout as String);
  });
}

/// Implementation of [ProjectService] for the DartClaw server.
///
/// Manages three project sources:
/// - Config-defined: seeded from [ProjectConfig] on startup, read-only
/// - Runtime-created: created via [create], persisted to `projects.json`
/// - Implicit `_local`: always present, ephemeral, not persisted
class ProjectServiceImpl implements ProjectService {
  final String _dataDir;
  final ProjectConfig _projectConfig;
  final CredentialsConfig _credentials;
  final EventBus? _eventBus;
  final GitRunner _gitRunner;
  final Logger _log;

  /// In-memory project registry keyed by id.
  /// Does NOT include `_local` (accessed via [getLocalProject]).
  final Map<String, Project> _projects = {};

  /// In-flight fetch completers, keyed by project ID.
  ///
  /// Prevents concurrent fetches on the same project.
  final Map<String, Completer<void>> _fetchInFlight = {};

  /// The implicit _local project (ephemeral, not persisted).
  late final Project _localProject;

  /// Temporary askpass script paths to clean up on dispose.
  final List<String> _tempFiles = [];

  /// Cooldown in minutes between automatic fetches.
  final int _fetchCooldownMinutes;

  /// Creates a [ProjectServiceImpl].
  ///
  /// [gitRunner] defaults to [_isolateGitRunner] but can be replaced for testing.
  ProjectServiceImpl({
    required String dataDir,
    required ProjectConfig projectConfig,
    required CredentialsConfig credentials,
    EventBus? eventBus,
    GitRunner? gitRunner,
  }) : _dataDir = dataDir,
       _projectConfig = projectConfig,
       _credentials = credentials,
       _eventBus = eventBus,
       _gitRunner = gitRunner ?? _isolateGitRunner,
       _fetchCooldownMinutes = projectConfig.fetchCooldownMinutes,
       _log = Logger('ProjectService');

  @override
  Future<void> initialize() async {
    // 1. Create implicit _local project.
    _localProject = _createLocalProject();

    // 2. Load runtime projects from projects.json.
    await _loadRuntimeProjects();

    // 3. Seed config-defined projects (config wins on collision).
    await _seedConfigProjects();

    // 4. Recover any stale cloning states from previous run.
    _recoverStaleCloning();

    final configCount = _projects.values.where((p) => p.configDefined).length;
    final runtimeCount = _projects.values.where((p) => !p.configDefined).length;
    _log.info(
      'Projects: ${_projects.length} registered '
      '($configCount from config, $runtimeCount runtime) + _local',
    );
  }

  @override
  Future<Project?> get(String id) async {
    if (id == '_local') return _localProject;
    return _projects[id];
  }

  @override
  Future<List<Project>> getAll() async {
    return [_localProject, ..._projects.values];
  }

  @override
  Project getLocalProject() => _localProject;

  @override
  Future<Project> getDefaultProject() async {
    // 1. Check for explicitly marked default in config.
    for (final project in _projects.values) {
      if (project.configDefined) {
        final def = _projectConfig.definitions[project.id];
        if (def != null && def.isDefault) return project;
      }
    }

    // 2. If external projects exist, return the first one.
    if (_projects.isNotEmpty) {
      return _projects.values.first;
    }

    // 3. Fall back to _local.
    return _localProject;
  }

  @override
  Future<Project> create({
    required String name,
    required String remoteUrl,
    String defaultBranch = 'main',
    String? credentialsRef,
    CloneStrategy cloneStrategy = CloneStrategy.shallow,
    PrConfig pr = const PrConfig.defaults(),
  }) async {
    final id = _generateId(name);

    if (id == '_local') {
      throw ArgumentError('Generated project ID "_local" is reserved — use a different name');
    }
    if (_projects.containsKey(id)) {
      throw ArgumentError('Project with id "$id" already exists');
    }

    final localPath = p.join(_dataDir, 'projects', id);
    final now = DateTime.now();

    final project = Project(
      id: id,
      name: name,
      remoteUrl: remoteUrl,
      localPath: localPath,
      defaultBranch: defaultBranch,
      credentialsRef: credentialsRef,
      cloneStrategy: cloneStrategy,
      pr: pr,
      status: ProjectStatus.cloning,
      createdAt: now,
    );

    _projects[id] = project;
    await _persist();
    _fireStatusChanged(project, null);

    // Clone in Isolate — fire-and-complete asynchronously.
    unawaited(_cloneInIsolate(project));

    return project;
  }

  @override
  Future<Project> update(
    String id, {
    String? name,
    String? remoteUrl,
    String? defaultBranch,
    String? credentialsRef,
    PrConfig? pr,
  }) async {
    final project = _projects[id];
    if (project == null) {
      throw ArgumentError('Project "$id" not found');
    }
    if (project.configDefined) {
      throw StateError('Project "$id" is config-defined and cannot be updated via API');
    }

    final coordinatesChanged =
        (remoteUrl != null && remoteUrl != project.remoteUrl) ||
        (defaultBranch != null && defaultBranch != project.defaultBranch);

    final updated = project.copyWith(
      name: name,
      remoteUrl: remoteUrl,
      defaultBranch: defaultBranch,
      credentialsRef: credentialsRef,
      pr: pr,
    );

    if (!coordinatesChanged) {
      _projects[id] = updated;
      await _persist();
      return updated;
    }

    final recloning = updated.copyWith(status: ProjectStatus.cloning, lastFetchAt: null, errorMessage: null);
    _projects[id] = recloning;
    await _persist();
    _fireStatusChanged(recloning, project.status);

    final dir = Directory(project.localPath);
    if (dir.existsSync()) {
      try {
        dir.deleteSync(recursive: true);
      } catch (e) {
        _log.warning('Failed to delete old clone directory "${project.localPath}" before re-clone: $e');
      }
    }

    unawaited(_cloneInIsolate(recloning));
    return recloning;
  }

  @override
  Future<Project> fetch(String id) async {
    final project = _projects[id];
    if (project == null) throw ArgumentError('Project "$id" not found');

    return _fetchProject(project, bypassCooldown: true);
  }

  @override
  Future<void> ensureFresh(Project project) async {
    // Cooldown check.
    final lastFetch = project.lastFetchAt;
    if (lastFetch != null) {
      final elapsed = DateTime.now().difference(lastFetch);
      if (elapsed < Duration(minutes: _fetchCooldownMinutes)) {
        _log.fine(
          'Skipping fetch for "${project.name}" — '
          'last fetched ${elapsed.inSeconds}s ago (cooldown: ${_fetchCooldownMinutes}m)',
        );
        return;
      }
    }

    // Per-project lock: wait for in-flight fetch if one exists.
    final existing = _fetchInFlight[project.id];
    if (existing != null) {
      _log.fine('Fetch already in flight for "${project.name}" — waiting');
      await existing.future;
      return;
    }

    final completer = Completer<void>();
    _fetchInFlight[project.id] = completer;

    try {
      if (project.id == '_local') {
        await _fetchLocal(project);
      } else {
        await _fetchExternal(project);
      }
      completer.complete();
    } catch (e) {
      _log.warning('Fetch failed for "${project.name}": $e — proceeding with local state');
      completer.complete(); // Complete normally — fetch failure is best-effort.
    } finally {
      _fetchInFlight.remove(project.id);
    }
  }

  Future<void> _fetchExternal(Project project) async {
    final env = _resolveGitEnv(project.remoteUrl, project.credentialsRef);
    final result = await _gitRunner(
      ['fetch', 'origin', project.defaultBranch],
      environment: env,
      workingDirectory: project.localPath,
    );

    if (result.exitCode != 0) {
      _log.warning('git fetch failed for "${project.name}": ${result.stderr}');
      return; // Best-effort — proceed with local state.
    }

    // Update lastFetchAt.
    final updated = project.copyWith(lastFetchAt: DateTime.now());
    _projects[project.id] = updated;
    await _persist();
    _log.info('Fetched latest for "${project.name}" (branch: ${project.defaultBranch})');
  }

  Future<void> _fetchLocal(Project project) async {
    // For _local: attempt fetch + fast-forward merge.
    final fetchResult = await _gitRunner(['fetch', 'origin'], workingDirectory: project.localPath);

    if (fetchResult.exitCode != 0) {
      _log.warning('git fetch failed for _local project: ${fetchResult.stderr}');
      return;
    }

    // Attempt fast-forward merge — never force-reset.
    final mergeResult = await _gitRunner([
      'merge',
      '--ff-only',
      'origin/${project.defaultBranch}',
    ], workingDirectory: project.localPath);

    if (mergeResult.exitCode != 0) {
      _log.warning(
        'Fast-forward merge failed for _local — local branch has diverged. '
        'Proceeding with local state. stderr: ${mergeResult.stderr}',
      );
      return; // Do NOT force-reset — user may have local commits.
    }

    _log.info('Fast-forwarded _local project to origin/${project.defaultBranch}');
  }

  @override
  Future<void> delete(String id) async {
    final project = _projects[id];
    if (project == null) throw ArgumentError('Project "$id" not found');
    if (project.configDefined) {
      throw StateError('Project "$id" is config-defined and cannot be deleted via API');
    }

    _projects.remove(id);
    await _persist();

    // Clean up clone directory.
    final dir = Directory(project.localPath);
    if (dir.existsSync()) {
      try {
        dir.deleteSync(recursive: true);
      } catch (e) {
        _log.warning('Failed to delete clone directory "${project.localPath}": $e');
      }
    }
  }

  @override
  Future<void> dispose() async {
    for (final path in _tempFiles) {
      try {
        File(path).deleteSync();
      } catch (_) {}
    }
    _tempFiles.clear();
  }

  // ---------------------------------------------------------------------------
  // Private helpers
  // ---------------------------------------------------------------------------

  Project _createLocalProject() {
    final cwd = Directory.current.path;
    return Project(
      id: '_local',
      name: _deriveNameFromPath(cwd),
      remoteUrl: '',
      localPath: cwd,
      defaultBranch: 'main',
      status: ProjectStatus.ready,
      configDefined: false,
      createdAt: DateTime.now(),
    );
  }

  Future<void> _loadRuntimeProjects() async {
    final file = File(p.join(_dataDir, 'projects.json'));
    if (!file.existsSync()) return;

    try {
      final content = file.readAsStringSync();
      final raw = jsonDecode(content);
      if (raw is Map<String, dynamic>) {
        for (final entry in raw.entries) {
          try {
            if (entry.value is Map<String, dynamic>) {
              final project = Project.fromJson(entry.value as Map<String, dynamic>);
              _projects[project.id] = project;
            }
          } catch (e) {
            _log.warning('Failed to parse project "${entry.key}" from projects.json: $e');
          }
        }
      }
    } catch (e) {
      _log.warning('Failed to load projects.json: $e');
    }
  }

  Future<void> _seedConfigProjects() async {
    for (final def in _projectConfig.definitions.values) {
      final id = def.id;
      final localPath = p.join(_dataDir, 'projects', id);

      if (_projects.containsKey(id)) {
        _log.warning(
          'Config project "$id" collides with existing runtime project — '
          'discarding runtime entry (config wins)',
        );
        _projects.remove(id);
      }

      final cloneExists = Directory(localPath).existsSync();
      final status = cloneExists ? ProjectStatus.ready : ProjectStatus.cloning;

      final project = Project(
        id: id,
        name: def.id, // Use ID as name for config-defined (no display name in YAML)
        remoteUrl: def.remote,
        localPath: localPath,
        defaultBranch: def.branch,
        credentialsRef: def.credentials,
        cloneStrategy: def.cloneStrategy,
        pr: def.pr,
        status: status,
        configDefined: true,
        createdAt: DateTime.now(),
      );

      _projects[id] = project;

      if (!cloneExists) {
        unawaited(_cloneInIsolate(project));
      }
    }
  }

  void _recoverStaleCloning() {
    bool anyRecovered = false;
    for (final entry in _projects.entries.toList()) {
      if (entry.value.status == ProjectStatus.cloning) {
        _log.warning(
          'Project "${entry.value.name}" has stale cloning status — '
          'clone was interrupted by restart. Resetting to error.',
        );
        _projects[entry.key] = entry.value.copyWith(
          status: ProjectStatus.error,
          errorMessage: 'Clone interrupted by restart — retry via Fetch action.',
        );
        anyRecovered = true;
      }
    }
    if (anyRecovered) {
      unawaited(_persist()); // Fire-and-forget, called from sync context
    }
  }

  Future<void> _cloneInIsolate(Project project) async {
    try {
      final env = _resolveGitEnv(project.remoteUrl, project.credentialsRef);
      final args = _buildCloneArgs(project);

      final result = await _gitRunner(args, environment: env.isEmpty ? null : env);

      if (result.exitCode == 0) {
        // Project may have been deleted while clone was in progress — discard.
        if (!_projects.containsKey(project.id)) return;

        final updated = project.copyWith(status: ProjectStatus.ready, lastFetchAt: DateTime.now(), errorMessage: null);
        _projects[project.id] = updated;
        await _persist();
        _fireStatusChanged(updated, ProjectStatus.cloning);
      } else {
        await _handleCloneFailure(project, result.stderr);
      }
    } catch (e) {
      await _handleCloneFailure(project, e.toString());
    }
  }

  Future<void> _handleCloneFailure(Project project, String message) async {
    _log.warning('Clone failed for project "${project.name}": $message');

    // Clean up partial clone directory.
    final dir = Directory(project.localPath);
    if (dir.existsSync()) {
      try {
        dir.deleteSync(recursive: true);
      } catch (e) {
        _log.fine('Failed to clean up partial clone "${project.localPath}": $e');
      }
    }

    // Only update if the project is still in the registry (not deleted mid-clone).
    if (_projects.containsKey(project.id)) {
      final updated = project.copyWith(
        status: ProjectStatus.error,
        errorMessage: message.length > 500 ? '${message.substring(0, 500)}…' : message,
      );
      _projects[project.id] = updated;
      await _persist();
      _fireStatusChanged(updated, ProjectStatus.cloning);
    }
  }

  Future<Project> _fetchProject(Project project, {required bool bypassCooldown}) async {
    final env = _resolveGitEnv(project.remoteUrl, project.credentialsRef);
    final args = ['fetch', '--prune', 'origin'];

    final result = await _gitRunner(args, environment: env.isEmpty ? null : env, workingDirectory: project.localPath);

    if (result.exitCode == 0) {
      final updated = project.copyWith(status: ProjectStatus.ready, lastFetchAt: DateTime.now(), errorMessage: null);
      if (_projects.containsKey(project.id)) {
        final prev = _projects[project.id]!;
        _projects[project.id] = updated;
        await _persist();
        if (prev.status != ProjectStatus.ready) {
          _fireStatusChanged(updated, prev.status);
        }
      }
      return updated;
    } else {
      throw Exception('git fetch failed: ${result.stderr}');
    }
  }

  List<String> _buildCloneArgs(Project project) {
    return [
      'clone',
      if (project.cloneStrategy == CloneStrategy.shallow) '--depth=1',
      '--branch',
      project.defaultBranch,
      project.remoteUrl,
      project.localPath,
    ];
  }

  /// Resolves git environment variables for credential injection.
  ///
  /// Delegates to the shared [resolveGitCredentialEnv] utility.
  Map<String, String> _resolveGitEnv(String remoteUrl, String? credentialsRef) {
    return resolveGitCredentialEnv(remoteUrl, credentialsRef, _credentials, dataDir: _dataDir, tempFiles: _tempFiles);
  }

  Future<void> _persist() async {
    try {
      final file = File(p.join(_dataDir, 'projects.json'));
      // Only persist runtime-created projects (not config-defined, not _local).
      final registry = <String, dynamic>{
        for (final p in _projects.values.where((p) => !p.configDefined)) p.id: p.toJson(),
      };
      await atomicWriteJson(file, registry);
    } catch (e) {
      _log.severe('Failed to persist projects.json: $e');
    }
  }

  void _fireStatusChanged(Project project, ProjectStatus? oldStatus) {
    _eventBus?.fire(
      ProjectStatusChangedEvent(
        projectId: project.id,
        oldStatus: oldStatus,
        newStatus: project.status,
        timestamp: DateTime.now(),
      ),
    );
  }

  /// Generates a URL-safe, filesystem-safe project ID from a display name.
  String _generateId(String name) {
    return name
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9-]'), '-')
        .replaceAll(RegExp(r'-+'), '-')
        .replaceAll(RegExp(r'^-|-$'), '');
  }

  /// Extracts a display name from the last segment of a file path.
  String _deriveNameFromPath(String path) {
    final segments = p.split(path);
    return segments.isEmpty ? path : segments.last;
  }
}
