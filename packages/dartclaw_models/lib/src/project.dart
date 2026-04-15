const _projectFieldUnset = Object();

/// Project auth probe details surfaced to operators.
class ProjectAuthStatus {
  /// Resolved repository identity, usually `owner/repo`.
  final String? repository;

  /// Credential reference used for the probe.
  final String? credentialsRef;

  /// Resolved credential type.
  final String? credentialType;

  /// Whether the credential and repository are currently compatible.
  final bool compatible;

  /// Last time this auth status was checked.
  final DateTime? checkedAt;

  /// Machine-readable auth/probe error code.
  final String? errorCode;

  /// Human-readable auth/probe error.
  final String? errorMessage;

  const ProjectAuthStatus({
    this.repository,
    this.credentialsRef,
    this.credentialType,
    required this.compatible,
    this.checkedAt,
    this.errorCode,
    this.errorMessage,
  });

  Map<String, dynamic> toJson() => {
    'compatible': compatible,
    if (repository != null) 'repository': repository,
    if (credentialsRef != null) 'credentialsRef': credentialsRef,
    if (credentialType != null) 'credentialType': credentialType,
    if (checkedAt != null) 'checkedAt': checkedAt!.toIso8601String(),
    if (errorCode != null) 'errorCode': errorCode,
    if (errorMessage != null) 'errorMessage': errorMessage,
  };

  factory ProjectAuthStatus.fromJson(Map<String, dynamic> json) => ProjectAuthStatus(
    repository: json['repository'] as String?,
    credentialsRef: json['credentialsRef'] as String?,
    credentialType: json['credentialType'] as String?,
    compatible: json['compatible'] as bool? ?? false,
    checkedAt: _parseDateTime(json['checkedAt']),
    errorCode: json['errorCode'] as String?,
    errorMessage: json['errorMessage'] as String?,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ProjectAuthStatus &&
          repository == other.repository &&
          credentialsRef == other.credentialsRef &&
          credentialType == other.credentialType &&
          compatible == other.compatible &&
          checkedAt == other.checkedAt &&
          errorCode == other.errorCode &&
          errorMessage == other.errorMessage;

  @override
  int get hashCode =>
      Object.hash(repository, credentialsRef, credentialType, compatible, checkedAt, errorCode, errorMessage);
}

/// Lifecycle states for project management.
enum ProjectStatus {
  /// Clone operation is in progress.
  cloning,

  /// Clone is complete and up to date.
  ready,

  /// Clone failed or is in an error state.
  error,

  /// Clone exists but has not been fetched recently.
  stale,
}

/// Git clone depth strategy.
enum CloneStrategy {
  /// Shallow clone with depth 1.
  shallow,

  /// Full clone with complete history.
  full,

  /// Sparse checkout (reserved for future work).
  sparse,
}

/// Strategy for delivering accepted task results.
enum PrStrategy {
  /// Push branch only, no PR creation.
  branchOnly,

  /// Push branch and create a GitHub PR via DartClaw's GitHub API integration.
  githubPr;

  /// Parses a YAML or JSON string to [PrStrategy].
  ///
  /// Accepts both hyphenated (`branch-only`, `github-pr`) and camelCase
  /// (`branchOnly`, `githubPr`) forms. Returns [branchOnly] for unknown values.
  static PrStrategy fromYaml(Object? value) {
    if (value is! String) return PrStrategy.branchOnly;
    return switch (value) {
      'branch-only' || 'branchOnly' => PrStrategy.branchOnly,
      'github-pr' || 'githubPr' => PrStrategy.githubPr,
      _ => PrStrategy.branchOnly,
    };
  }
}

/// Per-project PR creation configuration.
class PrConfig {
  /// PR delivery strategy.
  final PrStrategy strategy;

  /// Whether to create PRs as drafts.
  final bool draft;

  /// Labels to auto-apply to created PRs.
  final List<String> labels;

  const PrConfig({this.strategy = PrStrategy.branchOnly, this.draft = false, this.labels = const []});

  const PrConfig.defaults() : this();

  Map<String, dynamic> toJson() => {'strategy': strategy.name, 'draft': draft, if (labels.isNotEmpty) 'labels': labels};

