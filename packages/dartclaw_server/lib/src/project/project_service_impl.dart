import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:dartclaw_core/dartclaw_core.dart'
    show EventBus, ProjectService, ProjectStatusChangedEvent, atomicWriteJson;
import 'package:dartclaw_security/dartclaw_security.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import 'project_auth_support.dart';
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
    final result = await SafeProcess.git(
      argsCopy,
      plan: _InlineProcessEnvironmentPlan(envCopy),
      workingDirectory: wdCopy,
    );
    return (exitCode: result.exitCode, stderr: result.stderr as String, stdout: result.stdout as String);
  });
}

final class _InlineProcessEnvironmentPlan implements ProcessEnvironmentPlan {
  @override
  final Map<String, String> environment;

  const _InlineProcessEnvironmentPlan(Map<String, String>? environment)
    : environment = environment ?? const <String, String>{};
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
  final HttpClient Function() _httpClientFactory;
  final GitHubProbeRunner? _gitHubProbeRunner;
  final Logger _log;

  /// In-memory project registry keyed by id.
  /// Does NOT include `_local` (accessed via [getLocalProject]).
  final Map<String, Project> _projects = {};

  /// In-flight fetch/validation completers, keyed by project+ref+strictness.
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
    HttpClient Function()? httpClientFactory,
    GitHubProbeRunner? gitHubProbeRunner,
  }) : _dataDir = dataDir,
       _projectConfig = projectConfig,
       _credentials = credentials,
       _eventBus = eventBus,
       _gitRunner = gitRunner ?? _isolateGitRunner,
       _httpClientFactory = httpClientFactory ?? HttpClient.new,
       _gitHubProbeRunner = gitHubProbeRunner,
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
    String? remoteUrl,
    String? localPath,
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

    final hasRemote = remoteUrl != null && remoteUrl.isNotEmpty;
    final hasLocalPath = localPath != null && localPath.isNotEmpty;
    if (hasRemote == hasLocalPath) {
      throw ArgumentError('Exactly one of remoteUrl or localPath must be provided');
    }

    final effectiveLocalPath = localPath ?? p.join(_dataDir, 'projects', id);
    final now = DateTime.now();

    final project = Project(
      id: id,
      name: name,
      remoteUrl: remoteUrl ?? '',
      localPath: effectiveLocalPath,
      defaultBranch: defaultBranch,
      credentialsRef: credentialsRef,
      cloneStrategy: cloneStrategy,
      pr: pr,
      status: hasLocalPath ? ProjectStatus.ready : ProjectStatus.cloning,
      createdAt: now,
    );

    if (hasLocalPath) {
      _projects[id] = project;
      await _persist();
      return project;
    }

    final prepared = await _requireCompatibleAuth(project);

    _projects[id] = prepared;
    await _persist();
    _fireStatusChanged(prepared, null);

    // Clone in Isolate — fire-and-complete asynchronously.
    unawaited(_cloneInIsolate(prepared));

    return prepared;
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
    final prepared = await _requireCompatibleAuth(updated);

    if (!coordinatesChanged) {
      _projects[id] = prepared;
      await _persist();
      return prepared;
    }

    final recloning = prepared.copyWith(status: ProjectStatus.cloning, lastFetchAt: null, errorMessage: null);
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
    final prepared = await _requireCompatibleAuth(project, persistFailure: true);

    return _fetchProject(prepared, bypassCooldown: true);
  }

  @override
  Future<void> ensureFresh(Project project, {String? ref, bool strict = false}) async {
    if (project.remoteUrl.isEmpty) {
      return;
    }

    final effectiveRef = ref?.trim();
    final bypassCooldown = effectiveRef != null && effectiveRef.isNotEmpty;
    final inFlightKey = _fetchInFlightKey(project.id, effectiveRef, strict);

    // Cooldown check.
    final lastFetch = project.lastFetchAt;
    if (!bypassCooldown && lastFetch != null) {
      final elapsed = DateTime.now().difference(lastFetch);
      if (elapsed < Duration(minutes: _fetchCooldownMinutes)) {
        _log.fine(
          'Skipping fetch for "${project.name}" — '
          'last fetched ${elapsed.inSeconds}s ago (cooldown: ${_fetchCooldownMinutes}m)',
        );
        return;
      }
    }

    // Ref-aware lock: wait for in-flight fetch/validation for the same target.
    final existing = _fetchInFlight[inFlightKey];
    if (existing != null) {
      _log.fine('Fetch already in flight for "${project.name}" — waiting');
      await existing.future;
      return;
    }

    final completer = Completer<void>();
    _fetchInFlight[inFlightKey] = completer;
    // Prevent unhandled async errors when strict mode fails without concurrent waiters.
    unawaited(completer.future.catchError((_) {}));

    try {
      await _fetchExternal(project, ref: effectiveRef, strict: strict);
      completer.complete();
    } catch (e) {
      if (strict) {
        completer.completeError(e);
        rethrow;
      }
      _log.warning('Fetch failed for "${project.name}": $e — proceeding with local state');
      completer.complete(); // Complete normally — fetch failure is best-effort.
    } finally {
      _fetchInFlight.remove(inFlightKey);
    }
  }

  @override
  Future<String> resolveWorkflowBaseRef(Project project, {String? requestedBranch}) async {
    final requested = requestedBranch?.trim();
    if (requested != null && requested.isNotEmpty) {
      return requested;
    }

    final configured = project.defaultBranch.trim();
    if (configured.isNotEmpty) {
      return configured;
    }

    if (project.remoteUrl.isEmpty) {
      final observed = await _resolveSymbolicHeadBranch(project.localPath);
      if (observed != null && observed.isNotEmpty) {
        return observed;
      }
    }

    return 'main';
  }

  Future<void> _fetchExternal(Project project, {String? ref, bool strict = false}) async {
    final prepared = await _requireCompatibleAuth(project, persistFailure: strict || project.configDefined);
    final targetRef = _normalizeExternalRef(ref, defaultBranch: project.defaultBranch);
    final plan = _resolveGitPlan(project.remoteUrl, project.credentialsRef);
    final result = await _gitRunner(
      _buildRemoteOverrideArgs(project.remoteUrl, plan.remoteUrl, ['fetch', 'origin', targetRef]),
      environment: plan.environment,
      workingDirectory: project.localPath,
    );

    if (result.exitCode != 0) {
      final message = 'git fetch failed for "${project.name}" (ref: $targetRef): ${result.stderr}';
      if (strict) {
        throw StateError(message);
      }
      _log.warning(message);
      return; // Best-effort — proceed with local state.
    }

    // Update lastFetchAt.
    final updated = prepared.copyWith(lastFetchAt: DateTime.now(), status: ProjectStatus.ready, errorMessage: null);
    _projects[project.id] = updated;
    await _persist();
    _log.info('Fetched latest for "${project.name}" (ref: $targetRef)');
  }

  String _normalizeExternalRef(String? ref, {required String defaultBranch}) {
    if (ref == null || ref.isEmpty) return defaultBranch;
    if (ref.startsWith('origin/')) {
      final trimmed = ref.substring('origin/'.length).trim();
      return trimmed.isEmpty ? defaultBranch : trimmed;
    }
    return ref;
  }

  String _fetchInFlightKey(String projectId, String? ref, bool strict) {
    final normalizedRef = (ref == null || ref.isEmpty) ? '<default>' : ref;
    final strictness = strict ? 'strict' : 'best-effort';
    return '$projectId::$normalizedRef::$strictness';
  }

  Future<String?> _resolveSymbolicHeadBranch(String workingDirectory) async {
    final result = await _gitRunner(['symbolic-ref', '--quiet', '--short', 'HEAD'], workingDirectory: workingDirectory);
    if (result.exitCode != 0) {
      return null;
    }
    final stdout = result.stdout.trim();
    return stdout.isEmpty ? null : stdout;
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
      final localPath = def.localPath ?? p.join(_dataDir, 'projects', id);

      if (_projects.containsKey(id)) {
        _log.warning(
          'Config project "$id" collides with existing runtime project — '
          'discarding runtime entry (config wins)',
        );
        _projects.remove(id);
      }

      if (def.localPath != null) {
        final project = Project(
          id: id,
          name: def.id,
          remoteUrl: '',
          localPath: localPath,
          defaultBranch: def.branch,
          credentialsRef: def.credentials,
          cloneStrategy: def.cloneStrategy,
          pr: def.pr,
          status: ProjectStatus.ready,
          configDefined: true,
          createdAt: DateTime.now(),
        );
        _projects[id] = project;
        continue;
      }

      final cloneExists = Directory(localPath).existsSync();
      var project = Project(
        id: id,
        name: def.id, // Use ID as name for config-defined (no display name in YAML)
        remoteUrl: def.remote!,
        localPath: localPath,
        defaultBranch: def.branch,
        credentialsRef: def.credentials,
        cloneStrategy: def.cloneStrategy,
        pr: def.pr,
        status: cloneExists ? ProjectStatus.ready : ProjectStatus.cloning,
        configDefined: true,
        createdAt: DateTime.now(),
      );
      final auth = await probeProjectAuth(
        project,
        _credentials,
        httpClientFactory: _httpClientFactory,
        probeRunner: _gitHubProbeRunner,
      );
      project = project.copyWith(
        auth: auth,
        status: auth != null && !auth.compatible ? ProjectStatus.error : project.status,
        errorMessage: auth != null && !auth.compatible ? auth.errorMessage : null,
      );

      _projects[id] = project;

      if (!cloneExists && (project.auth == null || project.auth!.compatible)) {
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
      final plan = _resolveGitPlan(project.remoteUrl, project.credentialsRef);
      final args = _buildCloneArgs(project, plan.remoteUrl);

      final result = await _gitRunner(args, environment: plan.environment);

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
    if (project.remoteUrl.isEmpty) {
      return project;
    }

    final prepared = await _requireCompatibleAuth(project, persistFailure: true);
    final plan = _resolveGitPlan(project.remoteUrl, project.credentialsRef);
    final args = _buildRemoteOverrideArgs(project.remoteUrl, plan.remoteUrl, ['fetch', '--prune', 'origin']);

    final result = await _gitRunner(args, environment: plan.environment, workingDirectory: project.localPath);

    if (result.exitCode == 0) {
      final updated = prepared.copyWith(status: ProjectStatus.ready, lastFetchAt: DateTime.now(), errorMessage: null);
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

  List<String> _buildCloneArgs(Project project, String remoteUrl) {
    return [
      'clone',
      if (project.cloneStrategy == CloneStrategy.shallow) '--depth=1',
      '--branch',
      project.defaultBranch,
      remoteUrl,
      project.localPath,
    ];
  }

  GitCredentialPlan _resolveGitPlan(String remoteUrl, String? credentialsRef) {
    return resolveGitCredentialPlan(remoteUrl, credentialsRef, _credentials, dataDir: _dataDir, tempFiles: _tempFiles);
  }

  List<String> _buildRemoteOverrideArgs(String originalRemoteUrl, String resolvedRemoteUrl, List<String> gitArgs) {
    if (originalRemoteUrl.trim().isEmpty || originalRemoteUrl == resolvedRemoteUrl) {
      return gitArgs;
    }
    return ['-c', 'remote.origin.url=$resolvedRemoteUrl', ...gitArgs];
  }

  Future<Project> _requireCompatibleAuth(Project project, {bool persistFailure = false}) async {
    final auth = await probeProjectAuth(
      project,
      _credentials,
      httpClientFactory: _httpClientFactory,
      probeRunner: _gitHubProbeRunner,
    );
    final updated = project.copyWith(
      auth: auth,
      errorMessage: auth != null && !auth.compatible ? auth.errorMessage : null,
    );
    if (auth != null && !auth.compatible) {
      if (persistFailure && _projects.containsKey(project.id)) {
        final failed = updated.copyWith(status: ProjectStatus.error);
        final previous = _projects[project.id]!;
        _projects[project.id] = failed;
        await _persist();
        if (previous.status != failed.status) {
          _fireStatusChanged(failed, previous.status);
        }
      }
      throw ProjectAuthException(auth);
    }
    return updated;
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
