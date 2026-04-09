import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

void main() {
  late PromptAugmenter augmenter;

  setUp(() {
    augmenter = const PromptAugmenter();
  });

  group('PromptAugmenter.augment', () {
    test('returns prompt unchanged when outputs is null', () {
      const prompt = 'Do something useful';
      expect(augmenter.augment(prompt, null), prompt);
    });

    test('returns prompt unchanged when outputs is empty', () {
      const prompt = 'Do something useful';
      expect(augmenter.augment(prompt, {}), prompt);
    });

    test('returns prompt unchanged when all outputs are text format', () {
      const prompt = 'Do something useful';
      final outputs = {
        'result': const OutputConfig(format: OutputFormat.text),
      };
      expect(augmenter.augment(prompt, outputs), prompt);
    });

    test('returns prompt unchanged for lines format (no schema)', () {
      const prompt = 'List things';
      final outputs = {
        'items': const OutputConfig(format: OutputFormat.lines),
      };
      expect(augmenter.augment(prompt, outputs), prompt);
    });

    group('preset schema augmentation', () {
      test('appends Required Output Format section for verdict preset', () {
        const prompt = 'Review this code';
        final outputs = {
          'review': const OutputConfig(
            format: OutputFormat.json,
            schema: 'verdict',
          ),
        };
        final result = augmenter.augment(prompt, outputs);
        expect(result, contains('## Required Output Format'));
        expect(result, startsWith('Review this code'));
        expect(result, contains('pass'));
        expect(result, contains('findings'));
      });

      test('appends section for story-plan preset', () {
        const prompt = 'Plan the work';
        final outputs = {
          'stories': const OutputConfig(
            format: OutputFormat.json,
            schema: 'story-plan',
          ),
        };
        final result = augmenter.augment(prompt, outputs);
        expect(result, contains('## Required Output Format'));
        expect(result, contains('dependencies'));
      });

      test('appends section for checklist preset', () {
        const prompt = 'Check these items';
        final outputs = {
          'items': const OutputConfig(
            format: OutputFormat.json,
            schema: 'checklist',
          ),
        };
        final result = augmenter.augment(prompt, outputs);
        expect(result, contains('## Required Output Format'));
        expect(result, contains('all_pass'));
      });

      test('appends section for file-list preset', () {
        const prompt = 'List files';
        final outputs = {
          'files': const OutputConfig(
            format: OutputFormat.json,
            schema: 'file-list',
          ),
        };
        final result = augmenter.augment(prompt, outputs);
        expect(result, contains('## Required Output Format'));
        expect(result, contains('path'));
      });
    });

    group('evaluator default', () {
      test('applies verdict preset when evaluator=true, json format, no schema', () {
        const prompt = 'Evaluate this';
        final outputs = {
          'result': const OutputConfig(format: OutputFormat.json),
        };
        final result = augmenter.augment(prompt, outputs, evaluator: true);
        expect(result, contains('## Required Output Format'));
        expect(result, contains('pass'));
        expect(result, contains('findings'));
      });

      test('does NOT apply evaluator default when explicit schema present', () {
        const prompt = 'Evaluate this';
        final outputs = {
          'result': const OutputConfig(
            format: OutputFormat.json,
            schema: 'checklist', // explicit, not verdict
          ),
        };
        final result = augmenter.augment(prompt, outputs, evaluator: true);
        expect(result, contains('## Required Output Format'));
        // Should have checklist content, not verdict content.
        expect(result, contains('all_pass'));
        // verdict-specific content should NOT appear from evaluator default.
        expect(result, isNot(contains('findings_count')));
      });

      test('does NOT apply evaluator default when evaluator=false', () {
        const prompt = 'Just a step';
        final outputs = {
          'result': const OutputConfig(format: OutputFormat.json),
        };
        // No schema, no evaluator flag → no augmentation.
        final result = augmenter.augment(prompt, outputs);
        expect(result, prompt);
      });
    });

    group('inline schema augmentation', () {
      test('generates property list from inline object schema', () {
        const prompt = 'Produce output';
        final schema = {
          'type': 'object',
          'required': ['name', 'value'],
          'properties': {
            'name': {'type': 'string'},
            'value': {'type': 'integer'},
            'note': {'type': 'string'},
          },
        };
        final outputs = {
          'result': OutputConfig(
            format: OutputFormat.json,
            schema: schema,
          ),
        };
        final result = augmenter.augment(prompt, outputs);
        expect(result, contains('## Required Output Format'));
        expect(result, contains('name (string)'));
        expect(result, contains('value (integer)'));
        expect(result, contains('note (string, optional)'));
      });

      test('generates item list from inline array schema', () {
        const prompt = 'List things';
        final schema = {
          'type': 'array',
          'items': {
            'type': 'object',
            'required': ['id'],
            'properties': {
              'id': {'type': 'string'},
              'label': {'type': 'string'},
            },
          },
        };
        final outputs = {
          'items': OutputConfig(
            format: OutputFormat.json,
            schema: schema,
          ),
        };
        final result = augmenter.augment(prompt, outputs);
        expect(result, contains('## Required Output Format'));
        expect(result, contains('id (string)'));
        expect(result, contains('label (string, optional)'));
      });
    });

    group('multiple outputs', () {
      test('includes fragments from all json outputs with schemas', () {
        const prompt = 'Multi output step';
        final outputs = {
          'verdict': const OutputConfig(
            format: OutputFormat.json,
            schema: 'verdict',
          ),
          'files': const OutputConfig(
            format: OutputFormat.json,
            schema: 'file-list',
          ),
        };
        final result = augmenter.augment(prompt, outputs);
        expect(result, contains('findings'));
        expect(result, contains('path'));
      });
    });

    test('prompt is separator before Required Output Format section', () {
      const prompt = 'Do work';
      final outputs = {
        'r': const OutputConfig(
          format: OutputFormat.json,
          schema: 'verdict',
        ),
      };
      final result = augmenter.augment(prompt, outputs);
      expect(result, startsWith('Do work\n\n## Required Output Format'));
    });
  });
}
