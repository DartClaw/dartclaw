import 'package:dartclaw_workflow/dartclaw_workflow.dart';
import 'package:test/test.dart';

import 'workflow_validator_test_support.dart';

void main() {
  late WorkflowDefinitionValidator validator;

  setUp(() {
    validator = WorkflowDefinitionValidator();
  });

  group('review-source prefixing rule', () {
    test('S03: a bare review_report_path on a parallel source feeding an aggregator is rejected', () {
      final def = buildDef(
        steps: [
          reviewSourceStep(
            id: 'review-a',
            outputs: const {
              // Bare — must be prefixed `review-a.review_report_path`.
              'review_report_path': OutputConfig(format: OutputFormat.path, schema: 'review_report_path'),
              'review-a.findings_count': OutputConfig(format: OutputFormat.json, schema: 'findings_count'),
              'review-a.gating_findings_count': OutputConfig(
                format: OutputFormat.json,
                schema: 'gating_findings_count',
              ),
            },
          ),
          reviewSourceStep(id: 'review-b'),
          aggregateReviewsStep(aggregateReviews: const ['review-a', 'review-b']),
        ],
      );

      final errors = validator.validate(def).errors;
      expect(
        errors,
        contains(
          isA<ValidationError>()
              .having((e) => e.type, 'type', ValidationErrorType.contextInconsistency)
              .having((e) => e.stepId, 'stepId', 'review-a')
              .having((e) => e.message, 'message', contains('review_report_path'))
              .having((e) => e.message, 'message', contains('review-a.review_report_path')),
        ),
        reason: 'error names the offending step and the required prefixed form',
      );
    });

    test('rejects a mis-prefixed review key (wrong source id) on an aggregate source', () {
      final def = buildDef(
        steps: [
          reviewSourceStep(
            id: 'review-a',
            outputs: const {
              // Prefixed with the wrong source id.
              'review-b.review_report_path': OutputConfig(format: OutputFormat.path, schema: 'review_report_path'),
              'review-a.findings_count': OutputConfig(format: OutputFormat.json, schema: 'findings_count'),
              'review-a.gating_findings_count': OutputConfig(
                format: OutputFormat.json,
                schema: 'gating_findings_count',
              ),
            },
          ),
          aggregateReviewsStep(),
        ],
      );

      final errors = validator.validate(def).errors;
      expect(
        errors,
        contains(
          isA<ValidationError>()
              .having((e) => e.stepId, 'stepId', 'review-a')
              .having((e) => e.message, 'message', contains('review-a.review_report_path')),
        ),
      );
    });

    test('trigger boundary: a single source feeding an aggregator still requires prefixing', () {
      final def = buildDef(
        steps: [
          reviewSourceStep(
            id: 'review-a',
            outputs: const {
              'review_report_path': OutputConfig(format: OutputFormat.path, schema: 'review_report_path'),
              'review-a.findings_count': OutputConfig(format: OutputFormat.json, schema: 'findings_count'),
              'review-a.gating_findings_count': OutputConfig(
                format: OutputFormat.json,
                schema: 'gating_findings_count',
              ),
            },
          ),
          aggregateReviewsStep(aggregateReviews: const ['review-a']),
        ],
      );

      expect(
        hasError(validator.validate(def).errors, stepId: 'review-a', messageContains: 'review-a.review_report_path'),
        isTrue,
      );
    });

    test('prefixed review keys on aggregate sources pass', () {
      final def = buildDef(
        steps: [
          reviewSourceStep(id: 'review-a'),
          aggregateReviewsStep(),
        ],
      );

      expect(validator.validate(def).errors, isEmpty);
    });

    test('S04: a single review step with no aggregator keeps bare canonical keys', () {
      final def = buildDef(
        steps: [
          const WorkflowStep(
            id: 'review-code',
            name: 'Review',
            prompts: ['p'],
            outputs: {
              'review_report_path': OutputConfig(format: OutputFormat.path, schema: 'review_report_path'),
              'findings_count': OutputConfig(format: OutputFormat.json, schema: 'findings_count'),
              'gating_findings_count': OutputConfig(format: OutputFormat.json, schema: 'gating_findings_count'),
            },
          ),
        ],
      );

      expect(
        validator.validate(def).errors,
        isEmpty,
        reason: 'the prefixing rule fires only for sources feeding an aggregate-reviews step',
      );
    });
  });
}
