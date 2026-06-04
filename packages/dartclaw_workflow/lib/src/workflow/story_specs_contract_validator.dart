import 'dependency_graph.dart';
import 'step_output_validation_helpers.dart';
import 'workflow_runner_types.dart';

({Map<String, dynamic>? storySpecs, StepValidationFailure? validationFailure}) validateStorySpecsContract(
  Object? rawStorySpecs, {
  Set<String>? completedStoryIds,
}) {
  if (rawStorySpecs is List) {
    return (
      storySpecs: null,
      validationFailure: const StepValidationFailure(
        reason:
            'Plan skill produced legacy list-shaped `story_specs`. Expected an object with an `items` list of '
            'records carrying `id`, `spec_path`, and `dependencies`.',
      ),
    );
  }

  final storySpecs = asStringKeyedMap(rawStorySpecs);
  if (storySpecs == null) {
    return (
      storySpecs: null,
      validationFailure: const StepValidationFailure(
        reason: 'Plan skill produced invalid `story_specs`. Expected an object with an `items` list.',
      ),
    );
  }

  final rawItems = storySpecs['items'];
  if (rawItems is! List) {
    return (
      storySpecs: null,
      validationFailure: const StepValidationFailure(
        reason: 'Plan skill produced invalid `story_specs`. Expected `story_specs.items` to be a list.',
      ),
    );
  }

  final errors = <String>[];
  final normalizedItems = <Map<String, dynamic>>[];
  for (var index = 0; index < rawItems.length; index++) {
    final item = asStringKeyedMap(rawItems[index]);
    if (item == null) {
      errors.add('story_specs.items[$index] must be an object.');
      continue;
    }
    normalizedItems.add(_normalizeItem(item, index, errors));
  }

  if (errors.isEmpty) {
    _pruneSatisfiedDependencies(normalizedItems, completedStoryIds);
    try {
      DependencyGraph(normalizedItems).validate();
    } on ArgumentError catch (e) {
      errors.add(e.message.toString());
    }
  }

  if (errors.isNotEmpty) {
    return (
      storySpecs: null,
      validationFailure: StepValidationFailure(
        reason: 'Plan skill produced invalid `story_specs`: ${errors.join(' ')}',
      ),
    );
  }
  return (storySpecs: {...storySpecs, 'items': normalizedItems}, validationFailure: null);
}

/// Drops dependency IDs that reference already-completed (done/skipped) plan
/// stories.
///
/// On resume, `dartclaw-discover-andthen-plan` omits done/skipped stories, so
/// the remaining stories' dependencies on them would otherwise be rejected as
/// unknown. A dependency is pruned only when it names a story in
/// [completedStoryIds] (the plan's done/skipped story IDs) that is absent from
/// the emitted collection — an already-satisfied prerequisite. Dependencies on
/// emitted stories are kept, preserving ordering and cycle detection among
/// them. Dependencies on stories that are absent for any other reason — a typo,
/// or a non-completed story the discovery step dropped — are kept so
/// [DependencyGraph] rejects them as unknown rather than silently treating an
/// unsatisfied prerequisite as met.
///
/// When [completedStoryIds] is null the plan catalog was unavailable; nothing
/// is pruned and validation stays strict (every out-of-set dependency is
/// unknown).
void _pruneSatisfiedDependencies(List<Map<String, dynamic>> items, Set<String>? completedStoryIds) {
  if (completedStoryIds == null) return;
  final emittedIds = <String>{};
  for (final item in items) {
    final id = item['id'];
    if (id is String && id.isNotEmpty) emittedIds.add(id);
  }
  for (final item in items) {
    final deps = item['dependencies'];
    if (deps is! List) continue;
    item['dependencies'] = deps
        .whereType<String>()
        .where((dep) => emittedIds.contains(dep) || !completedStoryIds.contains(dep))
        .toList();
  }
}

Map<String, dynamic> _normalizeItem(Map<String, dynamic> item, int index, List<String> errors) {
  final normalizedItem = Map<String, dynamic>.from(item);
  final id = trimmedString(item['id']);
  if (id == null) {
    errors.add('story_specs.items[$index] is missing a non-empty `id`.');
  } else {
    normalizedItem['id'] = id;
  }

  final specPath = trimmedString(item['spec_path']);
  if (specPath == null) {
    errors.add('story_specs.items[$index] is missing a non-empty `spec_path`.');
  } else {
    normalizedItem['spec_path'] = specPath;
  }

  final rawDependencies = item['dependencies'];
  if (rawDependencies is! List) {
    errors.add('story_specs.items[$index] is missing `dependencies` as a list.');
  } else {
    normalizedItem['dependencies'] = _normalizeDependencies(rawDependencies, index, errors);
  }
  return normalizedItem;
}

List<String> _normalizeDependencies(List<Object?> rawDependencies, int index, List<String> errors) {
  final dependencies = <String>[];
  for (var depIndex = 0; depIndex < rawDependencies.length; depIndex++) {
    final dependency = trimmedString(rawDependencies[depIndex]);
    if (dependency == null) {
      errors.add('story_specs.items[$index].dependencies[$depIndex] must be a non-empty string.');
      continue;
    }
    dependencies.add(dependency);
  }
  return dependencies;
}
