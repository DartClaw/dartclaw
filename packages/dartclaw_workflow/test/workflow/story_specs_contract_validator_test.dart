import 'package:dartclaw_workflow/src/workflow/dependency_graph.dart' show DependencyGraph;
import 'package:dartclaw_workflow/src/workflow/story_specs_contract_validator.dart' show validateStorySpecsContract;
import 'package:test/test.dart';

Map<String, dynamic> _item(String id, {List<String> deps = const []}) => {
  'id': id,
  'title': id,
  'spec_path': 'dev/specs/0.17/fis/${id.toLowerCase()}.md',
  'dependencies': deps,
};

List<Map<String, dynamic>> _items(Map<String, dynamic> storySpecs) =>
    (storySpecs['items'] as List).cast<Map<String, dynamic>>();

void main() {
  // The contract validator is generic: it normalizes the structural shape and
  // runs the dependency DAG/cycle check on the emitted payload alone. It carries
  // no plan-status knowledge — pruning of already-completed prerequisites is the
  // discovery skill's job, so a dependency on a story absent from the emitted
  // set is always rejected as unknown.
  group('validateStorySpecsContract structural + DAG validation', () {
    test('a well-formed catalog validates and preserves emitted ordering', () {
      final storySpecs = {
        'items': [
          _item('S08'),
          _item('S07', deps: ['S08']),
          _item('S13'),
          _item('S11', deps: ['S07', 'S08', 'S13']),
        ],
      };

      final result = validateStorySpecsContract(storySpecs);

      expect(result.validationFailure, isNull);
      final items = _items(result.storySpecs!);
      final graph = DependencyGraph(items);
      expect(graph.getReady({}), unorderedEquals([0, 2]));
      expect(graph.getReady({'S07', 'S08', 'S13'}), contains(3));
    });

    test('a dependency cycle is rejected', () {
      final storySpecs = {
        'items': [
          _item('S07', deps: ['S08']),
          _item('S08', deps: ['S07']),
        ],
      };

      final result = validateStorySpecsContract(storySpecs);

      expect(result.storySpecs, isNull);
      expect(result.validationFailure!.reason, contains('Circular dependency'));
    });

    test('a dependency on a story absent from the emitted set is rejected as unknown', () {
      final storySpecs = {
        'items': [
          _item('S01'),
          _item('S02', deps: ['S99']),
        ],
      };

      final result = validateStorySpecsContract(storySpecs);

      expect(result.storySpecs, isNull);
      expect(result.validationFailure!.reason, contains('Unknown dependency IDs: S99'));
    });

    test('the unknown-dependency failure carries skill-actionable pruning guidance', () {
      // ADR-041 moved resume-pruning to the skill. A dependency on a closed
      // (omitted) story surfaces as "unknown"; the retry feedback must tell the
      // skill to drop the dependency, not re-add the closed story to `items`.
      final storySpecs = {
        'items': [
          _item('S01'),
          _item('S02', deps: ['S99']),
        ],
      };

      final result = validateStorySpecsContract(storySpecs);

      final reason = result.validationFailure!.reason;
      expect(reason, contains('drop that dependency'));
      expect(reason, contains('do not re-add the closed story'));
    });

    test('a cycle failure stays generic (no story-pruning guidance)', () {
      final storySpecs = {
        'items': [
          _item('S07', deps: ['S08']),
          _item('S08', deps: ['S07']),
        ],
      };

      final result = validateStorySpecsContract(storySpecs);

      expect(result.validationFailure!.reason, contains('Circular dependency'));
      expect(result.validationFailure!.reason, isNot(contains('drop that dependency')));
    });

    test('legacy list-shaped story_specs is rejected', () {
      final result = validateStorySpecsContract([_item('S01')]);

      expect(result.storySpecs, isNull);
      expect(result.validationFailure!.reason, contains('legacy list-shaped'));
    });

    test('an item missing a non-empty spec_path is rejected', () {
      final storySpecs = {
        'items': [
          {'id': 'S01', 'title': 'Story', 'spec_path': '', 'dependencies': <String>[]},
        ],
      };

      final result = validateStorySpecsContract(storySpecs);

      expect(result.storySpecs, isNull);
      expect(result.validationFailure!.reason, contains('spec_path'));
    });

    test('an item missing a non-empty title is rejected', () {
      final storySpecs = {
        'items': [
          {'id': 'S01', 'spec_path': 'dev/specs/0.17/fis/s01.md', 'dependencies': <String>[]},
        ],
      };

      final result = validateStorySpecsContract(storySpecs);

      expect(result.storySpecs, isNull);
      expect(result.validationFailure!.reason, contains('title'));
    });
  });
}
