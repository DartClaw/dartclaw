/// Legacy storage value that formerly selected the restricted profile.
const retiredResearchTaskType = 'research';

/// Legacy storage value that formerly implied git worktree isolation.
const retiredCodingTaskType = 'coding';

/// Inert value written to the retained legacy task-type column.
const taskTypeStoragePlaceholder = 'task';

/// Container security profiles an operator may declare.
const containerSecurityProfiles = {'workspace', 'restricted'};

/// Migration refusal for the category that formerly selected `restricted`.
const retiredResearchTaskTypeMessage =
    'Task type "research" no longer selects the restricted container profile. '
    'Declare securityProfile explicitly through the authenticated task API.';

/// Raised when an input attempts to use the retired profile-carrying category.
final class RetiredTaskTypeException implements Exception {
  /// Creates the fixed refusal for the retired research category.
  const new();

  @override
  String toString() => retiredResearchTaskTypeMessage;
}

/// Migration refusal for the category that formerly implied git isolation.
const retiredCodingWorktreeMessage =
    'Task type "coding" no longer implies git worktree isolation. '
    'Declare configJson.needsWorktree explicitly as true or false through an operator task-creation surface.';

/// Returns the fail-closed migration refusal carried by any legacy value.
Exception? retiredTaskCategoryRefusal(Iterable<Object?> values) {
  if (values.contains(retiredResearchTaskType)) return const RetiredTaskTypeException();
  if (values.contains(retiredCodingTaskType)) return const MissingWorktreeDeclarationException();
  return null;
}

/// Raised when a legacy coding task omits its worktree declaration.
final class MissingWorktreeDeclarationException implements Exception {
  /// Creates the fixed refusal for the retired coding-category implication.
  const new();

  @override
  String toString() => retiredCodingWorktreeMessage;
}
