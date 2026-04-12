import 'package:dartclaw_models/dartclaw_models.dart' show TaskType;

/// Resolves a [TaskType] to its security profile ID.
///
/// Default mapping:
/// - `research` → `restricted` (no workspace mount)
/// - All other types → `workspace`
String resolveProfile(TaskType taskType) {
  return switch (taskType) {
    TaskType.research => 'restricted',
    _ => 'workspace',
  };
}