  factory PrConfig.fromJson(Map<String, dynamic> json) => PrConfig(
    strategy: PrStrategy.fromYaml(json['strategy']),
    draft: json['draft'] as bool? ?? false,
    labels: (json['labels'] as List?)?.cast<String>() ?? const [],
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PrConfig &&
          strategy == other.strategy &&
          draft == other.draft &&
          labels.length == other.labels.length &&
          _listsEqual(labels, other.labels);

  @override
  int get hashCode => Object.hash(strategy, draft, Object.hashAll(labels));

  @override
  String toString() => 'PrConfig(strategy: ${strategy.name}, draft: $draft, labels: $labels)';
}

bool _listsEqual(List<String> a, List<String> b) {
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// A named pointer to an external git repository with clone/push/PR config.
///
/// Immutable value object — create modified copies via [copyWith].
/// Config-defined projects have [configDefined] = true and are read-only
/// via the API. Runtime-created projects are fully mutable.
class Project {
  /// Unique identifier. Config-defined projects use the YAML key.
  /// Runtime-created projects use a generated slug.
  /// The value `_local` is reserved for the implicit local project.
  final String id;

  /// Human-readable display name.
  final String name;

  /// Git remote URL (SSH or HTTPS). Empty string for the implicit _local project.
  final String remoteUrl;

  /// Local filesystem path to the clone directory.
  final String localPath;

  /// Default branch to track and branch from.
  final String defaultBranch;

  /// Reference to a credential name in CredentialsConfig.
  /// Resolved at clone/fetch/push time — never stored as a secret value.
  final String? credentialsRef;

  /// Clone depth strategy.
  final CloneStrategy cloneStrategy;

  /// PR creation configuration.
  final PrConfig pr;

  /// Current lifecycle status.
  final ProjectStatus status;

  /// When the clone was last fetched from remote, or null if never fetched.
  final DateTime? lastFetchAt;

  /// Whether this project was defined in dartclaw.yaml (read-only via API).
  final bool configDefined;

  /// Error message when status is [ProjectStatus.error].
  final String? errorMessage;

  /// Current auth/preflight metadata for the project.
  final ProjectAuthStatus? auth;

  /// When this project record was created.
  final DateTime createdAt;

  /// Creates an immutable project record.
  const Project({
    required this.id,
    required this.name,
    required this.remoteUrl,
    required this.localPath,
    this.defaultBranch = 'main',
    this.credentialsRef,
    this.cloneStrategy = CloneStrategy.shallow,
    this.pr = const PrConfig.defaults(),
    this.status = ProjectStatus.cloning,
    this.lastFetchAt,
    this.configDefined = false,
    this.errorMessage,
    this.auth,
    required this.createdAt,
  });

  /// Returns a new project with selected fields replaced.
  Project copyWith({
    String? id,
    String? name,
    String? remoteUrl,
    String? localPath,
    String? defaultBranch,
    Object? credentialsRef = _projectFieldUnset,
    CloneStrategy? cloneStrategy,
    PrConfig? pr,
    ProjectStatus? status,
    Object? lastFetchAt = _projectFieldUnset,
    bool? configDefined,
    Object? errorMessage = _projectFieldUnset,
    Object? auth = _projectFieldUnset,
    DateTime? createdAt,
  }) => Project(
    id: id ?? this.id,
    name: name ?? this.name,
    remoteUrl: remoteUrl ?? this.remoteUrl,
    localPath: localPath ?? this.localPath,
    defaultBranch: defaultBranch ?? this.defaultBranch,
    credentialsRef: identical(credentialsRef, _projectFieldUnset) ? this.credentialsRef : credentialsRef as String?,
    cloneStrategy: cloneStrategy ?? this.cloneStrategy,
    pr: pr ?? this.pr,
    status: status ?? this.status,
    lastFetchAt: identical(lastFetchAt, _projectFieldUnset) ? this.lastFetchAt : lastFetchAt as DateTime?,
    configDefined: configDefined ?? this.configDefined,
    errorMessage: identical(errorMessage, _projectFieldUnset) ? this.errorMessage : errorMessage as String?,
    auth: identical(auth, _projectFieldUnset) ? this.auth : auth as ProjectAuthStatus?,
    createdAt: createdAt ?? this.createdAt,
  );

  /// Serializes this project to JSON.
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'remoteUrl': remoteUrl,
    'localPath': localPath,
    'defaultBranch': defaultBranch,
    if (credentialsRef != null) 'credentialsRef': credentialsRef,
    'cloneStrategy': cloneStrategy.name,
    'pr': pr.toJson(),
    'status': status.name,
    if (lastFetchAt != null) 'lastFetchAt': lastFetchAt!.toIso8601String(),
    'configDefined': configDefined,
    if (errorMessage != null) 'errorMessage': errorMessage,
    if (auth != null) 'auth': auth!.toJson(),
    'createdAt': createdAt.toIso8601String(),
  };

  /// Deserializes a project from JSON.
  factory Project.fromJson(Map<String, dynamic> json) => Project(
    id: json['id'] as String,
    name: json['name'] as String,
    remoteUrl: json['remoteUrl'] as String,
    localPath: json['localPath'] as String,
    defaultBranch: json['defaultBranch'] as String? ?? 'main',
    credentialsRef: json['credentialsRef'] as String?,
    cloneStrategy: _parseCloneStrategy(json['cloneStrategy']),
    pr: json['pr'] is Map<String, dynamic>
        ? PrConfig.fromJson(json['pr'] as Map<String, dynamic>)
        : const PrConfig.defaults(),
    status: _parseProjectStatus(json['status']),
    lastFetchAt: _parseDateTime(json['lastFetchAt']),
    configDefined: json['configDefined'] as bool? ?? false,
    errorMessage: json['errorMessage'] as String?,
    auth: json['auth'] is Map<String, dynamic>
        ? ProjectAuthStatus.fromJson(json['auth'] as Map<String, dynamic>)
        : null,
    createdAt: DateTime.parse(json['createdAt'] as String),
  );

  @override
  String toString() =>
      'Project(id: $id, name: $name, status: ${status.name}, '
      'remoteUrl: ${remoteUrl.isEmpty ? "<local>" : remoteUrl})';
}

ProjectStatus _parseProjectStatus(Object? value) {
  if (value is String) {
    return ProjectStatus.values.asNameMap()[value] ?? ProjectStatus.error;
  }
  return ProjectStatus.error;
}

CloneStrategy _parseCloneStrategy(Object? value) {
  if (value is String) {
    return CloneStrategy.values.asNameMap()[value] ?? CloneStrategy.shallow;
  }
  return CloneStrategy.shallow;
}

DateTime? _parseDateTime(Object? value) {
  if (value is String) return DateTime.parse(value);
  return null;
}
