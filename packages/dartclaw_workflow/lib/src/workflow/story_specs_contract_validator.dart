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
