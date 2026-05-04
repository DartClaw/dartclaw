import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' show WorkflowStep;
import 'package:path/path.dart' as p;

/// Returns deterministic defaults for workflow context outputs with global semantics.
Object? defaultContextOutput(WorkflowStep step, Map<String, dynamic> outputs, String outputKey) {
  if (_isSourceOutputKey(outputKey)) return _defaultSourceValue(step, outputKey, outputs);
  if (step.id == 'discover-project') {
    switch (outputKey) {
      case 'prd':
        return _existingProjectIndexPath(outputs['project_index'], 'active_prd');
      case 'plan':
        if (_activeStorySpecs(outputs['project_index']) == null) return null;
        return _existingProjectIndexPath(outputs['project_index'], 'active_plan');
      case 'story_specs':
        if (_existingProjectIndexPath(outputs['project_index'], 'active_plan') == null) {
          return const <String, dynamic>{'items': <Map<String, dynamic>>[]};
        }
        final activeStorySpecs = _activeStorySpecs(outputs['project_index']);
        if (activeStorySpecs != null) return activeStorySpecs;
        return const <String, dynamic>{'items': <Map<String, dynamic>>[]};
    }
  }
  return null;
}

/// Fills blank source outputs after extraction so gates never see an empty source tag.
void applyContextOutputDefaults(WorkflowStep step, Map<String, dynamic> outputs) {
  _canonicalizeDiscoverProjectOutputs(step, outputs);

  for (final outputKey in step.outputKeys) {
    if (!_isBlank(outputs[outputKey])) continue;
    final derivedValue = defaultContextOutput(step, outputs, outputKey);
    if (derivedValue != null) {
      outputs[outputKey] = derivedValue;
    }
  }

  for (final outputKey in step.outputKeys.where(_isSourceOutputKey)) {
    if (!_shouldFillSource(step, outputKey, outputs)) continue;
    outputs[outputKey] = _defaultSourceValue(step, outputKey, outputs);
  }
}

void _canonicalizeDiscoverProjectOutputs(WorkflowStep step, Map<String, dynamic> outputs) {
  if (step.id != 'discover-project') return;
  _canonicalizeDiscoverProjectIndex(outputs);
  for (final outputKey in const ['prd', 'plan', 'story_specs']) {
    if (!step.outputKeys.contains(outputKey)) continue;
    final canonicalValue = defaultContextOutput(step, outputs, outputKey);
    outputs[outputKey] = canonicalValue ?? '';
  }
  _canonicalizeDiscoverProjectSourceOutputs(step, outputs);
}

void _canonicalizeDiscoverProjectIndex(Map<String, dynamic> outputs) {
  final projectIndex = _asStringKeyedMap(outputs['project_index']);
  if (projectIndex == null) return;

  final sanitized = Map<String, dynamic>.from(projectIndex);
  for (final key in const ['active_prd', 'active_plan']) {
    if (_existingProjectIndexPath(sanitized, key) == null) {
      sanitized[key] = null;
    }
  }
  if (sanitized['active_plan'] == null) {
    sanitized['active_story_specs'] = null;
  }
  outputs['project_index'] = sanitized;
}

void _canonicalizeDiscoverProjectSourceOutputs(WorkflowStep step, Map<String, dynamic> outputs) {
  for (final sourceKey in step.outputKeys.where(_isSourceOutputKey)) {
    final artifactKey = _artifactKeyForSource(sourceKey);
    if (artifactKey == null) continue;
    outputs[sourceKey] = _isBlank(outputs[artifactKey]) ? 'synthesized' : 'existing';
  }
}

bool _shouldFillSource(WorkflowStep step, String sourceKey, Map<String, dynamic> outputs) {
  if (_isBlank(outputs[sourceKey])) return true;
  final artifactKey = _artifactKeyForSource(sourceKey);
  return step.id == 'discover-project' &&
      outputs[sourceKey] == 'synthesized' &&
      artifactKey != null &&
      !_isBlank(outputs[artifactKey]);
}

String _defaultSourceValue(WorkflowStep step, String sourceKey, Map<String, dynamic> outputs) {
  if (step.id == 'discover-project') {
    final artifactKey = _artifactKeyForSource(sourceKey);
    if (artifactKey != null && !_isBlank(outputs[artifactKey])) {
      return 'existing';
    }
  }
  return 'synthesized';
}

bool _isSourceOutputKey(String outputKey) => outputKey.endsWith('_source');

String? _artifactKeyForSource(String sourceKey) {
  return switch (sourceKey) {
    'plan_source' => 'plan',
    'prd_source' => 'prd',
    'spec_source' => 'spec_path',
    _ => null,
  };
}

Object? _activeStorySpecs(Object? projectIndex) {
  if (projectIndex is Map<String, dynamic>) return projectIndex['active_story_specs'];
  if (projectIndex is Map<Object?, Object?>) return projectIndex['active_story_specs'];
  return null;
}

String? _projectIndexPath(Object? projectIndex, String key) {
  final raw = switch (projectIndex) {
    final Map<String, dynamic> typed => typed[key],
    final Map<Object?, Object?> map => map[key],
    _ => null,
  };
  if (raw is! String || _isBlank(raw)) return null;
  return raw;
}

Map<String, dynamic>? _asStringKeyedMap(Object? value) {
  return switch (value) {
    final Map<String, dynamic> typed => Map<String, dynamic>.from(typed),
    final Map<dynamic, dynamic> dynamicMap => dynamicMap.map((key, value) => MapEntry('$key', value)),
    _ => null,
  };
}

String? _existingProjectIndexPath(Object? projectIndex, String key) {
  final raw = _projectIndexPath(projectIndex, key);
  if (raw == null) return null;
  final projectRoot = _projectIndexPath(projectIndex, 'project_root');
  if (projectRoot == null) return raw;
  final absolute = p.isAbsolute(raw) ? raw : p.join(projectRoot, raw);
  return File(absolute).existsSync() ? raw : null;
}

bool _isBlank(Object? value) {
  if (value == null) return true;
  if (value is String) {
    final trimmed = value.trim();
    return trimmed.isEmpty || trimmed == 'null';
  }
  return false;
}
