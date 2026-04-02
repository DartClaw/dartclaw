import 'package:dartclaw_core/dartclaw_core.dart';

typedef FakeProjectCreateCallback =
    Future<Project> Function({
      required String name,
      required String remoteUrl,
      String defaultBranch,
      String? credentialsRef,
      CloneStrategy cloneStrategy,
      PrConfig pr,
    });

typedef FakeProjectUpdateCallback =
    Future<Project> Function(
      String id, {
      String? name,
      String? remoteUrl,
      String? defaultBranch,
      String? credentialsRef,
      PrConfig? pr,
    });

typedef FakeProjectFetchCallback = Future<Project> Function(String id);
typedef FakeProjectDeleteCallback = Future<void> Function(String id);
typedef FakeProjectEnsureFreshCallback = Future<void> Function(Project project);

typedef RecordedProjectCreate = ({
  String name,
  String remoteUrl,
  String defaultBranch,
  String? credentialsRef,
  CloneStrategy cloneStrategy,
  PrConfig pr,
});

typedef RecordedProjectUpdate = ({
  String id,
  String? name,
  String? remoteUrl,
  String? defaultBranch,
  String? credentialsRef,
  PrConfig? pr,
});

/// In-memory [ProjectService] fake with optional lifecycle callbacks.
class FakeProjectService implements ProjectService {
  FakeProjectService({
    Iterable<Project> projects = const [],
    Project? localProject,
    this.includeLocalProjectInGetAll = true,
    this.defaultProjectId,
    DateTime Function()? now,
    this.onCreate,
    this.onUpdate,
    this.onFetch,
    this.onDelete,
    this.onEnsureFresh,
  }) : _localProject =
           localProject ??
           Project(
             id: '_local',
             name: 'local',
             remoteUrl: '',
             localPath: '/workspace',
             defaultBranch: 'main',
             status: ProjectStatus.ready,
             createdAt: DateTime.parse('2026-01-01T00:00:00Z'),
           ),
       _now = now ?? DateTime.now {
    for (final project in projects) {
      seed(project);
    }
  }

  final bool includeLocalProjectInGetAll;
  final String? defaultProjectId;
  final DateTime Function() _now;
  final FakeProjectCreateCallback? onCreate;
  final FakeProjectUpdateCallback? onUpdate;
  final FakeProjectFetchCallback? onFetch;
  final FakeProjectDeleteCallback? onDelete;
  final FakeProjectEnsureFreshCallback? onEnsureFresh;

  final Project _localProject;
  final Map<String, Project> _projects = {};

  bool initializeCalled = false;
  bool disposeCalled = false;

  final List<String> getCalls = [];
  final List<String> fetchCalls = [];
  final List<String> deleteCalls = [];
  final List<Project> ensureFreshCalls = [];
  final List<RecordedProjectCreate> createCalls = [];
  final List<RecordedProjectUpdate> updateCalls = [];

  /// Adds or replaces a seeded project.
  void seed(Project project) {
    if (project.id == _localProject.id) {
      return;
    }
    _projects[project.id] = project;
  }

  /// Removes a seeded project without validation.
  void remove(String id) {
    _projects.remove(id);
  }

  @override
  Future<Project?> get(String id) async {
    getCalls.add(id);
    if (id == _localProject.id) {
      return _localProject;
    }
    return _projects[id];
  }

  @override
  Future<List<Project>> getAll() async {
    final projects = _projects.values.toList(growable: false);
    if (!includeLocalProjectInGetAll) {
      return projects;
    }
    return [_localProject, ...projects];
  }

  @override
  Future<Project> getDefaultProject() async {
    final configuredDefaultId = defaultProjectId;
    if (configuredDefaultId != null) {
      if (configuredDefaultId == _localProject.id) {
        return _localProject;
      }
      final configuredDefault = _projects[configuredDefaultId];
      if (configuredDefault != null) {
        return configuredDefault;
      }
    }
    if (_projects.isNotEmpty) {
      return _projects.values.first;
    }
    return _localProject;
  }

  @override
  Project getLocalProject() => _localProject;

