const workflowIntegrationBranchFieldPaths = {
  'integrationBranch': 'gitStrategy.integrationBranch',
  'integration_branch': 'gitStrategy.integration_branch',
  'bootstrap': 'gitStrategy.bootstrap',
};

bool? resolveWorkflowIntegrationBranchValue(
  Object? Function(String key) valueFor, {
  required Object Function(String fieldPath) typeError,
  required Object Function(Iterable<String> fieldPaths) disagreementError,
}) {
  final values = <String, bool>{};
  for (final entry in workflowIntegrationBranchFieldPaths.entries) {
    final value = valueFor(entry.key);
    if (value == null) continue;
    if (value is! bool) {
      throw typeError(entry.value);
    }
    values[entry.value] = value;
  }

  if (values.isEmpty) return null;
  final distinct = values.values.toSet();
  if (distinct.length > 1) {
    throw disagreementError(values.keys);
  }
  return distinct.single;
}

String quotedWorkflowFieldList(Iterable<String> fields) => fields.map((field) => '"$field"').join(', ');
