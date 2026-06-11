import 'package:dartclaw_workflow/dartclaw_workflow.dart';
import 'package:test/test.dart';

import 'workflow_validator_test_support.dart';

void main() {
  late WorkflowDefinitionValidator validator;

  setUp(() {
    validator = WorkflowDefinitionValidator();
  });

  test('warns when duplicate output names use different descriptions', () {
    final def = buildDef(
      steps: [
        WorkflowStep(
          id: 'a',
          name: 'A',
          prompts: const ['p'],
          outputs: const {'x': OutputConfig(format: OutputFormat.text, description: 'from A')},
        ),
        WorkflowStep(
          id: 'b',
          name: 'B',
          prompts: const ['p'],
          outputs: const {'x': OutputConfig(format: OutputFormat.text, description: 'from B')},
        ),
      ],
    );

    final report = validator.validate(def);
    expect(report.warnings, isNotEmpty);
    expect(report.warnings.single.message, contains('"x"'));
    expect(report.warnings.single.message, contains('a'));
    expect(report.warnings.single.message, contains('b'));
  });

  test('does not warn when duplicate output descriptions are absent', () {
    final def = buildDef(
      steps: [
        WorkflowStep(
          id: 'a',
          name: 'A',
          prompts: const ['p'],
          outputs: const {'x': OutputConfig(format: OutputFormat.text)},
        ),
        WorkflowStep(
          id: 'b',
          name: 'B',
          prompts: const ['p'],
          outputs: const {'x': OutputConfig(format: OutputFormat.text)},
        ),
      ],
    );

    final report = validator.validate(def);
    expect(report.warnings, isEmpty);
  });

  group('structured + inline-schema + description rules', () {
    test('structured output requires json format and schema', () {
      final def = WorkflowDefinition(
        name: 'wf',
        description: 'd',
        steps: const [
          WorkflowStep(
            id: 'review',
            name: 'Review',
            prompts: ['Review'],
            outputs: {'verdict': OutputConfig(format: OutputFormat.text, outputMode: OutputMode.structured)},
          ),
        ],
      );
      final report = validator.validate(def);
      expect(report.errors.length, greaterThanOrEqualTo(2));
      expect(hasError(report.errors, messageContains: 'format: json'), isTrue);
      expect(hasError(report.errors, messageContains: 'has no schema'), isTrue);
    });

    test('structured inline schema requires additionalProperties false on object nodes', () {
      final def = WorkflowDefinition(
        name: 'wf',
        description: 'd',
        steps: const [
          WorkflowStep(
            id: 'review',
            name: 'Review',
            prompts: ['Review'],
            outputs: {
              'verdict': OutputConfig(
                format: OutputFormat.json,
                outputMode: OutputMode.structured,
                schema: {
                  'type': 'object',
                  'properties': {
                    'summary': {'type': 'string'},
                  },
                },
              ),
            },
          ),
        ],
      );
      final report = validator.validate(def);
      expect(hasError(report.errors, messageContains: 'additionalProperties: false'), isTrue);
    });

    test('TD-085: inline schema with oneOf emits unsupported-keyword error at load time', () {
      final def = WorkflowDefinition(
        name: 'wf',
        description: 'd',
        steps: const [
          WorkflowStep(
            id: 'review',
            name: 'Review',
            prompts: ['Review'],
            outputs: {
              'verdict': OutputConfig(
                format: OutputFormat.json,
                schema: {
                  'type': 'object',
                  'additionalProperties': false,
                  'oneOf': [
                    {
                      'required': ['pass'],
                    },
                    {
                      'required': ['fail'],
                    },
                  ],
                },
              ),
            },
          ),
        ],
      );
      final report = validator.validate(def);
      expect(
        report.errors.any((e) => e.message.contains('"oneOf"') && e.message.contains('Supported subset')),
        isTrue,
        reason: 'unsupported JSON Schema keyword oneOf must produce an error, not silently pass',
      );
    });

    WorkflowDefinition defWithOutput(OutputConfig outputConfig) => WorkflowDefinition(
      name: 'wf',
      description: 'd',
      steps: [
        WorkflowStep(
          id: 'implement',
          name: 'Implement',
          prompts: const ['Implement'],
          outputs: {'diff_summary': outputConfig},
        ),
      ],
    );

    test('inline description colliding with text-preset description emits exactly one warning', () {
      // `diff_summary` is a text preset with a canonical description. Setting
      // an inline description as well silently overrides it – should warn.
      final report = validator.validate(
        defWithOutput(
          const OutputConfig(
            format: OutputFormat.text,
            schema: 'diff_summary',
            description: 'Custom inline description overrides the preset.',
          ),
        ),
      );
      expect(report.errors, isEmpty);
      expect(report.warnings, hasLength(1));
      expect(report.warnings.single.message, contains('diff_summary'));
      expect(report.warnings.single.message, contains('inline description overrides the preset'));
    });

    test('preset reference without inline description does not warn', () {
      final report = validator.validate(
        defWithOutput(const OutputConfig(format: OutputFormat.text, schema: 'diff_summary')),
      );
      expect(report.errors, isEmpty);
      expect(report.warnings, isEmpty);
    });

    test('inline description with no preset at all does not warn', () {
      final report = validator.validate(
        defWithOutput(const OutputConfig(format: OutputFormat.text, description: 'Freeform description, no preset.')),
      );
      expect(report.errors, isEmpty);
      expect(report.warnings, isEmpty);
    });

    test('inline description with a preset that has no description does not warn', () {
      // `non_negative_integer` is a JSON preset with no `description` – can
      // only be paired with `format: json`. An inline description here is
      // an authoring choice, not a collision.
      final def = WorkflowDefinition(
        name: 'wf',
        description: 'd',
        steps: const [
          WorkflowStep(
            id: 'review',
            name: 'Review',
            prompts: ['Review'],
            outputs: {
              'findings_count': OutputConfig(
                format: OutputFormat.json,
                schema: 'non_negative_integer',
                description: 'How many things we found.',
              ),
            },
          ),
        ],
      );
      final report = validator.validate(def);
      expect(report.errors, isEmpty);
      expect(report.warnings, isEmpty);
    });

    test('whitespace-only inline description is a hard error', () {
      final report = validator.validate(
        defWithOutput(const OutputConfig(format: OutputFormat.text, schema: 'diff_summary', description: '   ')),
      );
      expect(
        report.errors.any((e) => e.message.contains('diff_summary') && e.message.contains('blank "description"')),
        isTrue,
      );
    });

    test('json output without schema is a hard error', () {
      final def = WorkflowDefinition(
        name: 'wf',
        description: 'd',
        steps: const [
          WorkflowStep(
            id: 'research',
            name: 'Research',
            type: WorkflowTaskType.agent,
            prompts: ['Research'],
            outputs: {'verdict': OutputConfig(format: OutputFormat.json)},
          ),
        ],
      );
      final report = validator.validate(def);
      expect(hasError(report.errors, messageContains: 'format: json requires a schema'), isTrue);
    });

    test('foreach controller json aggregate does not require a schema', () {
      const def = WorkflowDefinition(
        name: 'wf',
        description: 'd',
        steps: [
          WorkflowStep(id: 'produce', name: 'Produce', prompts: ['p'], outputs: {'items': OutputConfig()}),
          WorkflowStep(id: 'implement', name: 'Implement', prompts: ['p'], outputs: {'story_result': OutputConfig()}),
          WorkflowStep(
            id: 'pipeline',
            name: 'Pipeline',
            type: WorkflowTaskType.foreach,
            mapOver: 'items',
            foreachSteps: ['implement'],
            outputs: {'story_results': OutputConfig(format: OutputFormat.json)},
          ),
        ],
      );
      final report = validator.validate(def);
      expect(report.errors, isEmpty);
    });
  });
}
