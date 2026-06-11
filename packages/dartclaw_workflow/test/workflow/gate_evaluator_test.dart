import 'package:dartclaw_workflow/dartclaw_workflow.dart' show GateEvaluator, WorkflowContext;
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
    test('evaluates comparison and conjunction expressions', () {
      final cases = <({String expression, bool expected})>[
        (expression: 'step1.status == accepted', expected: true),
        (expression: 'step1.status == failed', expected: false),
        (expression: 'step1.status != failed', expected: true),
        (expression: 'step1.status != accepted', expected: false),
        (expression: 'step1.tokenCount < 50000', expected: true),
        (expression: 'step1.tokenCount < 10000', expected: false),
        (expression: 'step1.tokenCount > 20000', expected: true),
        (expression: 'step1.tokenCount > 50000', expected: false),
        (expression: 'step1.tokenCount <= 30000', expected: true),
        (expression: 'step1.tokenCount >= 30000', expected: true),
        (expression: 'step1.status == accepted && step1.tokenCount < 50000', expected: true),
        (expression: 'step1.status == failed && step1.tokenCount < 50000', expected: false),
        (expression: 'step1.status == accepted && step1.tokenCount > 50000', expected: false),
        (expression: 'step1.status == accepted && step2.status == failed && step2.tokenCount < 10000', expected: true),
      ];

      for (final (:expression, :expected) in cases) {
        expect(evaluator.evaluate(expression, context), expected, reason: expression);
      }
    });

    test('fails closed for missing keys and malformed expressions', () {
      final ctx = WorkflowContext(data: {'a': 1, 'b': 1});
      final cases = <({String expression, WorkflowContext context, bool expected})>[
        (expression: 'missing.key == value', context: context, expected: false),
        (expression: 'review.findings_count == 0', context: context, expected: true),
        (expression: 'review.findings_count > 0', context: context, expected: false),
        (expression: 'not a valid gate', context: context, expected: false),
        (expression: 'a > 0 || not a valid gate', context: ctx, expected: false),
        (expression: 'a > 0 || b > 0 < 1', context: ctx, expected: false),
        (expression: 'a > 0 || b>0<1', context: ctx, expected: false),
        (expression: 'a > 0 ||', context: ctx, expected: false),
        (expression: '|| a > 0', context: ctx, expected: false),
        (expression: 'a > 0 || || a > 0', context: ctx, expected: false),
        (expression: 'a > 0 && || b > 0', context: ctx, expected: false),
        (expression: 'a > 0 || b > 0 &&', context: ctx, expected: false),
        (expression: '', context: context, expected: false),
      ];

      for (final (:expression, :context, :expected) in cases) {
        expect(evaluator.evaluate(expression, context), expected, reason: expression);
      }
    });

    test('handles string and numeric fallback comparisons', () {
      final stringContext = WorkflowContext(data: {'a': 'apple', 'b': 'banana'});
      final validatorContext = WorkflowContext(
        data: {'branch': 'feature/foo', 'quoted': '"feature/foo"', 'label': 'needs review'},
      );
      final nonNumericContext = WorkflowContext(data: {'findings_count': 'many'});
      final cases = <({String expression, WorkflowContext context, bool expected})>[
        (expression: 'a == apple', context: stringContext, expected: true),
        (expression: 'a != banana', context: stringContext, expected: true),
        (expression: 'branch == feature/foo', context: validatorContext, expected: true),
        (expression: 'quoted == "feature/foo"', context: validatorContext, expected: true),
        (expression: 'label == needs review', context: validatorContext, expected: true),
        (expression: 'findings_count > 0', context: nonNumericContext, expected: false),
        (expression: 'findings_count <= 0', context: nonNumericContext, expected: false),
      ];

      for (final (:expression, :context, :expected) in cases) {
        expect(evaluator.evaluate(expression, context), expected, reason: expression);
      }
    });

    test('evaluates || with && precedence', () {
      final cases = <({String expression, WorkflowContext context, bool expected})>[
        (expression: 'a > 0 || b > 0', context: WorkflowContext(data: {'a': 1, 'b': 0}), expected: true),
        (expression: 'a > 0 || b > 0', context: WorkflowContext(data: {'a': 0, 'b': 1}), expected: true),
        (expression: 'a > 0 || b > 0', context: WorkflowContext(data: {'a': 0, 'b': 0}), expected: false),
        (
          expression: 'a > 0 || b > 0 && c > 0',
          context: WorkflowContext(data: {'a': 1, 'b': 0, 'c': 0}),
          expected: true,
        ),
      ];

      for (final (:expression, :context, :expected) in cases) {
        expect(evaluator.evaluate(expression, context), expected, reason: expression);
      }
    });

    test('evaluates workflow remediation gates', () {
      final cases = <({String expression, WorkflowContext context, bool expected})>[
        (
          expression: 're-review.gating_findings_count == 0',
          context: WorkflowContext(data: {'re-review.findings_count': 3, 're-review.gating_findings_count': 0}),
          expected: true,
        ),
        (
          expression: 're-review.gating_findings_count == 0',
          context: WorkflowContext(data: {'re-review.findings_count': 3, 're-review.gating_findings_count': 1}),
          expected: false,
        ),
      ];

      for (final (:expression, :context, :expected) in cases) {
        expect(evaluator.evaluate(expression, context), expected, reason: expression);
      }
    });

    test('tolerates stray "context." prefix on gate keys', () {
      final cases = [
        'context.step1.status == accepted',
        'context.step2.tokenCount < 10000',
        'context.step1.status == accepted && step2.tokenCount < 10000',
      ];

      for (final expression in cases) {
        expect(evaluator.evaluate(expression, context), isTrue, reason: expression);
      }
    });

    test('unary empty checks handle strings, lists, maps, and missing values', () {
      final ctx = WorkflowContext(
        data: {
          'empty_string': '',
          'empty_list': <String>[],
          'items': ['S01'],
          'empty_map': <String, dynamic>{},
          'object': {'id': 'S01'},
        },
      );
      final cases = <({String expression, bool expected})>[
        (expression: 'empty_string isEmpty', expected: true),
        (expression: 'empty_list isEmpty', expected: true),
        (expression: 'items isNotEmpty', expected: true),
        (expression: 'empty_map isEmpty', expected: true),
        (expression: 'object isNotEmpty', expected: true),
        (expression: 'missing isEmpty', expected: true),
      ];

      for (final (:expression, :expected) in cases) {
        expect(evaluator.evaluate(expression, ctx), expected, reason: expression);
      }
    });

    test('null-literal equality handles missing, empty, literal, and nested values', () {
      final cases = <({String expression, WorkflowContext context, bool expected})>[
        (expression: 'active_prd == null', context: context, expected: true),
        (expression: 'active_prd != null', context: context, expected: false),
        (expression: 'active_prd == null', context: WorkflowContext(data: {'active_prd': ''}), expected: true),
        (expression: 'active_prd != null', context: WorkflowContext(data: {'active_prd': ''}), expected: false),
        (
          expression: 'active_prd != null',
          context: WorkflowContext(data: {'active_prd': 'docs/specs/0.16.5/prd.md'}),
          expected: true,
        ),
        (
          expression: 'active_prd == null',
          context: WorkflowContext(data: {'active_prd': 'docs/specs/0.16.5/prd.md'}),
          expected: false,
        ),
        (expression: 'active_prd == null', context: WorkflowContext(data: {'active_prd': 'null'}), expected: true),
        (expression: 'active_prd != null', context: WorkflowContext(data: {'active_prd': 'null'}), expected: false),
        (
          expression: 'project_index.active_prd != null',
          context: WorkflowContext(
            data: {
              'project_index': {'active_prd': 'docs/specs/0.16.5/prd.md', 'active_plan': null},
            },
          ),
          expected: true,
        ),
        (
          expression: 'project_index.active_plan == null',
          context: WorkflowContext(
            data: {
              'project_index': {'active_prd': 'docs/specs/0.16.5/prd.md', 'active_plan': null},
            },
          ),
          expected: true,
        ),
        (expression: 'x > 0', context: context, expected: false),
        (expression: 'x == 0', context: context, expected: true),
        (
          expression: 'prd_source == synthesized && findings_count > 0 && active_plan == null',
          context: WorkflowContext(data: {'prd_source': 'synthesized', 'findings_count': '3'}),
          expected: true,
        ),
      ];

      for (final (:expression, :context, :expected) in cases) {
        expect(evaluator.evaluate(expression, context), expected, reason: expression);
      }
    });
  });
}
