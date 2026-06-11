import 'dart:io';

import 'package:path/path.dart' as p;

import 'output_resolver.dart';
import 'path_safety_policy.dart';
import 'schema_presets.dart';
import 'step_output_validation_helpers.dart';
import 'workflow_definition.dart' show WorkflowStep;

/// Closed status enum from the AndThen `ops` skill's `update-plan` form.
///
/// Mirrored from `dartclaw-discover-andthen-plan/SKILL.md` rule 6 so a code-side
/// pass can enforce the same vocabulary the LLM is asked to honor. Keep these
/// two sites in sync.
const _storyStatusEnum = <String>{'pending', 'spec-ready', 'in-progress', 'done', 'skipped', 'blocked'};
const _closedStoryStatuses = <String>{'done', 'skipped'};

/// Required artifacts discovered from workflow step outputs.
final class ProducedArtifacts {
  /// Paths that must be present for downstream workflow worktrees.
  final List<String> requiredPaths;

  const ProducedArtifacts({required this.requiredPaths});
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
    String? runtimeArtifactsRoot,
  }) {
    final required = <String>{};
    final stepOutputs = step.outputs ?? const {};
    for (final outputKey in step.outputKeys) {
      final config = stepOutputs[outputKey];
      if (outputResolverFor(outputKey, config) is! FileSystemOutput) continue;
      for (final raw in _pathValues(outputs[outputKey])) {
        required.add(raw);
      }
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
      requiredPaths: _sortedNormalized(required, projectRoot: projectRoot, runtimeArtifactsRoot: runtimeArtifactsRoot),
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
  final storySpecs = asStringKeyedMap(rawStorySpecs);
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
    final itemMap = asStringKeyedMap(item) ?? <String, dynamic>{};
    final status = _normalizeStoryStatus(itemMap);
    if (_closedStoryStatuses.contains(status)) continue;

    final rawSpecPath = (itemMap['spec_path'] as String?)?.trim();
    if (rawSpecPath != null && rawSpecPath.isNotEmpty) {
      _validateStorySpecPathInput(rawSpecPath);
      final normalizedSpecPath = resolveStorySpecPathAgainstPlanDir(path: rawSpecPath, planDir: planDir);
      _validateStorySpecPathInput(normalizedSpecPath);
      final safeSpecPath = safeProjectRelativePath(
        normalizedSpecPath,
        projectRoot,
        fieldName: 'story_specs.items[].spec_path',
      );
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

List<String> _sortedNormalized(Iterable<String> paths, {String? projectRoot, String? runtimeArtifactsRoot}) {
  final normalized = <String>{};
  for (final path in paths) {
    final value = path.trim();
    if (value.isEmpty || value == 'null') continue;
    if (_isRuntimeArtifactPath(value, runtimeArtifactsRoot)) continue;
    normalized.add(safeProjectRelativePath(value, projectRoot, fieldName: 'Produced artifact path', rejectRoot: true));
  }
  return normalized.toList()..sort();
}

bool _isRuntimeArtifactPath(String path, String? runtimeArtifactsRoot) {
  final root = runtimeArtifactsRoot?.trim();
  if (root == null || root.isEmpty) return false;

  final normalizedRoot = p.normalize(root);
  final normalizedPath = p.normalize(path.trim());
  if (normalizedPath == normalizedRoot || p.isWithin(normalizedRoot, normalizedPath)) {
    return true;
  }

  final rootAbs = p.normalize(p.absolute(normalizedRoot));
  final pathAbs = p.isAbsolute(normalizedPath) ? normalizedPath : p.normalize(p.absolute(normalizedPath));
  if (pathAbs == rootAbs || p.isWithin(rootAbs, pathAbs)) return true;

  try {
    if (!Directory(rootAbs).existsSync()) return false;
    final resolvedRoot = p.normalize(Directory(rootAbs).resolveSymbolicLinksSync());
    return pathAbs == resolvedRoot || p.isWithin(resolvedRoot, pathAbs);
  } catch (_) {
    return false; // Symlink resolution failed (dangling link or permission) – deny containment.
  }
}

bool _isAlreadyPlanRooted(String specPath, String planDir) {
  final normalizedPlanDir = p.normalize(planDir);
  final planDirPrefix = normalizedPlanDir.endsWith(p.separator)
      ? normalizedPlanDir
      : '$normalizedPlanDir${p.separator}';
  return specPath == normalizedPlanDir || specPath.startsWith(planDirPrefix);
}

/// Coerces an out-of-enum or missing `status` value on a story-spec item to
/// `pending` per the resume-filter contract in `dartclaw-discover-andthen-plan`.
///
/// Defence-in-depth for the LLM-side rule – a typo like `"spec_ready"` would
/// otherwise propagate untouched and silently skip downstream `entryGate`
/// expressions that compare on the canonical dash form.
String _normalizeStoryStatus(Map<String, dynamic> itemMap) {
  final raw = itemMap['status'];
  if (raw is String && _storyStatusEnum.contains(raw)) return raw;
  itemMap['status'] = 'pending';
  return 'pending';
}

void _validateStorySpecPathInput(String path) {
  if (p.isAbsolute(path)) {
    throw FormatException('story_specs.items[].spec_path must be workspace-relative: $path');
  }
  validateArgumentSafePath(path, fieldName: 'story_specs.items[].spec_path', rawPath: path);
  if (p.extension(path).toLowerCase() != '.md') {
    throw FormatException('story_specs.items[].spec_path must be a markdown FIS path: $path');
  }
  if (!isFisMarkdownPath(path)) {
    throw FormatException('story_specs.items[].spec_path must use an sNN-style markdown FIS basename: $path');
  }
}
