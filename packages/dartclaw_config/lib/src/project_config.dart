import 'package:collection/collection.dart';
import 'package:dartclaw_models/dartclaw_models.dart' show CloneStrategy, PrConfig, PrStrategy;

/// Per-project definition from dartclaw.yaml.
class ProjectDefinition {
  /// Project ID — the YAML map key under `projects:`.
  final String id;

  /// Git remote URL (SSH or HTTPS).
  final String remote;

  /// Default branch to track and branch from.
  final String branch;

  /// Optional reference to a credential name in `credentials:` section.
  final String? credentials;

  /// Clone depth strategy.
  final CloneStrategy cloneStrategy;

  /// PR creation configuration.
  final PrConfig pr;

  /// Whether this project should be the default when no projectId is specified.
  final bool isDefault;

  const ProjectDefinition({
    required this.id,
    required this.remote,
    this.branch = 'main',
    this.credentials,
    this.cloneStrategy = CloneStrategy.shallow,
    this.pr = const PrConfig.defaults(),
    this.isDefault = false,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ProjectDefinition &&
          id == other.id &&
          remote == other.remote &&
          branch == other.branch &&
          credentials == other.credentials &&
          cloneStrategy == other.cloneStrategy &&
          pr == other.pr &&
          isDefault == other.isDefault;

  @override
  int get hashCode => Object.hash(id, remote, branch, credentials, cloneStrategy, pr, isDefault);
}

/// Configuration for the projects subsystem.
///
/// Parsed from the `projects:` YAML section. Config-defined projects are
/// read-only via the API — they can only be modified via config file changes
/// and a server restart.
class ProjectConfig {
  /// Project definitions from dartclaw.yaml, keyed by project ID.
  final Map<String, ProjectDefinition> definitions;

  /// Minutes between automatic fetches when `ensureFresh()` is called.
  ///
  /// Within this window, repeated `ensureFresh()` calls skip the git fetch.
  /// Default: 5.
  final int fetchCooldownMinutes;

  const ProjectConfig({this.definitions = const {}, this.fetchCooldownMinutes = 5});

  const ProjectConfig.defaults() : this();

  /// Whether any projects are configured.
  bool get isEmpty => definitions.isEmpty;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ProjectConfig &&
          fetchCooldownMinutes == other.fetchCooldownMinutes &&
          const MapEquality<String, ProjectDefinition>().equals(definitions, other.definitions);

  @override
  int get hashCode =>
      Object.hash(fetchCooldownMinutes, const MapEquality<String, ProjectDefinition>().hash(definitions));

  @override
  String toString() => 'ProjectConfig(definitions: ${definitions.keys.toList()})';
}

/// Parses the `projects:` YAML section into a [ProjectConfig].
///
/// Returns [ProjectConfig.defaults] if the section is absent or null.
/// Invalid entries are warned and skipped rather than throwing.
ProjectConfig parseProjectConfig(Map<String, dynamic>? projectsMap, List<String> warns) {
  if (projectsMap == null || projectsMap.isEmpty) return const ProjectConfig.defaults();

  final definitions = <String, ProjectDefinition>{};

  // Parse top-level scalar: fetchCooldownMinutes
  int fetchCooldownMinutes = 5;
  final cooldownRaw = projectsMap['fetchCooldownMinutes'];
  if (cooldownRaw is int) {
    fetchCooldownMinutes = cooldownRaw;
  } else if (cooldownRaw != null) {
    warns.add('projects.fetchCooldownMinutes: expected an integer — using default 5');
  }

  for (final entry in projectsMap.entries) {
    final id = entry.key;

    // Skip top-level scalar keys (not project definitions).
    if (id == 'fetchCooldownMinutes') continue;

    if (id == '_local') {
      warns.add('projects: "_local" is a reserved project ID — skipping');
      continue;
    }

    final raw = entry.value;
    if (raw is! Map) {
      warns.add('projects.$id: expected a map — skipping');
      continue;
    }
    final projectMap = Map<String, dynamic>.from(raw);

    final remote = projectMap['remote'];
    if (remote is! String || remote.isEmpty) {
      warns.add('projects.$id: "remote" is required and must be a non-empty string — skipping');
      continue;
    }

    final branch = projectMap['branch'] is String ? projectMap['branch'] as String : 'main';
    final credentials = projectMap['credentials'] is String ? projectMap['credentials'] as String : null;
    final isDefault = projectMap['default'] is bool ? projectMap['default'] as bool : false;

    // Parse clone strategy
    CloneStrategy cloneStrategy = CloneStrategy.shallow;
    final cloneRaw = projectMap['clone'];
    if (cloneRaw is Map) {
      final strategyRaw = cloneRaw['strategy'];
      if (strategyRaw is String) {
        final parsed = CloneStrategy.values.asNameMap()[strategyRaw];
        if (parsed != null) {
          cloneStrategy = parsed;
        } else {
          warns.add('projects.$id: unknown clone.strategy "$strategyRaw" — using "shallow"');
        }
      }
    }

    // Parse PR config
    PrConfig pr = const PrConfig.defaults();
    final prRaw = projectMap['pr'];
    if (prRaw is Map) {
      final prMap = Map<String, dynamic>.from(prRaw);
      final strategy = PrStrategy.fromYaml(prMap['strategy']);
      final draft = prMap['draft'] is bool ? prMap['draft'] as bool : false;
      final labels = (prMap['labels'] as List?)?.whereType<String>().toList() ?? const <String>[];
      pr = PrConfig(strategy: strategy, draft: draft, labels: labels);
    }

    definitions[id] = ProjectDefinition(
      id: id,
      remote: remote,
      branch: branch,
      credentials: credentials,
      cloneStrategy: cloneStrategy,
      pr: pr,
      isDefault: isDefault,
    );
  }

  return ProjectConfig(definitions: definitions, fetchCooldownMinutes: fetchCooldownMinutes);
}
