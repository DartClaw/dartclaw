import 'package:dartclaw_workflow/src/workflow/dependency_graph.dart' show DependencyGraph;
import 'package:dartclaw_workflow/src/workflow/story_specs_contract_validator.dart' show validateStorySpecsContract;
import 'package:test/test.dart';

Map<String, dynamic> _item(String id, {List<String> deps = const []}) => {
  'id': id,
  'spec_path': 'dev/specs/0.17/fis/${id.toLowerCase()}.md',
  'dependencies': deps,
};

List<Map<String, dynamic>> _items(Map<String, dynamic> storySpecs) =>
    (storySpecs['items'] as List).cast<Map<String, dynamic>>();

void main() {
  group('validateStorySpecsContract dependency pruning', () {
    // On the 0.17 resume, S01/S03/S06 are done and excluded from the emitted set.
    const completed = {'S01', 'S03', 'S06', 'S12'};

    test('dependencies on completed (excluded) stories validate', () {
      final storySpecs = {
        'items': [
          _item('S08'),
          _item('S07', deps: ['S01']),
          _item('S13'),
          _item('S11', deps: ['S01', 'S03', 'S06', 'S07', 'S08', 'S13']),
        ],
      };

      final result = validateStorySpecsContract(storySpecs, completedStoryIds: completed);

      expect(result.validationFailure, isNull, reason: 'deps on completed stories must not be "unknown"');
      final items = _items(result.storySpecs!);
      final s07 = items.firstWhere((i) => i['id'] == 'S07');
      expect(s07['dependencies'], isEmpty);
      final s11 = items.firstWhere((i) => i['id'] == 'S11');
      expect(s11['dependencies'], unorderedEquals(['S07', 'S08', 'S13']));
    });

    test('ordering among emitted stories is preserved after pruning', () {
      final storySpecs = {
        'items': [
          _item('S08'),
          _item('S07', deps: ['S01']),
          _item('S13'),
          _item('S11', deps: ['S01', 'S03', 'S06', 'S07', 'S08', 'S13']),
        ],
      };

      final items = _items(validateStorySpecsContract(storySpecs, completedStoryIds: completed).storySpecs!);
      final graph = DependencyGraph(items);

      expect(graph.getReady({}), unorderedEquals([0, 1, 2]));
      expect(graph.getReady({'S07', 'S08', 'S13'}), contains(3));
    });

    test('cycle among emitted stories is still rejected', () {
      final storySpecs = {
        'items': [
          _item('S07', deps: ['S08']),
          _item('S08', deps: ['S07']),
        ],
      };

      final result = validateStorySpecsContract(storySpecs, completedStoryIds: completed);

      expect(result.storySpecs, isNull);
      expect(result.validationFailure!.reason, contains('Circular dependency'));
    });

    test('dependency on an id that is not a completed story is rejected (typo guard)', () {
      final storySpecs = {
        'items': [
          _item('S01'),
          _item('S02', deps: ['S99']),
        ],
      };

      // S99 is not a completed story, so it is unknown, not an already-satisfied prerequisite.
      final result = validateStorySpecsContract(storySpecs, completedStoryIds: {'S03', 'S06'});

      expect(result.storySpecs, isNull);
      expect(result.validationFailure!.reason, contains('Unknown dependency IDs: S99'));
    });

    test('dependency on an absent but NON-completed story is rejected, not silently pruned', () {
      // S05 exists in the plan but is, say, blocked/pending — not in completedStoryIds.
      // Pruning it would treat an unsatisfied prerequisite as met.
      final storySpecs = {
        'items': [
          _item('S02', deps: ['S05']),
        ],
      };

      final result = validateStorySpecsContract(storySpecs, completedStoryIds: {'S01'});

      expect(result.storySpecs, isNull);
      expect(result.validationFailure!.reason, contains('Unknown dependency IDs: S05'));
    });

    test('without a completed-story set validation stays strict (out-of-set deps rejected)', () {
      final storySpecs = {
        'items': [
          _item('S07', deps: ['S01']),
        ],
      };

      // completedStoryIds null: plan catalog unavailable, fall back to strict rejection.
      final result = validateStorySpecsContract(storySpecs);

      expect(result.storySpecs, isNull);
      expect(result.validationFailure!.reason, contains('Unknown dependency IDs: S01'));
    });
  });
}
