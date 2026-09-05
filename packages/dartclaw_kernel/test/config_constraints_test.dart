import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:test/test.dart';

void main() {
  group('FieldConstraints.evaluate', () {
    FieldConstraintViolation? evaluate(String path, Object? value) =>
        FieldConstraints.evaluate(ConfigMeta.fields[path]!, value);

    test('answers a range violation naming the declaration and the offending value', () {
      final violation = evaluate('context.warning_threshold', 49);

      expect(violation, isA<OutOfRange>());
      expect(violation!.field.yamlPath, 'context.warning_threshold');
      expect(violation.field.min, 50);
      expect(violation.field.max, 99);
      expect(violation.value, 49);
    });

    test('answers a membership violation naming the declaration and the offending value', () {
      final violation = evaluate('logging.level', 'DEBUG');

      expect(violation, isA<ValueNotAllowed>());
      expect(violation!.field.allowedValues, containsAll(['FINE', 'INFO', 'WARNING', 'SEVERE']));
      expect(violation.value, 'DEBUG');
    });

    test('one verdict serves a refusing caller and a warn-and-default caller alike', () {
      // The verdict carries no wording, so a caller that must warn and fall back
      // renders its own sentence from the same decision instead of adopting the
      // config API's refusal.
      final violation = evaluate('context.warning_threshold', 49)!;
      final meta = violation.field;

      expect(
        const ConfigValidator().validate({'context.warning_threshold': 49}).single.message,
        "Field 'context.warning_threshold' must be between 50 and 99, got 49",
      );
      expect(meta.yamlPath, 'context.warning_threshold');
      expect(violation.value, 49);
      // Nothing on the violation exposes an operator-facing sentence to copy.
      expect('$violation', isNot(contains('must be')));
      expect('$violation', isNot(contains('Field')));
    });

    test('decides nullability ahead of type, so a null never reports as a type error', () {
      expect(evaluate('port', null), isA<NullNotAllowed>());
      expect(evaluate('agent.max_turns', null), isNull);
      expect(evaluate('agent.model', null), isNull);
    });

    test('accepts a whole-number double for an integer field and refuses a fractional one', () {
      expect(evaluate('port', 3000.0), isNull);
      expect(evaluate('port', 3000.5), isA<TypeMismatch>());
      expect(evaluate('port', double.infinity), isA<TypeMismatch>());
      expect(evaluate('port', double.nan), isA<TypeMismatch>());
      // The range is judged on the integral value, not the submitted double.
      expect(evaluate('port', 70000.0), isA<OutOfRange>().having((v) => v.value, 'value', 70000));
    });

    test('applies each declared bound independently', () {
      expect(evaluate('sessions.reset_hour', -2), isA<OutOfRange>());
      expect(evaluate('sessions.reset_hour', 24), isA<OutOfRange>());
      expect(evaluate('sessions.reset_hour', -1), isNull);
      expect(evaluate('sessions.reset_hour', 0), isNull);
      expect(evaluate('agent.max_turns', 0), isA<OutOfRange>());
      expect(evaluate('agent.max_turns', 1 << 30), isNull);
    });

    test('refuses a blank non-nullable string but leaves a nullable one alone', () {
      expect(evaluate('host', '  '), isA<BlankString>());
      expect(evaluate('host', 7), isA<TypeMismatch>());
      expect(evaluate('agent.model', '  '), isNull);
    });

    test('types collection elements against the declared collection type', () {
      expect(evaluate('channels.google_chat.dm_allowlist', ['spaces/AAA/users/1', 7]), isA<ElementTypeMismatch>());
      expect(evaluate('channels.google_chat.dm_allowlist', 'spaces/AAA'), isA<TypeMismatch>());
      expect(
        evaluate('alerts.targets', [
          {'channel': 'signal', 'recipient': '+15550001111'},
        ]),
        isNull,
      );
      expect(evaluate('alerts.targets', [7]), isA<ElementTypeMismatch>());
      expect(evaluate('alerts.routes', 'x'), isA<TypeMismatch>());
    });

    test('honours allowedValues only for an enum-typed declaration', () {
      // `tasks.completion_action` declares allowedValues over a `string` type;
      // its loader enforces them and the write path never has. config_meta_test.dart
      // pins the full set of such declarations.
      expect(ConfigMeta.fields['tasks.completion_action']!.allowedValues, isNotNull);
      expect(evaluate('tasks.completion_action', 'bogus'), isNull);
      expect(evaluate('logging.level', 'DEBUG'), isA<ValueNotAllowed>());
    });
  });
}
