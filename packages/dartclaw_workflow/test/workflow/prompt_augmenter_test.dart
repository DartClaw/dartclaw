import 'package:dartclaw_workflow/dartclaw_workflow.dart';
import 'package:dartclaw_workflow/src/workflow/execution_envelope_schema.dart' show buildExecutionEnvelopeSchema;
import 'package:dartclaw_workflow/src/workflow/review_scoring_fragment.dart';
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

      test('appends review scoring fragment for verdict and gating count presets', () {
        const forbiddenTokens = ['FIS', 'Fix/Note', 'review-verdict', 'fis-authoring', 'andthen'];
        final verdictResult = augmenter.augment(
          'Review this code',
          outputs: {'review': const OutputConfig(format: OutputFormat.json, schema: 'verdict')},
        );
        final countResult = augmenter.augment(
          'Review this code',
          outputs: {
            'gating_findings_count': const OutputConfig(format: OutputFormat.json, schema: 'gating_findings_count'),
          },
        );
        final nonReviewResult = augmenter.augment(
          'Summarize this code',
          outputs: {'summary': const OutputConfig(format: OutputFormat.text, schema: 'diff_summary')},
        );

        expect(verdictResult, contains('## Review Finding Scoring'));
        expect(verdictResult, contains('at or above `high`'));
        expect(countResult, contains('## Review Finding Scoring'));
        expect(countResult, contains('at or above `high`'));
        expect(nonReviewResult, isNot(contains('## Review Finding Scoring')));
        for (final token in forbiddenTokens) {
          expect(reviewScoringFragment, isNot(contains(token)), reason: token);
        }
      });

      test('appends section for story_specs preset', () {
        const prompt = 'Spec the stories';
        final outputs = {'story_specs': const OutputConfig(format: OutputFormat.json, schema: 'story_specs')};
        final result = augmenter.augment(prompt, outputs: outputs);
        expect(result, contains('## Required Output Format'));
        expect(result, contains('spec_path'));
        expect(result, contains('id'));
        expect(result, contains('title'));
        // AC lives in the FIS body on disk, not in the structured record.
        expect(result, isNot(contains('acceptance_criteria')));
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
          'story_specs': const OutputConfig(format: OutputFormat.json, schema: 'story_specs'),
        };
        final result = augmenter.augment(prompt, outputs: outputs);
        expect(result, contains('findings'));
        expect(result, contains('spec_path'));
      });
    });

    test('prompt is separator before Required Output Format section', () {
      const prompt = 'Do work';
      final outputs = {'r': const OutputConfig(format: OutputFormat.json, schema: 'verdict')};
      final result = augmenter.augment(prompt, outputs: outputs);
      expect(result, startsWith('Do work\n\n## Required Output Format'));
    });

    test('declared context outputs render no main-prompt output contract', () {
      // Every model-derived output rides the execution envelope, so the main
      // prompt states no output contract at all — there is no second channel to
      // teach.
      const prompt = 'Do work';
      final outputs = {
        'review_summary': const OutputConfig(format: OutputFormat.json, schema: 'verdict'),
        'findings_count': const OutputConfig(format: OutputFormat.text),
      };
      final result = augmenter.augment(
        prompt,
        outputs: outputs,
        outputKeys: const ['review_summary', 'findings_count'],
      );
      expect(result, isNot(contains('## Workflow Output Contract')));
      expect(result, isNot(contains('workflow-context')));
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

  group('finalizer output contract (TI05)', () {
    const reviewStep = WorkflowStep(
      id: 'plan-review',
      name: 'Plan Review',
      taskType: WorkflowTaskType.agent,
      prompts: ['Review the plan'],
      outputs: {
        'review_report_path': OutputConfig(
          format: OutputFormat.path,
          description: 'Absolute review report path under the workflow runtime artifacts directory.',
        ),
        'verdict': OutputConfig(format: OutputFormat.json, schema: 'verdict', outputMode: OutputMode.structured),
      },
    );

    test('an all-covered finalizer step still states what it must determine, and no emission protocol', () {
      // Both keys are finalizer-covered, so the emission protocol and the format
      // fragments belong to the finalizer turn. What the keys *mean* does not:
      // it is this turn's contract, and a step told nothing about them answers
      // from its input alone.
      final result = augmenter.augment(
        'Review this code',
        outputs: reviewStep.outputs,
        outputKeys: const ['review_report_path', 'verdict'],
        finalizerCoveredKeys: const ['review_report_path', 'verdict'],
      );

      expect(result, contains('## Declared Outputs'));
      expect(result, contains('"review_report_path"'));
      // `verdict` carries no authored description and its preset supplies none,
      // so there is nothing to state about it — the section renders what the
      // YAML says and invents nothing.
      expect(result, isNot(contains('"verdict"')));
      expect(result, isNot(contains('## Workflow Output Contract')));
      expect(result, isNot(contains('## Step Outcome Protocol')));
      expect(result, isNot(contains('## Required Output Format')));
      expect(result, isNot(contains('<workflow-context>')));
    });

    // Models detect-spec-input, and pins the live regression this closes: with
    // every key finalizer-covered, the main prompt stated none of them, so the
    // classifier was asked to classify with nothing saying what `spec_source`
    // meant and answered from the FEATURE string alone.
    test("a covered key's description reaches the main prompt, its emission protocol does not", () {
      const sourceDescription =
          "'existing' when input resolves to a reusable implementation specification, "
          "'synthesized' when the spec skill authored a new one.";
      final outputs = {
        'spec_path': const OutputConfig(format: OutputFormat.path, description: 'Path to the active spec on disk.'),
        'spec_source': const OutputConfig(
          format: OutputFormat.text,
          schema: 'narrative_text',
          description: sourceDescription,
        ),
      };
      final result = augmenter.augment(
        'Classify the input',
        outputs: outputs,
        outputKeys: const ['spec_path', 'spec_source'],
        finalizerCoveredKeys: const ['spec_path', 'spec_source'],
      );

      expect(result, contains(sourceDescription));
      expect(result, contains('"spec_source"'));
      expect(result, isNot(contains('<workflow-context>')));
      expect(result, isNot(contains('End your final response')));
    });

    test('finalizer prompt for a review step carries field descriptions and the scoring rule', () {
      final schema = buildExecutionEnvelopeSchema(reviewStep, reviewStep.outputs)!;
      final finalizerPrompt = buildFinalizerPrompt(schema);

      expect(finalizerPrompt, contains('## Declared Outputs'));
      // A provider that enforces no schema sees this prompt and nothing else,
      // so the schema reaches it as prose through the one renderer.
      expect(finalizerPrompt, contains('as JSON with this structure'));
      expect(finalizerPrompt, contains('Absolute review report path under the workflow runtime artifacts directory.'));
      expect(finalizerPrompt, contains('Review Finding Scoring'));
      expect(finalizerPrompt, contains('at or above `high`'));
      expect(finalizerPrompt, contains('## Step Outcome'));
    });
  });
}