  @override
  Future<Project> create({
    required String name,
    required String remoteUrl,
    String defaultBranch = 'main',
    String? credentialsRef,
    CloneStrategy cloneStrategy = CloneStrategy.shallow,
    PrConfig pr = const PrConfig.defaults(),
  }) async {
    createCalls.add((
      name: name,
      remoteUrl: remoteUrl,
      defaultBranch: defaultBranch,
      credentialsRef: credentialsRef,
      cloneStrategy: cloneStrategy,
      pr: pr,
    ));
    final callback = onCreate;
    if (callback != null) {
      final project = await callback(
        name: name,
        remoteUrl: remoteUrl,
        defaultBranch: defaultBranch,
        credentialsRef: credentialsRef,
        cloneStrategy: cloneStrategy,
        pr: pr,
      );
      seed(project);
      return project;
    }

    final id = _slugify(name);
    if (id == _localProject.id) {
      throw ArgumentError('Reserved ID "$id"');
    }
    if (_projects.containsKey(id)) {
      throw ArgumentError('Project "$id" already exists');
    }
    final project = Project(
      id: id,
      name: name,
      remoteUrl: remoteUrl,
      localPath: '/data/projects/$id',
      defaultBranch: defaultBranch,
      credentialsRef: credentialsRef,
      cloneStrategy: cloneStrategy,
      pr: pr,
      status: ProjectStatus.cloning,
      createdAt: _now(),
    );
    _projects[id] = project;
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
    updateCalls.add((
      id: id,
      name: name,
      remoteUrl: remoteUrl,
      defaultBranch: defaultBranch,
      credentialsRef: credentialsRef,
      pr: pr,
    ));
    final callback = onUpdate;
    if (callback != null) {
      final project = await callback(
        id,
        name: name,
        remoteUrl: remoteUrl,
        defaultBranch: defaultBranch,
        credentialsRef: credentialsRef,
        pr: pr,
      );
      seed(project);
      return project;
    }

    final existing = _projects[id] ?? (throw ArgumentError('Not found: $id'));
    if (existing.configDefined) {
      throw StateError('Config-defined project $id');
    }
    final remoteChanging = remoteUrl != null && remoteUrl != existing.remoteUrl;
    final branchChanging = defaultBranch != null && defaultBranch != existing.defaultBranch;
    final updated = existing.copyWith(
      name: name,
      remoteUrl: remoteUrl,
      defaultBranch: defaultBranch,
      credentialsRef: credentialsRef,
      pr: pr,
      status: (remoteChanging || branchChanging) ? ProjectStatus.cloning : existing.status,
      lastFetchAt: (remoteChanging || branchChanging) ? null : existing.lastFetchAt,
      errorMessage: (remoteChanging || branchChanging) ? null : existing.errorMessage,
    );
    _projects[id] = updated;
    return updated;
  }

  @override
  Future<Project> fetch(String id) async {
    fetchCalls.add(id);
    final callback = onFetch;
    if (callback != null) {
      final project = await callback(id);
      seed(project);
      return project;
    }

    final existing = _projects[id] ?? (throw ArgumentError('Not found: $id'));
    final updated = existing.copyWith(status: ProjectStatus.ready, lastFetchAt: _now(), errorMessage: null);
    _projects[id] = updated;
    return updated;
  }

  @override
  Future<void> ensureFresh(Project project) async {
    ensureFreshCalls.add(project);
    await onEnsureFresh?.call(project);
  }

  @override
  Future<void> delete(String id) async {
    deleteCalls.add(id);
    final callback = onDelete;
    if (callback != null) {
      await callback(id);
      _projects.remove(id);
      return;
    }
    final existing = _projects[id] ?? (throw ArgumentError('Not found: $id'));
    if (existing.configDefined) {
      throw StateError('Config-defined project $id');
    }
    _projects.remove(id);
  }

  @override
  Future<void> initialize() async {
    initializeCalled = true;
  }

  @override
  Future<void> dispose() async {
    disposeCalled = true;
  }

  String _slugify(String input) {
    final slug = input
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9-]+'), '-')
        .replaceAll(RegExp(r'-+'), '-')
        .replaceAll(RegExp(r'^-|-$'), '');
    return slug.isEmpty ? 'project' : slug;
  }
}
