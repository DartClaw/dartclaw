import 'package:dartclaw_core/dartclaw_core.dart' show normalizeDynamicMap;
import 'package:test/test.dart';

void main() {
  group('normalizeDynamicMap', () {
    test('already-String-keyed map is returned unchanged', () {
      final input = <dynamic, dynamic>{'a': 1, 'b': 'two', 'c': null};
      final result = normalizeDynamicMap(input);
      expect(result, equals({'a': 1, 'b': 'two', 'c': null}));
    });

    test('non-string keys are coerced via toString()', () {
      final input = <dynamic, dynamic>{1: 'one', 2: 'two'};
      final result = normalizeDynamicMap(input);
      expect(result, equals({'1': 'one', '2': 'two'}));
    });

    test('nested Map<dynamic, dynamic> is recursively normalized', () {
      final input = <dynamic, dynamic>{
        'outer': <dynamic, dynamic>{1: 'inner-one', 'x': 42},
      };
      final result = normalizeDynamicMap(input);
      expect(
        result,
        equals({
          'outer': {'1': 'inner-one', 'x': 42},
        }),
      );
    });

    test('list elements that are Map<dynamic, dynamic> are recursively normalized', () {
      final input = <dynamic, dynamic>{
        'items': [
          <dynamic, dynamic>{1: 'a'},
          'plain-string',
          42,
        ],
      };
      final result = normalizeDynamicMap(input);
      expect(
        result,
        equals({
          'items': [
            {'1': 'a'},
            'plain-string',
            42,
          ],
        }),
      );
    });

    test('null, int, String values pass through unchanged', () {
      final input = <dynamic, dynamic>{'n': null, 'i': 99, 's': 'hello'};
      final result = normalizeDynamicMap(input);
      expect(result['n'], isNull);
      expect(result['i'], equals(99));
      expect(result['s'], equals('hello'));
    });

    test('deeply nested structure is fully normalized', () {
      final input = <dynamic, dynamic>{
        'level1': <dynamic, dynamic>{
          'level2': <dynamic, dynamic>{42: 'deep'},
        },
      };
      final result = normalizeDynamicMap(input);
      expect(
        result,
        equals({
          'level1': {
            'level2': {'42': 'deep'},
          },
        }),
      );
    });

    test('empty map returns empty map', () {
      final result = normalizeDynamicMap(<dynamic, dynamic>{});
      expect(result, isEmpty);
    });

    test('list of non-map items passes through unchanged', () {
      final input = <dynamic, dynamic>{
        'nums': [1, 2, 3],
      };
      final result = normalizeDynamicMap(input);
      expect(result['nums'], equals([1, 2, 3]));
    });
  });
}
