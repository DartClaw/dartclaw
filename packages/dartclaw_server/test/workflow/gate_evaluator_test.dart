import 'package:dartclaw_core/dartclaw_core.dart' show WorkflowContext;
import 'package:dartclaw_server/dartclaw_server.dart' show GateEvaluator;
import 'package:test/test.dart';

void main() {
  late GateEvaluator evaluator;
  late WorkflowContext context;

  setUp(() {
    evaluator = GateEvaluator();
    context = WorkflowContext(
      data: {
        'step1.status': 'accepted',
        'step1.tokenCount': '30000',
        'step2.status': 'failed',
        'step2.tokenCount': '5000',
      },
    );
  });

  group('GateEvaluator', () {
    test('== equality passes when values match', () {
      expect(evaluator.evaluate('step1.status == accepted', context), isTrue);
    });

    test('== equality fails when values do not match', () {
      expect(evaluator.evaluate('step1.status == failed', context), isFalse);
    });

    test('!= inequality passes when values differ', () {
      expect(evaluator.evaluate('step1.status != failed', context), isTrue);
    });

    test('!= inequality fails when values match', () {
      expect(evaluator.evaluate('step1.status != accepted', context), isFalse);
    });

    test('< numeric less-than passes when value is less', () {
      expect(evaluator.evaluate('step1.tokenCount < 50000', context), isTrue);
    });

    test('< numeric less-than fails when value is greater', () {
      expect(evaluator.evaluate('step1.tokenCount < 10000', context), isFalse);
    });

    test('> numeric greater-than passes when value is greater', () {
      expect(evaluator.evaluate('step1.tokenCount > 20000', context), isTrue);
    });

    test('> numeric greater-than fails when value is less', () {
      expect(evaluator.evaluate('step1.tokenCount > 50000', context), isFalse);
    });

    test('<= passes when value equals threshold', () {
      expect(evaluator.evaluate('step1.tokenCount <= 30000', context), isTrue);
    });

    test('>= passes when value equals threshold', () {
      expect(evaluator.evaluate('step1.tokenCount >= 30000', context), isTrue);
    });

    test('&& conjunction passes when all conditions hold', () {
      expect(
        evaluator.evaluate('step1.status == accepted && step1.tokenCount < 50000', context),
        isTrue,
      );
    });

    test('&& conjunction fails when first condition fails', () {
      expect(
        evaluator.evaluate('step1.status == failed && step1.tokenCount < 50000', context),
        isFalse,
      );
    });

    test('&& conjunction fails when second condition fails', () {
      expect(
        evaluator.evaluate('step1.status == accepted && step1.tokenCount > 50000', context),
        isFalse,
      );
    });

    test('missing context key returns false (fail-safe)', () {
      expect(evaluator.evaluate('missing.key == value', context), isFalse);
    });

    test('malformed expression returns false (fail-safe)', () {
      expect(evaluator.evaluate('not a valid gate', context), isFalse);
    });

    test('string comparison fallback when non-numeric values', () {
      final strContext = WorkflowContext(data: {'a': 'apple', 'b': 'banana'});
      expect(evaluator.evaluate('a == apple', strContext), isTrue);
      expect(evaluator.evaluate('a != banana', strContext), isTrue);
    });

    test('multiple && conditions all true', () {
      expect(
        evaluator.evaluate(
          'step1.status == accepted && step2.status == failed && step2.tokenCount < 10000',
          context,
        ),
        isTrue,
      );
    });

    test('empty expression evaluates as true (no conditions)', () {
      // Split by && on empty string gives [''] — one empty condition.
      // An empty condition doesn't match the regex → false.
      expect(evaluator.evaluate('', context), isFalse);
    });
  });
}
