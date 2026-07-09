import 'dependency_graph.dart';
import 'step_output_validation_helpers.dart';
import 'workflow_runner_types.dart';

({Map<String, dynamic>? storySpecs, StepValidationFailure? validationFailure}) validateStorySpecsContract(
  Object? rawStorySpecs,
) {
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
    try {
      DependencyGraph(normalizedItems).validate();
    } on ArgumentError catch (e) {
      errors.add(_dependencyErrorWithRemediation(e.message.toString()));
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

/// Appends skill-actionable guidance to the generic DAG error when a
/// dependency names a story absent from the emitted catalog.
///
/// The skill owns resume-pruning (ADR-041): it omits done/skipped stories from
/// `items` and must drop dependencies on them. Without this hint the bare
/// "Unknown dependency IDs" message can misdirect a retry into re-adding the
/// closed story to `items` (re-running completed work) instead of pruning the
/// dependency.
String _dependencyErrorWithRemediation(String message) {
  if (!message.startsWith('Unknown dependency IDs')) return message;
  return '$message. If a dependency names a story you intentionally omitted '
      'because it is already done or skipped, drop that dependency from the '
      "story's `dependencies` array — do not re-add the closed story to `items`.";
}

/// Item keys the `story_specs` data-shape contract recognizes.
///
/// Unknown keys are rejected loudly (the sanctioned ADR-041 data-shape
/// exception) so a stale emitter breaks discovery at validation time instead of
/// silently never dispatching dependent gates.
const _knownStorySpecItemKeys = {
  'id',
  'title',
  'spec_path',
  'dependencies',
  'parallel',
  'wave',
  'phase',
  'risk',
  'status',
  'spec_source',
  'spec_confidence',
};

Map<String, dynamic> _normalizeItem(Map<String, dynamic> item, int index, List<String> errors) {
  final normalizedItem = Map<String, dynamic>.from(item);
  final unknownKeys = item.keys.where((key) => !_knownStorySpecItemKeys.contains(key)).toList()..sort();
  if (unknownKeys.isNotEmpty) {
    errors.add('story_specs.items[$index] has unknown propert${unknownKeys.length == 1 ? 'y' : 'ies'}: $unknownKeys.');
  }
  final id = trimmedString(item['id']);
  if (id == null) {
    errors.add('story_specs.items[$index] is missing a non-empty `id`.');
  } else {
    normalizedItem['id'] = id;
  }

  final title = trimmedString(item['title']);
  if (title == null) {
    errors.add('story_specs.items[$index] is missing a non-empty `title`.');
  } else {
    normalizedItem['title'] = title;
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
