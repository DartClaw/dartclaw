import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

void main() {
  late SchemaValidator validator;

  setUp(() {
    validator = const SchemaValidator();
  });

  group('SchemaValidator.validate', () {
    group('object validation', () {
      const objectSchema = {
        'type': 'object',
        'required': ['pass', 'summary'],
        'properties': {
          'pass': {'type': 'boolean'},
          'summary': {'type': 'string'},
          'count': {'type': 'integer'},
        },
      };

      test('valid object returns no warnings', () {
        final value = {'pass': true, 'summary': 'looks good', 'count': 3};
        expect(validator.validate(value, objectSchema), isEmpty);
      });

      test('missing required field returns warning', () {
        final value = {'pass': true}; // missing summary
        final warnings = validator.validate(value, objectSchema);
        expect(warnings, hasLength(1));
        expect(warnings.first, contains('Missing required field "summary"'));
      });

      test('wrong type returns warning', () {
        final value = {'pass': 'yes', 'summary': 'ok'}; // pass should be bool
        final warnings = validator.validate(value, objectSchema);
        expect(warnings, hasLength(1));
        expect(warnings.first, contains('Expected boolean'));
      });

      test('extra fields cause no warnings (lenient)', () {
        final value = {
          'pass': true,
          'summary': 'ok',
          'extra_field': 'ignored',
        };
        expect(validator.validate(value, objectSchema), isEmpty);
      });

      test('missing optional field causes no warning', () {
        // count is not in required, so missing is fine.
        final value = {'pass': true, 'summary': 'ok'};
        expect(validator.validate(value, objectSchema), isEmpty);
      });

      test('non-object value with object schema returns warning', () {
        final warnings = validator.validate('not an object', objectSchema);
        expect(warnings, hasLength(1));
        expect(warnings.first, contains('Expected object'));
      });
    });

    group('array validation', () {
      const arraySchema = {
        'type': 'array',
        'items': {
          'type': 'object',
          'required': ['id'],
          'properties': {
            'id': {'type': 'string'},
            'title': {'type': 'string'},
          },
        },
      };

      test('valid array returns no warnings', () {
        final value = [
          {'id': 's01', 'title': 'First'},
          {'id': 's02'},
        ];
        expect(validator.validate(value, arraySchema), isEmpty);
      });

      test('invalid item triggers warning with index path', () {
        final value = [
          {'id': 's01'},
          {'title': 'no id'}, // missing required id
        ];
        final warnings = validator.validate(value, arraySchema);
        expect(warnings, hasLength(1));
        expect(warnings.first, contains('[1]'));
        expect(warnings.first, contains('Missing required field "id"'));
      });

      test('non-array value with array schema returns warning', () {
        final warnings = validator.validate({'key': 'val'}, arraySchema);
        expect(warnings, hasLength(1));
        expect(warnings.first, contains('Expected array'));
      });

      test('empty array returns no warnings', () {
        expect(validator.validate([], arraySchema), isEmpty);
      });
    });

    group('type checks', () {
      test('string type accepts String', () {
        expect(
          validator.validate('hello', {'type': 'string'}),
          isEmpty,
        );
      });

      test('string type rejects int', () {
        expect(
          validator.validate(42, {'type': 'string'}),
          hasLength(1),
        );
      });

      test('integer type accepts int', () {
        expect(
          validator.validate(5, {'type': 'integer'}),
          isEmpty,
        );
      });

      test('integer type accepts whole-number double (JSON int-as-double)', () {
        // JSON decoder may return 3000.0 for integer 3000.
        expect(
          validator.validate(3000.0, {'type': 'integer'}),
          isEmpty,
        );
      });

      test('integer type rejects fractional double', () {
        expect(
          validator.validate(3.14, {'type': 'integer'}),
          hasLength(1),
        );
      });

      test('number type accepts int', () {
        expect(
          validator.validate(42, {'type': 'number'}),
          isEmpty,
        );
      });

      test('number type accepts double', () {
        expect(
          validator.validate(3.14, {'type': 'number'}),
          isEmpty,
        );
      });

      test('number type rejects string', () {
        expect(
          validator.validate('3.14', {'type': 'number'}),
          hasLength(1),
        );
      });

      test('boolean type accepts bool', () {
        expect(
          validator.validate(true, {'type': 'boolean'}),
          isEmpty,
        );
      });

      test('boolean type rejects string', () {
        expect(
          validator.validate('true', {'type': 'boolean'}),
          hasLength(1),
        );
      });
    });

    group('nested validation', () {
      const nestedSchema = {
        'type': 'object',
        'required': ['findings'],
        'properties': {
          'findings': {
            'type': 'array',
            'items': {
              'type': 'object',
              'required': ['severity'],
              'properties': {
                'severity': {'type': 'string'},
              },
            },
          },
        },
      };

      test('valid nested structure returns no warnings', () {
        final value = {
          'findings': [
            {'severity': 'high'},
          ],
        };
        expect(validator.validate(value, nestedSchema), isEmpty);
      });

      test('missing required field in nested item shows path', () {
        final value = {
          'findings': [
            {'description': 'no severity'},
          ],
        };
        final warnings = validator.validate(value, nestedSchema);
        expect(warnings, hasLength(1));
        expect(warnings.first, contains('findings[0]'));
        expect(warnings.first, contains('Missing required field "severity"'));
      });
    });

    group('verdict schema validation', () {
      test('valid verdict object passes', () {
        final value = {
          'pass': true,
          'findings_count': 0,
          'findings': [],
          'summary': 'All good',
        };
        expect(
          validator.validate(value, verdictPreset.schema),
          isEmpty,
        );
      });

      test('missing pass field returns warning', () {
        final value = {
          'findings_count': 0,
          'findings': [],
          'summary': 'ok',
        };
        final warnings = validator.validate(value, verdictPreset.schema);
        expect(warnings.any((w) => w.contains('"pass"')), true);
      });
    });

    group('schema with no type', () {
      test('returns no warnings when schema has no type', () {
        // Edge case: schema without 'type' field — validator does nothing.
        expect(validator.validate({'any': 'value'}, {}), isEmpty);
      });
    });
  });
}
