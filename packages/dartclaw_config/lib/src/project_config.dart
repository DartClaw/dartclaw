import 'dart:io';

import 'package:collection/collection.dart';
import 'package:dartclaw_models/dartclaw_models.dart' show CloneStrategy, PrConfig, PrStrategy;
import 'package:path/path.dart' as p;

/// Validation result for a configured or API-supplied local project path.
class LocalProjectPathValidation {
  final String normalizedPath;
  final String? errorCode;
  final String? errorMessage;
  final bool pathExists;
  final bool gitRepository;

  const LocalProjectPathValidation({
    required this.normalizedPath,
    this.errorCode,
    this.errorMessage,
    required this.pathExists,
    required this.gitRepository,
  });

  bool get isValid => errorCode == null;
}

/// Validates a local project path and returns its normalized absolute form.
///
/// Relative paths, any `..` traversal segments, and paths outside the optional
/// [allowlist] are rejected. Existence and git-repository shape are reported as
/// metadata so callers can decide whether to warn or fail.
LocalProjectPathValidation validateProjectLocalPath(String localPath, {List<String> allowlist = const []}) {
  final trimmed = localPath.trim();
  if (trimmed.isEmpty) {
    return const LocalProjectPathValidation(
      normalizedPath: '',
      errorCode: 'empty',
      errorMessage: 'localPath must not be empty',
      pathExists: false,
      gitRepository: false,
    );
  }
  if (!p.isAbsolute(trimmed)) {
    return LocalProjectPathValidation(
      normalizedPath: p.normalize(trimmed),
      errorCode: 'relative',
      errorMessage: 'localPath must be an absolute path',
      pathExists: false,
      gitRepository: false,
    );
  }
  if (p.split(trimmed).contains('..')) {
    return LocalProjectPathValidation(
      normalizedPath: p.normalize(trimmed),
      errorCode: 'traversal',
      errorMessage: 'localPath traversal is not allowed',
      pathExists: false,
      gitRepository: false,
    );
  }

  final normalizedPath = p.normalize(trimmed);
  if (allowlist.isNotEmpty) {
    final allowed = allowlist.any((candidate) {
      final normalizedCandidate = p.normalize(candidate.trim());
      return p.equals(normalizedPath, normalizedCandidate) || p.isWithin(normalizedCandidate, normalizedPath);
    });
    if (!allowed) {
      return LocalProjectPathValidation(
        normalizedPath: normalizedPath,
        errorCode: 'outside-allowlist',
        errorMessage: 'localPath is outside the configured allowlist',
        pathExists: false,
        gitRepository: false,
      );
    }
  }

  final pathExists = Directory(normalizedPath).existsSync();
  final gitRepository = pathExists && _looksLikeGitRepository(normalizedPath);
  return LocalProjectPathValidation(
    normalizedPath: normalizedPath,
    pathExists: pathExists,
    gitRepository: gitRepository,
  );
}

bool _looksLikeGitRepository(String path) {
  if (Directory(p.join(path, '.git')).existsSync()) {
    return true;
  }
  return File(p.join(path, '.git')).existsSync();
}

/// Per-project definition from dartclaw.yaml.
class ProjectDefinition {
  /// Project ID — the YAML map key under `projects:`.
  final String id;

  /// Git remote URL (SSH or HTTPS).
  final String? remote;

  /// Existing on-disk git checkout to use directly.
  final String? localPath;

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
    this.remote,
    this.localPath,
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
          localPath == other.localPath &&
          branch == other.branch &&
          credentials == other.credentials &&
          cloneStrategy == other.cloneStrategy &&
          pr == other.pr &&
          isDefault == other.isDefault;

  @override
  int get hashCode => Object.hash(id, remote, localPath, branch, credentials, cloneStrategy, pr, isDefault);
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

  /// Whether `POST /api/projects` may create local-path projects.
  final bool allowApiLocalPath;

  /// Absolute-path allowlist for config/API local-path projects.
  final List<String> localPathAllowlist;

