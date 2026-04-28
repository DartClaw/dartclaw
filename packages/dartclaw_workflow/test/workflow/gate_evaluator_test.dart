import 'package:dartclaw_workflow/dartclaw_workflow.dart' show WorkflowContext;
import 'package:dartclaw_workflow/dartclaw_workflow.dart' show GateEvaluator;
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
      expect(evaluator.evaluate('step1.status == accepted && step1.tokenCount < 50000', context), isTrue);
    });

    test('&& conjunction fails when first condition fails', () {
      expect(evaluator.evaluate('step1.status == failed && step1.tokenCount < 50000', context), isFalse);
    });

    test('&& conjunction fails when second condition fails', () {
      expect(evaluator.evaluate('step1.status == accepted && step1.tokenCount > 50000', context), isFalse);
    });

    test('missing context key returns false (fail-safe)', () {
      expect(evaluator.evaluate('missing.key == value', context), isFalse);
    });

    test('missing numeric context key defaults to 0', () {
      expect(evaluator.evaluate('review.findings_count == 0', context), isTrue);
      expect(evaluator.evaluate('review.findings_count > 0', context), isFalse);
    });

    test('malformed expression returns false (fail-safe)', () {
      expect(evaluator.evaluate('not a valid gate', context), isFalse);
    });

    test('malformed expression inside || returns false even when another clause is true', () {
      final ctx = WorkflowContext(data: {'a': 1});
      expect(evaluator.evaluate('a > 0 || not a valid gate', ctx), isFalse);
    });

    test('unsupported extra operator syntax inside || returns false fail-safe', () {
      final ctx = WorkflowContext(data: {'a': 1, 'b': 1});
      expect(evaluator.evaluate('a > 0 || b > 0 < 1', ctx), isFalse);
      expect(evaluator.evaluate('a > 0 || b>0<1', ctx), isFalse);
    });

    test('string comparison fallback when non-numeric values', () {
      final strContext = WorkflowContext(data: {'a': 'apple', 'b': 'banana'});
      expect(evaluator.evaluate('a == apple', strContext), isTrue);
      expect(evaluator.evaluate('a != banana', strContext), isTrue);
    });

    test('string comparison accepts validator-compatible values', () {
      final strContext = WorkflowContext(
        data: {'branch': 'feature/foo', 'quoted': '"feature/foo"', 'label': 'needs review'},
      );
      expect(evaluator.evaluate('branch == feature/foo', strContext), isTrue);
      expect(evaluator.evaluate('quoted == "feature/foo"', strContext), isTrue);
      expect(evaluator.evaluate('label == needs review', strContext), isTrue);
    });

    test('multiple && conditions all true', () {
      expect(
        evaluator.evaluate('step1.status == accepted && step2.status == failed && step2.tokenCount < 10000', context),
        isTrue,
      );
    });

    test('|| returns true when first clause is true', () {
      final ctx = WorkflowContext(data: {'a': 1, 'b': 0});
      expect(evaluator.evaluate('a > 0 || b > 0', ctx), isTrue);
    });

    test('|| returns true when second clause is true', () {
      final ctx = WorkflowContext(data: {'a': 0, 'b': 1});
      expect(evaluator.evaluate('a > 0 || b > 0', ctx), isTrue);
    });

    test('|| returns false when both clauses are false', () {
      final ctx = WorkflowContext(data: {'a': 0, 'b': 0});
      expect(evaluator.evaluate('a > 0 || b > 0', ctx), isFalse);
    });

    test('&& binds tighter than ||', () {
      final ctx = WorkflowContext(data: {'a': 1, 'b': 0, 'c': 0});
      expect(evaluator.evaluate('a > 0 || b > 0 && c > 0', ctx), isTrue);
    });

    test('empty || branches return false fail-safe', () {
      final ctx = WorkflowContext(data: {'a': 1});
      expect(evaluator.evaluate('a > 0 ||', ctx), isFalse);
      expect(evaluator.evaluate('|| a > 0', ctx), isFalse);
      expect(evaluator.evaluate('a > 0 || || a > 0', ctx), isFalse);
    });

    test('empty && branches inside || return false fail-safe', () {
      final ctx = WorkflowContext(data: {'a': 1, 'b': 1});
      expect(evaluator.evaluate('a > 0 && || b > 0', ctx), isFalse);
      expect(evaluator.evaluate('a > 0 || b > 0 &&', ctx), isFalse);
    });

    test('remediation loop exits with LOW-only findings', () {
      final ctx = WorkflowContext(data: {'re-review.findings_count': 3, 're-review.gating_findings_count': 0});
      expect(evaluator.evaluate('re-review.gating_findings_count == 0', ctx), isTrue);
    });

    test('remediation loop continues on MEDIUM finding', () {
      final ctx = WorkflowContext(data: {'re-review.findings_count': 3, 're-review.gating_findings_count': 1});
      expect(evaluator.evaluate('re-review.gating_findings_count == 0', ctx), isFalse);
    });

    test('empty expression evaluates as true (no conditions)', () {
      // Split by && on empty string gives [''] — one empty condition.
      // An empty condition doesn't match the regex → false.
      expect(evaluator.evaluate('', context), isFalse);
    });

    test('tolerates stray "context." prefix on gate keys', () {
      // Prompt templates require `context.` but gate keys do not. The evaluator
      // strips a stray prefix so authors mixing the two syntaxes still succeed.
      expect(evaluator.evaluate('context.step1.status == accepted', context), isTrue);
      expect(evaluator.evaluate('context.step2.tokenCount < 10000', context), isTrue);
      expect(evaluator.evaluate('context.step1.status == accepted && step2.tokenCount < 10000', context), isTrue);
    });

    group('null-literal equality', () {
      test('missing key == null evaluates true', () {
        expect(evaluator.evaluate('active_prd == null', context), isTrue);
      });

      test('missing key != null evaluates false', () {
        expect(evaluator.evaluate('active_prd != null', context), isFalse);
      });

      test('empty-string value == null evaluates true', () {
        final ctx = WorkflowContext(data: {'active_prd': ''});
        expect(evaluator.evaluate('active_prd == null', ctx), isTrue);
        expect(evaluator.evaluate('active_prd != null', ctx), isFalse);
      });

      test('non-empty, non-"null" value != null evaluates true', () {
        final ctx = WorkflowContext(data: {'active_prd': 'docs/specs/0.16.5/prd.md'});
        expect(evaluator.evaluate('active_prd != null', ctx), isTrue);
        expect(evaluator.evaluate('active_prd == null', ctx), isFalse);
      });

      test('literal "null" string value == null evaluates true', () {
        final ctx = WorkflowContext(data: {'active_prd': 'null'});
        expect(evaluator.evaluate('active_prd == null', ctx), isTrue);
        expect(evaluator.evaluate('active_prd != null', ctx), isFalse);
      });

      test('dotted map value can be compared with null literal', () {
        final ctx = WorkflowContext(
          data: {
            'project_index': {'active_prd': 'docs/specs/0.16.5/prd.md', 'active_plan': null},
          },
        );
        expect(evaluator.evaluate('project_index.active_prd != null', ctx), isTrue);
        expect(evaluator.evaluate('project_index.active_plan == null', ctx), isTrue);
      });

      test('numeric gate with missing key still uses empty→0 fallback', () {
        // Ensures null-literal logic did not regress numeric semantics.
        expect(evaluator.evaluate('x > 0', context), isFalse);
        expect(evaluator.evaluate('x == 0', context), isTrue);
      });

      test('null-literal equality composes with && like other conditions', () {
        final ctx = WorkflowContext(data: {'prd_source': 'synthesized', 'findings_count': '3'});
        expect(
          evaluator.evaluate('prd_source == synthesized && findings_count > 0 && active_plan == null', ctx),
          isTrue,
        );
      });
    });
  });
}
