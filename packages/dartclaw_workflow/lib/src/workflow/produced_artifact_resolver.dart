import 'dart:io';

import 'package:dartclaw_models/dartclaw_models.dart' show WorkflowStep;
import 'package:path/path.dart' as p;

import 'output_resolver.dart';
import 'schema_presets.dart';

/// Required and advisory artifacts discovered from workflow step outputs.
final class ProducedArtifacts {
  /// Paths that must be present for downstream workflow worktrees.
  final List<String> requiredPaths;

  /// Non-load-bearing paths useful for diagnostics.
  final List<String> advisoryPaths;

  const ProducedArtifacts({required this.requiredPaths, this.advisoryPaths = const <String>[]});
}

/// Normalized story-spec paths discovered inside `story_specs`.
final class StorySpecPathResolution {
  /// Output map with any `story_specs.items[].spec_path` values normalized.
  final Map<String, dynamic> outputs;

  /// Normalized `spec_path` values found in `story_specs`.
  final List<String> specPaths;

  const StorySpecPathResolution({required this.outputs, required this.specPaths});
}

/// Collects the artifacts a workflow step produced and downstream steps need.
final class ProducedArtifactResolver {
  const ProducedArtifactResolver();

  /// Resolves required produced artifacts from top-level and nested outputs.
  ProducedArtifacts resolve({
    required WorkflowStep step,
    required Map<String, Object?> outputs,
    String planDir = '',
    String? projectRoot,
  }) {
    final required = <String>{};
    final stepOutputs = step.outputs ?? const {};
    for (final outputKey in step.outputKeys) {
      final config = stepOutputs[outputKey];
      if (outputResolverFor(outputKey, config) is! FileSystemOutput) continue;
      required.addAll(_pathValues(outputs[outputKey]));
    }

    final storySpecs = resolveStorySpecPaths(
      Map<String, dynamic>.from(outputs),
      planDir: planDir,
      projectRoot: projectRoot,
    );
    required.addAll(storySpecs.specPaths);

    for (final path in _technicalResearchSiblings(storySpecs.specPaths, outputs, planDir, projectRoot)) {
      required.add(path);
    }

    return ProducedArtifacts(
      requiredPaths: _sortedNormalized(required, projectRoot: projectRoot),
      advisoryPaths: const <String>[],
    );
  }
}

/// Resolves `story_specs.spec_path` values against [planDir] exactly once.
String resolveStorySpecPathAgainstPlanDir({required String path, required String planDir}) {
  if (path.isEmpty) return path;
  if (p.isAbsolute(path)) return p.normalize(path);
  if (planDir.isEmpty || planDir == '.') return p.normalize(path);
  final normalizedSpec = p.normalize(path);
  if (_isAlreadyPlanRooted(normalizedSpec, planDir)) {
    return normalizedSpec;
  }
  return p.normalize(p.join(planDir, path));
}

/// Returns normalized `story_specs` outputs plus their load-bearing paths.
StorySpecPathResolution resolveStorySpecPaths(
  Map<String, dynamic> outputs, {
  String planDir = '',
  String? projectRoot,
}) {
  if (!outputs.containsKey('story_specs')) {
    return StorySpecPathResolution(outputs: outputs, specPaths: const <String>[]);
  }

  final rawStorySpecs = outputs['story_specs'];
  final storySpecs = switch (rawStorySpecs) {
    final Map<String, dynamic> typed => typed,
    final Map<dynamic, dynamic> dynamicMap => dynamicMap.map((key, value) => MapEntry('$key', value)),
    _ => null,
  };
  if (storySpecs == null) {
    return StorySpecPathResolution(outputs: outputs, specPaths: const <String>[]);
  }
  final rawItems = storySpecs['items'];
  if (rawItems is! List) {
    return StorySpecPathResolution(outputs: outputs, specPaths: const <String>[]);
  }

  final paths = <String>[];
  final normalizedItems = <Map<String, dynamic>>[];
  for (final item in rawItems) {
    final itemMap = switch (item) {
      final Map<String, dynamic> typed => Map<String, dynamic>.from(typed),
      final Map<dynamic, dynamic> dynamicMap => dynamicMap.map((key, value) => MapEntry('$key', value)),
      _ => <String, dynamic>{},
    };
    final rawSpecPath = (itemMap['spec_path'] as String?)?.trim();
    if (rawSpecPath != null && rawSpecPath.isNotEmpty) {
      final normalizedSpecPath = resolveStorySpecPathAgainstPlanDir(path: rawSpecPath, planDir: planDir);
      final safeSpecPath = _safeProjectRelativePath(normalizedSpecPath, projectRoot);
      itemMap['spec_path'] = safeSpecPath;
      paths.add(safeSpecPath);
    }
    normalizedItems.add(itemMap);
  }

  return StorySpecPathResolution(
    outputs: {
      ...outputs,
      'story_specs': {...storySpecs, 'items': normalizedItems},
    },
    specPaths: _sortedNormalized(paths, projectRoot: projectRoot),
  );
}

