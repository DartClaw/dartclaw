import 'package:dartclaw_workflow/dartclaw_workflow.dart' show DependencyGraph;
import 'package:test/test.dart';

void main() {
  group('DependencyGraph', () {
    test('empty collection has no dependencies', () {
      final graph = DependencyGraph([]);
      expect(graph.hasDependencies, isFalse);
    });

    test('items without dependencies are always ready', () {
      final items = [
        {'id': 's01', 'name': 'Story 1'},
        {'id': 's02', 'name': 'Story 2'},
        {'id': 's03', 'name': 'Story 3'},
      ];
      final graph = DependencyGraph(items);
      expect(graph.hasDependencies, isFalse);
      expect(graph.getReady({}), containsAll([0, 1, 2]));
    });

    test('items without id field are treated as independent', () {
      final items = [
        'plain string',
        42,
        {'name': 'no id field'},
      ];
      final graph = DependencyGraph(items);
      expect(graph.hasDependencies, isFalse);
      final ready = graph.getReady({});
      expect(ready, containsAll([0, 1, 2]));
    });

    test('linear chain: s01→s02→s03 — only s01 ready initially', () {
      final items = [
        {'id': 's01', 'name': 'Story 1'},
        {
          'id': 's02',
          'name': 'Story 2',
          'dependencies': ['s01'],
        },
        {
          'id': 's03',
          'name': 'Story 3',
          'dependencies': ['s02'],
        },
      ];
      final graph = DependencyGraph(items);
      graph.validate();

      // Initially only s01 is ready.
      var ready = graph.getReady({});
      expect(ready, [0]);

      // After s01 completes, s02 is ready.
      ready = graph.getReady({'s01'});
      expect(ready, containsAll([0, 1]));

      // After s01 and s02 complete, all ready.
      ready = graph.getReady({'s01', 's02'});
      expect(ready, containsAll([0, 1, 2]));
    });

    test('diamond dependency: s01→s02, s01→s03, s02&s03→s04', () {
      final items = [
        {'id': 's01', 'name': 'Story 1'},
        {
          'id': 's02',
          'name': 'Story 2',
          'dependencies': ['s01'],
        },
        {
          'id': 's03',
          'name': 'Story 3',
          'dependencies': ['s01'],
        },
        {
          'id': 's04',
          'name': 'Story 4',
          'dependencies': ['s02', 's03'],
        },
      ];
      final graph = DependencyGraph(items);
      graph.validate(); // Should not throw.

      // Only s01 ready at start.
      expect(graph.getReady({}), [0]);

      // s02 and s03 ready after s01.
      final afterS01 = graph.getReady({'s01'});
      expect(afterS01, containsAll([0, 1, 2]));
      expect(afterS01, isNot(contains(3)));

      // s04 ready after s02 and s03.
      final afterS0203 = graph.getReady({'s01', 's02', 's03'});
      expect(afterS0203, containsAll([0, 1, 2, 3]));
    });

    test('circular dependency (s01→s02→s01) throws ArgumentError', () {
      final items = [
        {
          'id': 's01',
          'name': 'Story 1',
          'dependencies': ['s02'],
        },
        {
          'id': 's02',
          'name': 'Story 2',
          'dependencies': ['s01'],
        },
      ];
      final graph = DependencyGraph(items);
      expect(() => graph.validate(), throwsA(isA<ArgumentError>()));
    });

    test('self-referencing dependency (s01→s01) throws ArgumentError', () {
      final items = [
        {
          'id': 's01',
          'name': 'Story 1',
          'dependencies': ['s01'],
        },
      ];
      final graph = DependencyGraph(items);
      expect(
        () => graph.validate(),
        throwsA(isA<ArgumentError>().having((e) => e.message, 'message', contains('Circular dependency'))),
      );
    });

    test('circular dependency error message contains cycle path', () {
      final items = [
        {
          'id': 's01',
          'name': 'Story 1',
          'dependencies': ['s03'],
        },
        {
          'id': 's02',
          'name': 'Story 2',
          'dependencies': ['s01'],
        },
        {
          'id': 's03',
          'name': 'Story 3',
          'dependencies': ['s02'],
        },
      ];
      final graph = DependencyGraph(items);
      expect(
        () => graph.validate(),
        throwsA(isA<ArgumentError>().having((e) => e.message, 'message', contains('Circular dependency detected'))),
      );
    });

    test('dependency referencing non-existent item ID — item treated as independent', () {
      final items = [
        {
          'id': 's01',
          'name': 'Story 1',
          'dependencies': ['s99'],
        }, // s99 doesn't exist
        {'id': 's02', 'name': 'Story 2'},
      ];
      final graph = DependencyGraph(items);
      graph.validate(); // No error — stale/missing dep not validated

      // s01 depends on s99 which doesn't exist → treated as satisfied.
      final ready = graph.getReady({});
      expect(ready, containsAll([0, 1]));
    });

    test('mixed: some with deps, some without — independent items always ready', () {
      final items = [
        {'id': 's01', 'name': 'Story 1'},
        {
          'id': 's02',
          'name': 'Story 2',
          'dependencies': ['s01'],
        },
        {'id': 's03', 'name': 'Story 3'}, // independent
      ];
      final graph = DependencyGraph(items);
      graph.validate();

      // s01 and s03 ready; s02 not yet.
      final ready = graph.getReady({});
      expect(ready, containsAll([0, 2]));
      expect(ready, isNot(contains(1)));
    });

    test('getReady grows as completed set grows', () {
      final items = [
        {'id': 's01'},
        {
          'id': 's02',
          'dependencies': ['s01'],
        },
        {
          'id': 's03',
          'dependencies': ['s02'],
        },
      ];
      final graph = DependencyGraph(items);

      expect(graph.getReady({}), [0]);
      expect(graph.getReady({'s01'}), containsAll([0, 1]));
      expect(graph.getReady({'s01', 's02'}), containsAll([0, 1, 2]));
    });

    test('hasDependencies is true when any item declares dependencies', () {
      final items = [
        {'id': 's01'},
        {
          'id': 's02',
          'dependencies': ['s01'],
        },
      ];
      final graph = DependencyGraph(items);
      expect(graph.hasDependencies, isTrue);
    });

    test('validate does not throw on valid DAG', () {
      final items = [
        {'id': 's01'},
        {
          'id': 's02',
          'dependencies': ['s01'],
        },
        {
          'id': 's03',
          'dependencies': ['s01', 's02'],
        },
      ];
      final graph = DependencyGraph(items);
      expect(() => graph.validate(), returnsNormally);
    });
  });
}