  const ProjectConfig({
    this.definitions = const {},
    this.fetchCooldownMinutes = 5,
    this.allowApiLocalPath = false,
    this.localPathAllowlist = const [],
  });

  const ProjectConfig.defaults() : this();

  /// Whether any projects are configured.
  bool get isEmpty => definitions.isEmpty;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ProjectConfig &&
          fetchCooldownMinutes == other.fetchCooldownMinutes &&
          allowApiLocalPath == other.allowApiLocalPath &&
          const ListEquality<String>().equals(localPathAllowlist, other.localPathAllowlist) &&
          const MapEquality<String, ProjectDefinition>().equals(definitions, other.definitions);

  @override
  int get hashCode => Object.hash(
    fetchCooldownMinutes,
    allowApiLocalPath,
    const ListEquality<String>().hash(localPathAllowlist),
    const MapEquality<String, ProjectDefinition>().hash(definitions),
  );

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

  var allowApiLocalPath = false;
  final allowApiRaw = projectsMap['allowApiLocalPath'];
  if (allowApiRaw is bool) {
    allowApiLocalPath = allowApiRaw;
  } else if (allowApiRaw != null) {
    warns.add('projects.allowApiLocalPath: expected a boolean — using default false');
  }

  final localPathAllowlist = <String>[];
  final allowlistRaw = projectsMap['localPathAllowlist'];
  if (allowlistRaw is List) {
    for (final (index, entry) in allowlistRaw.indexed) {
      if (entry is! String || entry.trim().isEmpty) {
        warns.add('projects.localPathAllowlist[$index]: expected a non-empty absolute path string — skipping');
        continue;
      }
      final validation = validateProjectLocalPath(entry);
      if (!validation.isValid && validation.errorCode != 'outside-allowlist') {
        warns.add(
          'projects.localPathAllowlist[$index]: ${validation.errorMessage ?? "invalid path"} — skipping',
        );
        continue;
      }
      localPathAllowlist.add(validation.normalizedPath);
    }
  } else if (allowlistRaw != null) {
    warns.add('projects.localPathAllowlist: expected a list of absolute paths — using empty allowlist');
  }

  for (final entry in projectsMap.entries) {
    final id = entry.key;

    // Skip top-level scalar keys (not project definitions).
    if (id == 'fetchCooldownMinutes' || id == 'allowApiLocalPath' || id == 'localPathAllowlist') continue;

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

    final remote = _trimmedStringOrNull(projectMap['remote']);
    final localPathRaw = _trimmedStringOrNull(projectMap['localPath']);
    final hasRemote = remote != null && remote.isNotEmpty;
    final hasLocalPath = localPathRaw != null && localPathRaw.isNotEmpty;
    if (hasRemote == hasLocalPath) {
      warns.add('projects.$id: exactly one of "remote" or "localPath" must be supplied — skipping');
      continue;
    }

    String? localPath;
    if (hasLocalPath) {
      final validation = validateProjectLocalPath(localPathRaw, allowlist: localPathAllowlist);
      if (!validation.isValid) {
        final reason = switch (validation.errorCode) {
          'traversal' => 'local-path traversal',
          'outside-allowlist' => 'local-path outside allowlist',
          'relative' => 'local-path must be absolute',
          _ => validation.errorMessage ?? 'invalid local-path',
        };
        warns.add('projects.$id: $reason — skipping');
        continue;
      }
      localPath = validation.normalizedPath;
      if (!validation.pathExists) {
        warns.add('projects.$id: localPath "$localPath" does not exist at config-load time — accepting');
      } else if (!validation.gitRepository) {
        warns.add('projects.$id: localPath "$localPath" is not a git repository at config-load time — accepting');
      }
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
      localPath: localPath,
      branch: branch,
      credentials: credentials,
      cloneStrategy: cloneStrategy,
      pr: pr,
      isDefault: isDefault,
    );
  }

  return ProjectConfig(
    definitions: definitions,
    fetchCooldownMinutes: fetchCooldownMinutes,
    allowApiLocalPath: allowApiLocalPath,
    localPathAllowlist: localPathAllowlist,
  );
}

String? _trimmedStringOrNull(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}
