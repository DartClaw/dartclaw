import 'package:dartclaw_workflow/dartclaw_workflow.dart';
import 'package:test/test.dart';

void main() {
  late PromptAugmenter augmenter;

  setUp(() {
    augmenter = const PromptAugmenter();
  });

  group('PromptAugmenter.augment', () {
    test('returns prompt unchanged when outputs is null', () {
      const prompt = 'Do something useful';
      expect(augmenter.augment(prompt, outputs: null), prompt);
    });

    test('returns prompt unchanged when outputs is empty', () {
      const prompt = 'Do something useful';
      expect(augmenter.augment(prompt, outputs: {}), prompt);
    });

    test('returns prompt unchanged when all outputs are text format', () {
      const prompt = 'Do something useful';
      final outputs = {'result': const OutputConfig(format: OutputFormat.text)};
      expect(augmenter.augment(prompt, outputs: outputs), prompt);
    });

    test('returns prompt unchanged for lines format (no schema)', () {
      const prompt = 'List things';
      final outputs = {'items': const OutputConfig(format: OutputFormat.lines)};
      expect(augmenter.augment(prompt, outputs: outputs), prompt);
    });

    group('preset schema augmentation', () {
      test('appends Required Output Format section for verdict preset', () {
        const prompt = 'Review this code';
        final outputs = {'review': const OutputConfig(format: OutputFormat.json, schema: 'verdict')};
        final result = augmenter.augment(prompt, outputs: outputs);
        expect(result, contains('## Required Output Format'));
        expect(result, startsWith('Review this code'));
        expect(result, contains('pass'));
        expect(result, contains('findings'));
      });

      test('appends section for story-plan preset', () {
        const prompt = 'Plan the work';
        final outputs = {'stories': const OutputConfig(format: OutputFormat.json, schema: 'story-plan')};
        final result = augmenter.augment(prompt, outputs: outputs);
        expect(result, contains('## Required Output Format'));
        expect(result, contains('id (string)'));
        expect(result, contains('title (string)'));
        expect(result, contains('Short unique identifier'));
      });

      test('appends section for checklist preset', () {
        const prompt = 'Check these items';
        final outputs = {'items': const OutputConfig(format: OutputFormat.json, schema: 'checklist')};
        final result = augmenter.augment(prompt, outputs: outputs);
        expect(result, contains('## Required Output Format'));
        expect(result, contains('all_pass'));
      });

      test('appends section for story-specs preset', () {
        const prompt = 'Spec the stories';
        final outputs = {'story_specs': const OutputConfig(format: OutputFormat.json, schema: 'story-specs')};
        final result = augmenter.augment(prompt, outputs: outputs);
        expect(result, contains('## Required Output Format'));
        expect(result, contains('acceptance_criteria'));
        expect(result, contains('spec_path'));
      });

      test('appends section for file-list preset', () {
        const prompt = 'List files';
        final outputs = {'files': const OutputConfig(format: OutputFormat.json, schema: 'file-list')};
        final result = augmenter.augment(prompt, outputs: outputs);
        expect(result, contains('## Required Output Format'));
        expect(result, contains('path'));
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
        final outputs = {'result': OutputConfig(format: OutputFormat.json, schema: schema)};
        final result = augmenter.augment(prompt, outputs: outputs);
        expect(result, contains('## Required Output Format'));
        expect(result, contains('name (string)'));
        expect(result, contains('value (integer)'));
        expect(result, contains('note (string, optional)'));
      });

      test('renders nullable property type lists without throwing', () {
        const prompt = 'Describe the project layout';
        final schema = {
          'type': 'object',
          'required': ['document_locations'],
          'properties': {
            'document_locations': {
              'type': 'object',
              'required': ['product'],
              'properties': {
                'product': {
                  'type': ['string', 'null'],
                },
              },
            },
          },
        };
        final outputs = {'project_index': OutputConfig(format: OutputFormat.json, schema: schema)};
        final result = augmenter.augment(prompt, outputs: outputs);
        expect(result, contains('document_locations (object)'));
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
        final outputs = {'items': OutputConfig(format: OutputFormat.json, schema: schema)};
        final result = augmenter.augment(prompt, outputs: outputs);
        expect(result, contains('## Required Output Format'));
        expect(result, contains('id (string)'));
        expect(result, contains('label (string, optional)'));
      });
    });

    group('multiple outputs', () {
      test('includes fragments from all json outputs with schemas', () {
        const prompt = 'Multi output step';
        final outputs = {
          'verdict': const OutputConfig(format: OutputFormat.json, schema: 'verdict'),
          'files': const OutputConfig(format: OutputFormat.json, schema: 'file-list'),
        };
        final result = augmenter.augment(prompt, outputs: outputs);
        expect(result, contains('findings'));
        expect(result, contains('path'));
      });
    });

    test('prompt is separator before Required Output Format section', () {
      const prompt = 'Do work';
      final outputs = {'r': const OutputConfig(format: OutputFormat.json, schema: 'verdict')};
      final result = augmenter.augment(prompt, outputs: outputs);
      expect(result, startsWith('Do work\n\n## Required Output Format'));
    });

    test('context outputs append workflow-context contract', () {
      const prompt = 'Do work';
      final outputs = {
        'review_summary': const OutputConfig(format: OutputFormat.json, schema: 'verdict'),
        'findings_count': const OutputConfig(format: OutputFormat.text),
      };
      final result = augmenter.augment(
        prompt,
        outputs: outputs,
        contextOutputs: const ['review_summary', 'findings_count'],
      );
      expect(result, contains('## Workflow Output Contract'));
      expect(result, contains('<workflow-context>'));
      expect(result, contains('"review_summary"'));
      expect(result, contains('"findings_count"'));
      expect(result, isNot(contains('## Required Output Format')));
    });

    group('step outcome protocol (S36)', () {
      test('appends Step Outcome Protocol section when flag is true', () {
        const prompt = 'Do the thing';
        final result = augmenter.augment(prompt, emitStepOutcomeProtocol: true);
        expect(result, startsWith('Do the thing'));
        expect(result, contains('## Step Outcome Protocol'));
        expect(result, contains('<step-outcome>'));
        expect(result, contains('succeeded'));
        expect(result, contains('failed'));
        expect(result, contains('needsInput'));
      });

      test('omits Step Outcome Protocol section when flag is false', () {
        const prompt = 'Do the thing';
        final result = augmenter.augment(prompt);
        expect(result, equals(prompt));
      });

      test('omits Step Outcome Protocol section when flag defaulted', () {
        const prompt = 'Do the thing';
        final outputs = {'r': const OutputConfig(format: OutputFormat.json, schema: 'verdict')};
        final result = augmenter.augment(prompt, outputs: outputs);
        expect(result, isNot(contains('## Step Outcome Protocol')));
      });

      test('Step Outcome Protocol appears after output contract sections', () {
        const prompt = 'Do work';
        final outputs = {'r': const OutputConfig(format: OutputFormat.json, schema: 'verdict')};
        final result = augmenter.augment(prompt, outputs: outputs, emitStepOutcomeProtocol: true);
        final outcomeIdx = result.indexOf('## Step Outcome Protocol');
        final schemaIdx = result.indexOf('## Required Output Format');
        expect(schemaIdx, greaterThan(0));
        expect(outcomeIdx, greaterThan(schemaIdx));
      });
    });
  });
}
