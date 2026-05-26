import 'package:test/test.dart';

// ignore: implementation_imports
import 'package:dartclaw_config/src/yaml_type_safe_reader.dart';

void main() {
  group('readString', () {
    test('returns value when key exists and type matches', () {
      final warns = <String>[];
      expect(readString('key', {'key': 'hello'}, warns), 'hello');
      expect(warns, isEmpty);
    });

    test('returns defaultValue when key is absent', () {
      final warns = <String>[];
      expect(readString('key', {}, warns, defaultValue: 'def'), 'def');
      expect(warns, isEmpty);
    });

    test('returns null default when key is absent and no default provided', () {
      final warns = <String>[];
      expect(readString('key', {}, warns), isNull);
      expect(warns, isEmpty);
    });

    test('warns and returns default on type mismatch', () {
      final warns = <String>[];
      expect(readString('key', {'key': 42}, warns, defaultValue: 'def'), 'def');
      expect(warns, hasLength(1));
      expect(warns.first, contains('Invalid type for key'));
    });
  });

  group('readInt', () {
    test('returns value when key exists and type matches', () {
      final warns = <String>[];
      expect(readInt('port', {'port': 8080}, warns), 8080);
      expect(warns, isEmpty);
    });

    test('returns defaultValue when key is absent', () {
      final warns = <String>[];
      expect(readInt('port', {}, warns, defaultValue: 3000), 3000);
      expect(warns, isEmpty);
    });

    test('warns and returns default on type mismatch', () {
      final warns = <String>[];
      expect(readInt('port', {'port': 'not-a-number'}, warns, defaultValue: 3000), 3000);
      expect(warns, hasLength(1));
      expect(warns.first, contains('Invalid type for port'));
    });
  });

  group('readBool', () {
    test('returns value when key exists and type matches', () {
      final warns = <String>[];
      expect(readBool('enabled', {'enabled': true}, warns), isTrue);
      expect(warns, isEmpty);
    });

    test('returns defaultValue when key is absent', () {
      final warns = <String>[];
      expect(readBool('enabled', {}, warns, defaultValue: false), isFalse);
      expect(warns, isEmpty);
    });

    test('warns and returns default on type mismatch', () {
      final warns = <String>[];
      expect(readBool('enabled', {'enabled': 'yes'}, warns, defaultValue: false), isFalse);
      expect(warns, hasLength(1));
      expect(warns.first, contains('Invalid type for enabled'));
    });
  });

  group('readMap', () {
    test('returns normalized map when key exists with Map value', () {
      final warns = <String>[];
      final result = readMap('config', {
        'config': {'a': 1, 'b': 'x'},
      }, warns);
      expect(result, {'a': 1, 'b': 'x'});
      expect(warns, isEmpty);
    });

    test('returns defaultValue when key is absent', () {
      final warns = <String>[];
      expect(readMap('config', {}, warns, defaultValue: {'x': 1}), {'x': 1});
      expect(warns, isEmpty);
    });

    test('warns and returns default on type mismatch', () {
      final warns = <String>[];
      expect(readMap('config', {'config': 'not-a-map'}, warns), isNull);
      expect(warns, hasLength(1));
      expect(warns.first, contains('Invalid type for config'));
    });
  });

  group('readStringList', () {
    test('returns string elements when key exists with List value', () {
      final warns = <String>[];
      final result = readStringList('tags', {
        'tags': ['a', 'b', 'c'],
      }, warns);
      expect(result, ['a', 'b', 'c']);
      expect(warns, isEmpty);
    });

    test('returns defaultValue when key is absent', () {
      final warns = <String>[];
      expect(readStringList('tags', {}, warns, defaultValue: ['x']), ['x']);
      expect(warns, isEmpty);
    });

    test('warns and returns default on type mismatch', () {
      final warns = <String>[];
      expect(readStringList('tags', {'tags': 'not-a-list'}, warns), isNull);
      expect(warns, hasLength(1));
      expect(warns.first, contains('Invalid type for tags'));
    });
  });

  group('readField (generic)', () {
    test('returns value on type match', () {
      final warns = <String>[];
      expect(readField<int>('n', {'n': 5}, warns), 5);
      expect(warns, isEmpty);
    });

    test('warns and returns default on type mismatch', () {
      final warns = <String>[];
      expect(readField<int>('n', {'n': 'five'}, warns, defaultValue: 0), 0);
      expect(warns, hasLength(1));
    });
  });
}
