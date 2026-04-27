import 'package:dartclaw_core/dartclaw_core.dart' show WorkflowStep;

/// Returns deterministic defaults for workflow context outputs with global semantics.
Object? defaultContextOutput(WorkflowStep step, Map<String, dynamic> outputs, String outputKey) {
  if (_isSourceOutputKey(outputKey)) return _defaultSourceValue(step, outputKey, outputs);
  if (step.id == 'discover-project') {
    switch (outputKey) {
      case 'prd':
        return _projectIndexPath(outputs['project_index'], 'active_prd');
      case 'plan':
        if (_activeStorySpecs(outputs['project_index']) == null) return null;
        return _projectIndexPath(outputs['project_index'], 'active_plan');
      case 'story_specs':
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
  for (final outputKey in const ['prd', 'plan', 'story_specs']) {
    if (!step.outputKeys.contains(outputKey)) continue;
    final canonicalValue = defaultContextOutput(step, outputs, outputKey);
    outputs[outputKey] = canonicalValue ?? '';
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

bool _isBlank(Object? value) {
  if (value == null) return true;
  if (value is String) {
    final trimmed = value.trim();
    return trimmed.isEmpty || trimmed == 'null';
  }
  return false;
}