List<String> _pathValues(Object? raw) {
  if (raw == null) return const <String>[];
  if (raw is String) {
    final value = raw.trim();
    if (value.isEmpty || value == 'null') return const <String>[];
    return <String>[value];
  }
  if (raw is Iterable) {
    return raw.map((value) => value.toString().trim()).where((value) => value.isNotEmpty && value != 'null').toList();
  }
  return const <String>[];
}

List<String> _technicalResearchSiblings(
  List<String> specPaths,
  Map<String, Object?> outputs,
  String planDir,
  String? projectRoot,
) {
  if (_pathValues(outputs['technical_research']).isNotEmpty) {
    return const <String>[];
  }
  final dirs = <String>{};
  final planPaths = _pathValues(outputs['plan']);
  for (final planPath in planPaths) {
    dirs.add(p.dirname(planPath));
  }
  if (planDir.isNotEmpty && planDir != '.') {
    dirs.add(planDir);
  }
  for (final specPath in specPaths) {
    final fisDir = p.dirname(specPath);
    final parent = p.dirname(fisDir);
    if (parent.isNotEmpty && parent != '.') {
      dirs.add(parent);
    }
  }

  return _sortedNormalized(
    dirs
        .map((dir) => p.join(dir, '.technical-research.md'))
        .where((candidate) => _artifactPathExists(candidate, projectRoot)),
    projectRoot: projectRoot,
  );
}

bool _artifactPathExists(String path, String? projectRoot) {
  if (projectRoot == null || projectRoot.isEmpty) return false;
  final file = p.isAbsolute(path) ? File(path) : File(p.join(projectRoot, path));
  return file.existsSync();
}

List<String> _sortedNormalized(Iterable<String> paths, {String? projectRoot}) {
  final normalized = <String>{};
  for (final path in paths) {
    final value = path.trim();
    if (value.isEmpty || value == 'null') continue;
    normalized.add(_safeProjectRelativePath(value, projectRoot));
  }
  return normalized.toList()..sort();
}

String _safeProjectRelativePath(String path, String? projectRoot) {
  final value = path.trim();
  if (value.isEmpty || value == 'null') return p.normalize(value);
  if (projectRoot == null || projectRoot.trim().isEmpty) return p.normalize(value);

  final rootAbs = p.normalize(p.absolute(projectRoot));
  final candidateAbs = p.isAbsolute(value) ? p.normalize(value) : p.normalize(p.join(rootAbs, value));
  if (candidateAbs == rootAbs) {
    throw FormatException('Produced artifact path targets the project root: $path');
  }
  if (candidateAbs != rootAbs && !p.isWithin(rootAbs, candidateAbs)) {
    throw FormatException('Produced artifact path escapes project root: $path');
  }

  // Realpath escape check only runs when the project root itself exists.
  // Otherwise `_resolveNearestExistingPath` walks up to a parent ancestor
  // that is — by definition — outside the (still-empty) project root, and
  // every legitimate subpath would be flagged. The lexical containment
  // check above already guards against `..` traversal in this case; symlink
  // tricks are not possible until the project tree exists.
  final rootReal = _resolveExistingPath(rootAbs);
  if (rootReal != null) {
    final candidateRealAnchor = _resolveNearestExistingPath(candidateAbs);
    if (candidateRealAnchor != null && candidateRealAnchor != rootReal && !p.isWithin(rootReal, candidateRealAnchor)) {
      throw FormatException('Produced artifact path resolves outside project root: $path');
    }
  }

  return p.normalize(p.relative(candidateAbs, from: rootAbs));
}

String? _resolveNearestExistingPath(String path) {
  var current = p.normalize(path);
  while (true) {
    final resolved = _resolveExistingPath(current);
    if (resolved != null) return resolved;
    final parent = p.dirname(current);
    if (parent == current) return null;
    current = parent;
  }
}

String? _resolveExistingPath(String path) {
  final type = FileSystemEntity.typeSync(path, followLinks: false);
  if (type == FileSystemEntityType.notFound) return null;
  try {
    final followedType = FileSystemEntity.typeSync(path);
    if (followedType == FileSystemEntityType.directory) {
      return p.normalize(Directory(path).resolveSymbolicLinksSync());
    }
    return p.normalize(File(path).resolveSymbolicLinksSync());
  } on FileSystemException {
    // Broken / dangling symlink: resolveSymbolicLinksSync throws because the
    // target does not exist. Fall back to the link's textual target so the
    // caller can still bounds-check it against the project root — without
    // this fallback, `_resolveNearestExistingPath` walks up to a real
    // directory and the escape goes undetected.
    if (type == FileSystemEntityType.link) {
      try {
        final target = Link(path).targetSync();
        final resolvedTarget = p.isAbsolute(target) ? target : p.join(p.dirname(path), target);
        return p.normalize(p.absolute(resolvedTarget));
      } on FileSystemException {
        return null;
      }
    }
    return null;
  }
}

bool _isAlreadyPlanRooted(String specPath, String planDir) {
  final normalizedPlanDir = p.normalize(planDir);
  final planDirPrefix = normalizedPlanDir.endsWith(p.separator)
      ? normalizedPlanDir
      : '$normalizedPlanDir${p.separator}';
  return specPath == normalizedPlanDir || specPath.startsWith(planDirPrefix);
}
