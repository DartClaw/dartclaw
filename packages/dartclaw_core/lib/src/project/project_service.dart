import 'package:dartclaw_models/dartclaw_models.dart' show CloneStrategy, PrConfig, Project, ProjectStatus;

/// Service for managing external project repositories.
///
/// Interface in dartclaw_core; implementation in dartclaw_server.
/// Manages three sources:
/// - Config-defined projects — seeded from `projects:` YAML on startup, read-only
/// - Runtime-created projects — created via [create], persisted to `projects.json`
/// - Implicit `_local` project — always present, ephemeral, not persisted
abstract class ProjectService {
  /// Returns the project with [id], or null if not found.
  ///
  /// Includes the implicit `_local` project.
  Future<Project?> get(String id);

  /// Returns all registered projects (config-defined + runtime-created + implicit `_local`).
  Future<List<Project>> getAll();

  /// Creates a new project and initiates clone. Returns the project in [ProjectStatus.cloning].
  ///
  /// Clone runs in an Isolate — the returned project's status transitions
  /// to [ProjectStatus.ready] or [ProjectStatus.error] asynchronously.
  ///
  /// Throws [ArgumentError] if the derived ID conflicts with an existing project
  /// or uses the reserved `_local` ID.
  Future<Project> create({
    required String name,
    required String remoteUrl,
    String defaultBranch = 'main',
    String? credentialsRef,
    CloneStrategy cloneStrategy = CloneStrategy.shallow,
    PrConfig pr = const PrConfig.defaults(),
  });

  /// Updates a runtime-created project's mutable fields.
  ///
  /// Throws [StateError] if the project is config-defined (read-only).
  /// [remoteUrl] / [defaultBranch] changes trigger a fresh clone lifecycle
  /// when no active tasks exist on the project (enforcement left to the API
  /// layer).
  Future<Project> update(
    String id, {
    String? name,
    String? remoteUrl,
    String? defaultBranch,
    String? credentialsRef,
    PrConfig? pr,
  });

  /// Fetches the latest commits from the remote for the given project.
  ///
  /// Bypasses any cooldown — always triggers a real `git fetch`.
  /// Used by the `POST /api/projects/<id>/fetch` endpoint (S04).
  Future<Project> fetch(String id);

  /// Ensures the project clone is fresh, fetching if the cooldown has elapsed.
  ///
  /// Respects a configurable cooldown — if the project was fetched within
  /// the cooldown window, the fetch is skipped. Concurrent calls on the
  /// same project are serialized: the second caller waits for the first
  /// fetch to complete rather than triggering a parallel fetch.
  ///
  /// For the implicit _local project: runs `git fetch` + `git merge --ff-only`.
  /// For external projects: runs `git fetch origin <defaultBranch>`.
  ///
  /// Network failures are best-effort: logs a warning, does not throw.
  /// The caller should proceed with the local state.
  Future<void> ensureFresh(Project project);

  /// Deletes a runtime-created project.
  ///
  /// Throws [StateError] if the project is config-defined.
  /// Clone directory is removed. Any in-progress clone Isolate completes
  /// naturally — its result is discarded.
  Future<void> delete(String id);

  /// Returns the default project — used when no `projectId` is specified.
  ///
  /// Resolution order:
  /// 1. First config-defined project with `default: true`
  /// 2. First registered external project (config-defined or runtime)
  /// 3. Implicit `_local` project as fallback
  Future<Project> getDefaultProject();

  /// Returns the implicit `_local` project.
  ///
  /// The `_local` project represents `Directory.current.path`. It is always
  /// [ProjectStatus.ready] and is never persisted to `projects.json`.
  Project getLocalProject();

  /// Initializes the service: loads `projects.json`, reconciles with config,
  /// recovers stale cloning states.
  ///
  /// Must be called once during server startup before any other method.
  Future<void> initialize();

  /// Releases any resources held by the service.
  Future<void> dispose();
}
