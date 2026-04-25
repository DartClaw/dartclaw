@Tags(['component'])
library;

import 'package:dartclaw_workflow/dartclaw_workflow.dart';
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
        final value = {'pass': true, 'summary': 'ok', 'extra_field': 'ignored'};
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
        expect(validator.validate('hello', {'type': 'string'}), isEmpty);
      });

      test('string type rejects int', () {
        expect(validator.validate(42, {'type': 'string'}), hasLength(1));
      });

      test('integer type accepts int', () {
        expect(validator.validate(5, {'type': 'integer'}), isEmpty);
      });

      test('integer type accepts whole-number double (JSON int-as-double)', () {
        // JSON decoder may return 3000.0 for integer 3000.
        expect(validator.validate(3000.0, {'type': 'integer'}), isEmpty);
      });

      test('integer type rejects fractional double', () {
        expect(validator.validate(3.14, {'type': 'integer'}), hasLength(1));
      });

      test('number type accepts int', () {
        expect(validator.validate(42, {'type': 'number'}), isEmpty);
      });

      test('number type accepts double', () {
        expect(validator.validate(3.14, {'type': 'number'}), isEmpty);
      });

      test('number type rejects string', () {
        expect(validator.validate('3.14', {'type': 'number'}), hasLength(1));
      });

      test('boolean type accepts bool', () {
        expect(validator.validate(true, {'type': 'boolean'}), isEmpty);
      });

      test('boolean type rejects string', () {
        expect(validator.validate('true', {'type': 'boolean'}), hasLength(1));
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
        final value = {'pass': true, 'findings_count': 0, 'findings': [], 'summary': 'All good'};
        expect(validator.validate(value, verdictPreset.schema), isEmpty);
      });

      test('missing pass field returns warning', () {
        final value = {'findings_count': 0, 'findings': [], 'summary': 'ok'};
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

    group('additionalProperties: false enforcement', () {
      const strictSchema = {
        'type': 'object',
        'properties': {
          'name': {'type': 'string'},
        },
        'additionalProperties': false,
      };

      test('no extra fields returns no warnings', () {
        expect(validator.validate({'name': 'Alice'}, strictSchema), isEmpty);
      });

      test('extra field returns warning', () {
        final warnings = validator.validate({'name': 'Alice', 'extra': 1}, strictSchema);
        expect(warnings, hasLength(1));
        expect(warnings.first, contains('Unexpected property "extra"'));
      });

      test('schema without additionalProperties:false allows extra fields', () {
        const lenient = {
          'type': 'object',
          'properties': {'name': {'type': 'string'}},
        };
        expect(validator.validate({'name': 'Alice', 'extra': 1}, lenient), isEmpty);
      });
    });

    group('enum enforcement', () {
      test('string matching enum passes', () {
        expect(validator.validate('low', {'type': 'string', 'enum': ['low', 'medium', 'high']}), isEmpty);
      });

      test('string not in enum returns warning', () {
        final warnings = validator.validate('critical', {'type': 'string', 'enum': ['low', 'medium', 'high']});
        expect(warnings, hasLength(1));
        expect(warnings.first, contains('"critical"'));
        expect(warnings.first, contains('"low"'));
      });

      test('integer matching enum passes', () {
        expect(validator.validate(1, {'type': 'integer', 'enum': [1, 2, 3]}), isEmpty);
      });

      test('integer not in enum returns warning', () {
        final warnings = validator.validate(5, {'type': 'integer', 'enum': [1, 2, 3]});
        expect(warnings, hasLength(1));
        expect(warnings.first, contains('5'));
      });
    });

    group('numeric bounds enforcement', () {
      test('value at minimum boundary passes', () {
        expect(validator.validate(0, {'type': 'integer', 'minimum': 0}), isEmpty);
      });

      test('value below minimum returns warning', () {
        final warnings = validator.validate(-1, {'type': 'integer', 'minimum': 0});
        expect(warnings, hasLength(1));
        expect(warnings.first, contains('minimum 0'));
      });

      test('value at maximum boundary passes', () {
        expect(validator.validate(10, {'type': 'integer', 'maximum': 10}), isEmpty);
      });

      test('value above maximum returns warning', () {
        final warnings = validator.validate(11, {'type': 'integer', 'maximum': 10});
        expect(warnings, hasLength(1));
        expect(warnings.first, contains('maximum 10'));
      });

      test('number type respects minimum and maximum', () {
        expect(validator.validate(3.14, {'type': 'number', 'minimum': 0.0, 'maximum': 5.0}), isEmpty);
        expect(validator.validate(-0.1, {'type': 'number', 'minimum': 0.0}), hasLength(1));
      });

      test('max_parallel:0 triggers minimum warning when minimum is 1', () {
        final warnings = validator.validate(0, {'type': 'integer', 'minimum': 1});
        expect(warnings, hasLength(1));
        expect(warnings.first, contains('minimum 1'));
      });

      test('negative max_parallel triggers minimum warning when minimum is 1', () {
        final warnings = validator.validate(-3, {'type': 'integer', 'minimum': 1});
        expect(warnings, hasLength(1));
        expect(warnings.first, contains('minimum 1'));
      });
    });
  });
}
