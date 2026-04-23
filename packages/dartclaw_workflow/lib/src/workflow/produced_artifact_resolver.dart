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
    for (final outputKey in step.contextOutputs) {
      final config = stepOutputs[outputKey];
      if (outputResolverFor(outputKey, config) is! FileSystemOutput) continue;
      required.addAll(_pathValues(outputs[outputKey]));
    }

    final storySpecs = resolveStorySpecPaths(Map<String, dynamic>.from(outputs), planDir: planDir);
    required.addAll(storySpecs.specPaths);

    for (final path in _technicalResearchSiblings(storySpecs.specPaths, outputs, planDir, projectRoot)) {
      required.add(path);
    }

    return ProducedArtifacts(requiredPaths: _sortedNormalized(required), advisoryPaths: const <String>[]);
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
StorySpecPathResolution resolveStorySpecPaths(Map<String, dynamic> outputs, {String planDir = ''}) {
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
      itemMap['spec_path'] = normalizedSpecPath;
      paths.add(normalizedSpecPath);
    }
    normalizedItems.add(itemMap);
  }

  return StorySpecPathResolution(
    outputs: {
      ...outputs,
      'story_specs': {...storySpecs, 'items': normalizedItems},
    },
    specPaths: _sortedNormalized(paths),
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
  );
}

bool _artifactPathExists(String path, String? projectRoot) {
  if (projectRoot == null || projectRoot.isEmpty) return false;
  final file = p.isAbsolute(path) ? File(path) : File(p.join(projectRoot, path));
  return file.existsSync();
}

List<String> _sortedNormalized(Iterable<String> paths) {
  final normalized = <String>{};
  for (final path in paths) {
    final value = path.trim();
    if (value.isEmpty || value == 'null') continue;
    normalized.add(p.normalize(value));
  }
  return normalized.toList()..sort();
}

bool _isAlreadyPlanRooted(String specPath, String planDir) {
  final normalizedPlanDir = p.normalize(planDir);
  final planDirPrefix = normalizedPlanDir.endsWith(p.separator)
      ? normalizedPlanDir
      : '$normalizedPlanDir${p.separator}';
  return specPath == normalizedPlanDir || specPath.startsWith(planDirPrefix);
}
