import 'workflow_context.dart';

/// Resolves a context key, preferring exact flat keys before dotted map paths.
dynamic resolveContextKey(WorkflowContext context, String key) {
  final data = context.data;
  if (data.containsKey(key)) return data[key];
  if (!key.contains('.')) return null;
  Object? current = data;
  for (final segment in key.split('.')) {
    if (current is! Map) return null;
    current = current[segment];
  }
  return current;
}
