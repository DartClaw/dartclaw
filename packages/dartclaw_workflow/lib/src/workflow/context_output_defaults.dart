import 'workflow_definition.dart' show WorkflowStep;

/// Returns deterministic defaults for workflow context outputs with global semantics.
Object? defaultContextOutput(WorkflowStep step, Map<String, dynamic> outputs, String outputKey) {
  if (_isSourceOutputKey(outputKey)) return _defaultSourceValue(step, outputKey, outputs);
  return null;
}

/// Fills blank source outputs after extraction so gates never see an empty source tag.
void applyContextOutputDefaults(WorkflowStep step, Map<String, dynamic> outputs) {
  for (final outputKey in step.outputKeys) {
    if (!_isBlank(outputs[outputKey])) continue;
    final derivedValue = defaultContextOutput(step, outputs, outputKey);
    if (derivedValue != null) {
      outputs[outputKey] = derivedValue;
    }
  }
}

String _defaultSourceValue(WorkflowStep step, String sourceKey, Map<String, dynamic> outputs) => 'synthesized';

bool _isSourceOutputKey(String outputKey) => outputKey.endsWith('_source');

bool _isBlank(Object? value) {
  if (value == null) return true;
  if (value is String) {
    final trimmed = value.trim();
    return trimmed.isEmpty || trimmed == 'null';
  }
  return false;
}
