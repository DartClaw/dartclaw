import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

const _minimalYaml = '''
name: test-workflow
description: A test workflow
steps:
  - id: step-1
    name: Step One
    prompt: Do something
''';

const _fullYaml = '''
name: full-workflow
description: A full workflow
maxTokens: 50000
variables:
  PROJECT:
    required: true
    description: The project name
    default: my-project
  ENV:
    required: false
    description: Environment
steps:
  - id: research
    name: Research Step
    prompt: Research {{PROJECT}} for {{ENV}}
    type: research
    provider: claude
    model: claude-opus
    timeout: 30m
    review: always
    parallel: false
    gate: null
    contextInputs: []
    contextOutputs:
      - research_result
    maxTokens: 10000
    maxRetries: 2
    allowedTools:
      - Bash
      - Read
  - id: implement
    name: Implement Step
    prompt: Implement based on {{context.research_result}}
    type: coding
    review: coding-only
    parallel: true
    contextInputs:
      - research_result
    contextOutputs:
      - impl_result
    extraction:
      type: regex
      pattern: "\\\\d+"
loops:
  - id: refine-loop
    steps:
      - implement
    maxIterations: 3
    exitGate: implement.status == done
''';

void main() {
  late WorkflowDefinitionParser parser;

  setUp(() {
    parser = WorkflowDefinitionParser();
  });

  group('WorkflowDefinitionParser.parse', () {
    test('parses minimal YAML', () {
      final def = parser.parse(_minimalYaml);
      expect(def.name, 'test-workflow');
      expect(def.description, 'A test workflow');
      expect(def.steps.length, 1);
      expect(def.steps[0].id, 'step-1');
      expect(def.steps[0].name, 'Step One');
      expect(def.steps[0].prompt, 'Do something');
      expect(def.variables, isEmpty);
      expect(def.loops, isEmpty);
      expect(def.maxTokens, isNull);
    });

    test('parses full YAML with all features', () {
      final def = parser.parse(_fullYaml);
      expect(def.name, 'full-workflow');
      expect(def.maxTokens, 50000);

      // Variables
      expect(def.variables.length, 2);
      expect(def.variables['PROJECT']!.required, true);
      expect(def.variables['PROJECT']!.description, 'The project name');
      expect(def.variables['PROJECT']!.defaultValue, 'my-project');
      expect(def.variables['ENV']!.required, false);

      // Steps
      expect(def.steps.length, 2);
      final research = def.steps[0];
      expect(research.id, 'research');
      expect(research.type, 'research');
      expect(research.provider, 'claude');
      expect(research.model, 'claude-opus');
      expect(research.timeoutSeconds, 1800); // 30m in seconds
      expect(research.review, StepReviewMode.always);
      expect(research.parallel, false);
      expect(research.contextOutputs, ['research_result']);
      expect(research.maxTokens, 10000);
      expect(research.maxRetries, 2);
      expect(research.allowedTools, ['Bash', 'Read']);

      final implement = def.steps[1];
      expect(implement.id, 'implement');
      expect(implement.type, 'coding');
      expect(implement.review, StepReviewMode.codingOnly);
      expect(implement.parallel, true);
      expect(implement.contextInputs, ['research_result']);
      expect(implement.extraction!.type, ExtractionType.regex);
      expect(implement.extraction!.pattern, r'\d+');

      // Loops
      expect(def.loops.length, 1);
      expect(def.loops[0].id, 'refine-loop');
      expect(def.loops[0].steps, ['implement']);
      expect(def.loops[0].maxIterations, 3);
      expect(def.loops[0].exitGate, 'implement.status == done');
    });

    test('parses review field: always, coding-only, never', () {
      final yaml = '''
name: n
description: d
steps:
  - id: s1
    name: S1
    prompt: p
    review: always
  - id: s2
    name: S2
    prompt: p
    review: coding-only
  - id: s3
    name: S3
    prompt: p
    review: never
''';
      final def = parser.parse(yaml);
      expect(def.steps[0].review, StepReviewMode.always);
      expect(def.steps[1].review, StepReviewMode.codingOnly);
      expect(def.steps[2].review, StepReviewMode.never);
    });

    test('parses timeout string to seconds', () {
      final yaml = '''
name: n
description: d
steps:
  - id: s
    name: S
    prompt: p
    timeout: "30m"
''';
      final def = parser.parse(yaml);
      expect(def.steps[0].timeoutSeconds, 1800);
    });

    test('parses parallel: true', () {
      final yaml = '''
name: n
description: d
steps:
  - id: s
    name: S
    prompt: p
    parallel: true
''';
      final def = parser.parse(yaml);
      expect(def.steps[0].parallel, true);
    });

    test('parses contextInputs and contextOutputs as string lists', () {
      final yaml = '''
name: n
description: d
steps:
  - id: s
    name: S
    prompt: p
    contextInputs:
      - in_a
      - in_b
    contextOutputs:
      - out_c
''';
      final def = parser.parse(yaml);
      expect(def.steps[0].contextInputs, ['in_a', 'in_b']);
      expect(def.steps[0].contextOutputs, ['out_c']);
    });

    test('parses type field correctly', () {
      for (final type in ['research', 'analysis', 'writing', 'coding']) {
        final yaml = '''
name: n
description: d
steps:
  - id: s
    name: S
    prompt: p
    type: $type
''';
        expect(parser.parse(yaml).steps[0].type, type);
      }
    });

    test('missing name throws FormatException', () {
      const yaml = '''
description: d
steps:
  - id: s
    name: S
    prompt: p
''';
      expect(() => parser.parse(yaml), throwsFormatException);
    });

    test('missing description throws FormatException', () {
      const yaml = '''
name: n
steps:
  - id: s
    name: S
    prompt: p
''';
      expect(() => parser.parse(yaml), throwsFormatException);
    });

    test('missing steps throws FormatException', () {
      const yaml = '''
name: n
description: d
''';
      expect(() => parser.parse(yaml), throwsFormatException);
    });

    test('empty steps list throws FormatException', () {
      const yaml = '''
name: n
description: d
steps: []
''';
      expect(() => parser.parse(yaml), throwsFormatException);
    });

    test('step missing id throws FormatException', () {
      const yaml = '''
name: n
description: d
steps:
  - name: S
    prompt: p
''';
      expect(() => parser.parse(yaml), throwsFormatException);
    });

    test('step missing prompt throws FormatException', () {
      const yaml = '''
name: n
description: d
steps:
  - id: s
    name: S
''';
      expect(() => parser.parse(yaml), throwsFormatException);
    });

    group('outputs map parsing (S01)', () {
      test('parses outputs map with format and preset schema', () {
        const yaml = '''
name: n
description: d
steps:
  - id: s
    name: S
    prompt: p
    contextOutputs:
      - result
    outputs:
      result:
        format: json
        schema: verdict
''';
        final def = parser.parse(yaml);
        final step = def.steps[0];
        expect(step.outputs, isNotNull);
        expect(step.outputs!['result']!.format, OutputFormat.json);
        expect(step.outputs!['result']!.presetName, 'verdict');
      });

      test('parses outputs shorthand format syntax', () {
        const yaml = '''
name: n
description: d
steps:
  - id: s
    name: S
    prompt: p
    contextOutputs:
      - result
    outputs:
      result: json
''';
        final def = parser.parse(yaml);
        final step = def.steps[0];
        expect(step.outputs!['result']!.format, OutputFormat.json);
        expect(step.outputs!['result']!.schema, isNull);
      });

      test('parses lines format', () {
        const yaml = '''
name: n
description: d
steps:
  - id: s
    name: S
    prompt: p
    contextOutputs:
      - items
    outputs:
      items:
        format: lines
''';
        final def = parser.parse(yaml);
        expect(def.steps[0].outputs!['items']!.format, OutputFormat.lines);
      });

      test('parses inline schema as map', () {
        const yaml = r'''
name: n
description: d
steps:
  - id: s
    name: S
    prompt: p
    contextOutputs:
      - result
    outputs:
      result:
        format: json
        schema:
          type: object
          required:
            - name
          properties:
            name:
              type: string
''';
        final def = parser.parse(yaml);
        final config = def.steps[0].outputs!['result']!;
        expect(config.format, OutputFormat.json);
        expect(config.inlineSchema, isNotNull);
        expect(config.inlineSchema!['type'], 'object');
        expect(config.inlineSchema!['required'], ['name']);
      });

      test('throws on unknown format', () {
        const yaml = '''
name: n
description: d
steps:
  - id: s
    name: S
    prompt: p
    contextOutputs:
      - result
    outputs:
      result:
        format: invalid_format
''';
        expect(() => parser.parse(yaml), throwsFormatException);
      });

      test('null outputs when field absent (backward compat)', () {
        const yaml = '''
name: n
description: d
steps:
  - id: s
    name: S
    prompt: p
''';
        final def = parser.parse(yaml);
        expect(def.steps[0].outputs, isNull);
      });
    });

    group('evaluator flag parsing (S01)', () {
      test('parses evaluator: true', () {
        const yaml = '''
name: n
description: d
steps:
  - id: s
    name: S
    prompt: p
    evaluator: true
''';
        final def = parser.parse(yaml);
        expect(def.steps[0].evaluator, true);
      });

      test('defaults evaluator to false when absent', () {
        const yaml = '''
name: n
description: d
steps:
  - id: s
    name: S
    prompt: p
''';
        final def = parser.parse(yaml);
        expect(def.steps[0].evaluator, false);
      });
    });

    group('backward compat: extraction field (S01)', () {
      test('parses extraction field unchanged', () {
        const yaml = r'''
name: n
description: d
steps:
  - id: s
    name: S
    prompt: p
    contextOutputs:
      - result
    extraction:
      type: regex
      pattern: \d+
''';
        final def = parser.parse(yaml);
        expect(def.steps[0].extraction!.type, ExtractionType.regex);
        expect(def.steps[0].extraction!.pattern, r'\d+');
        expect(def.steps[0].outputs, isNull);
      });
    });

    group('multi-prompt (S02)', () {
      test('scalar string prompt normalizes to 1-element list', () {
        const yaml = '''
name: n
description: d
steps:
  - id: s
    name: S
    prompt: Do the thing
''';
        final def = parser.parse(yaml);
        expect(def.steps[0].prompts, ['Do the thing']);
        expect(def.steps[0].isMultiPrompt, false);
      });

      test('list prompt parses into multi-element list', () {
        const yaml = '''
name: n
description: d
steps:
  - id: s
    name: S
    prompt:
      - First prompt
      - Second prompt
      - Third prompt
''';
        final def = parser.parse(yaml);
        expect(def.steps[0].prompts, ['First prompt', 'Second prompt', 'Third prompt']);
        expect(def.steps[0].isMultiPrompt, true);
      });

      test('empty list prompt throws FormatException', () {
        const yaml = '''
name: n
description: d
steps:
  - id: s
    name: S
    prompt: []
''';
        expect(() => parser.parse(yaml), throwsA(isA<FormatException>()));
      });

      test('list with empty string element throws FormatException', () {
        const yaml = """
name: n
description: d
steps:
  - id: s
    name: S
    prompt:
      - First
      - ''
""";
        expect(() => parser.parse(yaml), throwsA(isA<FormatException>()));
      });
    });
  });

  group('S03: loop finalizer parsing', () {
    test('parses loop with finally field', () {
      const yaml = '''
name: n
description: d
steps:
  - id: loop-step
    name: Loop Step
    prompt: p
  - id: summarize
    name: Summarize
    prompt: p
loops:
  - id: loop1
    steps:
      - loop-step
    maxIterations: 3
    exitGate: loop-step.done == true
    finally: summarize
''';
      final def = parser.parse(yaml);
      expect(def.loops[0].finally_, 'summarize');
    });

    test('parses loop without finally (backward compat)', () {
      const yaml = '''
name: n
description: d
steps:
  - id: loop-step
    name: Loop Step
    prompt: p
loops:
  - id: loop1
    steps:
      - loop-step
    maxIterations: 3
    exitGate: loop-step.done == true
''';
      final def = parser.parse(yaml);
      expect(def.loops[0].finally_, isNull);
    });
  });

  group('S03: stepDefaults parsing', () {
    test('parses stepDefaults with multiple entries', () {
      const yaml = '''
name: n
description: d
steps:
  - id: review-code
    name: Review
    prompt: p
stepDefaults:
  - match: "review*"
    model: claude-opus-4
    maxTokens: 8000
  - match: "*"
    provider: claude
''';
      final def = parser.parse(yaml);
      expect(def.stepDefaults, isNotNull);
      expect(def.stepDefaults!.length, 2);
      expect(def.stepDefaults![0].match, 'review*');
      expect(def.stepDefaults![0].model, 'claude-opus-4');
      expect(def.stepDefaults![0].maxTokens, 8000);
      expect(def.stepDefaults![1].match, '*');
      expect(def.stepDefaults![1].provider, 'claude');
    });

    test('parses without stepDefaults (backward compat)', () {
      final def = parser.parse(_minimalYaml);
      expect(def.stepDefaults, isNull);
    });

    test('parses maxCostUsd as double (float value)', () {
      const yaml = '''
name: n
description: d
steps:
  - id: s
    name: S
    prompt: p
stepDefaults:
  - match: "*"
    maxCostUsd: 2.50
''';
      final def = parser.parse(yaml);
      expect(def.stepDefaults![0].maxCostUsd, 2.5);
      expect(def.stepDefaults![0].maxCostUsd, isA<double>());
    });

    test('parses maxCostUsd as double when written as int (int-as-double)', () {
      const yaml = '''
name: n
description: d
steps:
  - id: s
    name: S
    prompt: p
stepDefaults:
  - match: "*"
    maxCostUsd: 2
''';
      final def = parser.parse(yaml);
      expect(def.stepDefaults![0].maxCostUsd, 2.0);
      expect(def.stepDefaults![0].maxCostUsd, isA<double>());
    });

    test('throws FormatException when stepDefaults entry missing match field', () {
      const yaml = '''
name: n
description: d
steps:
  - id: s
    name: S
    prompt: p
stepDefaults:
  - model: claude-opus-4
''';
      expect(() => parser.parse(yaml), throwsFormatException);
    });
  });

  group('S03: step maxCostUsd parsing', () {
    test('parses step maxCostUsd as double', () {
      const yaml = '''
name: n
description: d
steps:
  - id: s
    name: S
    prompt: p
    maxCostUsd: 2.00
''';
      final def = parser.parse(yaml);
      expect(def.steps[0].maxCostUsd, 2.0);
      expect(def.steps[0].maxCostUsd, isA<double>());
    });

    test('parses step maxCostUsd as double when written as int', () {
      const yaml = '''
name: n
description: d
steps:
  - id: s
    name: S
    prompt: p
    maxCostUsd: 2
''';
      final def = parser.parse(yaml);
      expect(def.steps[0].maxCostUsd, 2.0);
      expect(def.steps[0].maxCostUsd, isA<double>());
    });
  });

  group('skill field parsing (S04)', () {
    test('parses skill field when present', () {
      const yaml = '''
name: n
description: d
steps:
  - id: s
    name: S
    skill: andthen:review-code
    prompt: Also do this.
''';
      final def = parser.parse(yaml);
      expect(def.steps[0].skill, 'andthen:review-code');
      expect(def.steps[0].prompt, 'Also do this.');
    });

    test('skill-only step (no prompt) is valid', () {
      const yaml = '''
name: n
description: d
steps:
  - id: s
    name: S
    skill: andthen:review-code
''';
      final def = parser.parse(yaml);
      expect(def.steps[0].skill, 'andthen:review-code');
      expect(def.steps[0].prompt, isNull);
      expect(def.steps[0].prompts, isNull);
    });

    test('step without skill or prompt throws FormatException', () {
      const yaml = '''
name: n
description: d
steps:
  - id: s
    name: S
''';
      expect(() => parser.parse(yaml), throwsA(isA<FormatException>()));
    });

    test('step without skill requires non-empty prompt', () {
      const yaml = '''
name: n
description: d
steps:
  - id: s
    name: S
    prompt: ''
''';
      expect(() => parser.parse(yaml), throwsA(isA<FormatException>()));
    });

    test('step without skill field has null skill', () {
      const yaml = '''
name: n
description: d
steps:
  - id: s
    name: S
    prompt: p
''';
      final def = parser.parse(yaml);
      expect(def.steps[0].skill, isNull);
    });
  });

  group('S06: map step fields', () {
    test('parses map_over (snake_case) field', () {
      const yaml = '''
name: n
description: d
steps:
  - id: s
    name: S
    prompt: p
    map_over: items
''';
      final def = parser.parse(yaml);
      expect(def.steps[0].mapOver, 'items');
    });

    test('parses mapOver (camelCase alias) field', () {
      const yaml = '''
name: n
description: d
steps:
  - id: s
    name: S
    prompt: p
    mapOver: items
''';
      final def = parser.parse(yaml);
      expect(def.steps[0].mapOver, 'items');
    });

    test('mapOver absent -> null (non-map step)', () {
      const yaml = '''
name: n
description: d
steps:
  - id: s
    name: S
    prompt: p
''';
      final def = parser.parse(yaml);
      expect(def.steps[0].mapOver, isNull);
      expect(def.steps[0].isMapStep, isFalse);
    });

    test('parses max_parallel as int', () {
      const yaml = '''
name: n
description: d
steps:
  - id: s
    name: S
    prompt: p
    map_over: items
    max_parallel: 4
''';
      final def = parser.parse(yaml);
      expect(def.steps[0].maxParallel, 4);
      expect(def.steps[0].maxParallel, isA<int>());
    });

    test('parses max_parallel as string "unlimited"', () {
      const yaml = '''
name: n
description: d
steps:
  - id: s
    name: S
    prompt: p
    map_over: items
    max_parallel: "unlimited"
''';
      final def = parser.parse(yaml);
      expect(def.steps[0].maxParallel, 'unlimited');
      expect(def.steps[0].maxParallel, isA<String>());
    });

    test('parses max_parallel as template string', () {
      const yaml = '''
name: n
description: d
steps:
  - id: s
    name: S
    prompt: p
    map_over: items
    max_parallel: "{{MAX_PARALLEL}}"
''';
      final def = parser.parse(yaml);
      expect(def.steps[0].maxParallel, '{{MAX_PARALLEL}}');
    });

    test('max_parallel absent -> null', () {
      const yaml = '''
name: n
description: d
steps:
  - id: s
    name: S
    prompt: p
    map_over: items
''';
      final def = parser.parse(yaml);
      expect(def.steps[0].maxParallel, isNull);
    });

    test('max_parallel invalid type throws FormatException', () {
      const yaml = '''
name: n
description: d
steps:
  - id: s
    name: S
    prompt: p
    map_over: items
    max_parallel:
      nested: bad
''';
      expect(() => parser.parse(yaml), throwsFormatException);
    });

    test('parses max_items (snake_case)', () {
      const yaml = '''
name: n
description: d
steps:
  - id: s
    name: S
    prompt: p
    map_over: items
    max_items: 50
''';
      final def = parser.parse(yaml);
      expect(def.steps[0].maxItems, 50);
    });

    test('parses maxItems (camelCase alias)', () {
      const yaml = '''
name: n
description: d
steps:
  - id: s
    name: S
    prompt: p
    map_over: items
    maxItems: 10
''';
      final def = parser.parse(yaml);
      expect(def.steps[0].maxItems, 10);
    });

    test('max_items absent -> defaults to 20', () {
      const yaml = '''
name: n
description: d
steps:
  - id: s
    name: S
    prompt: p
    map_over: items
''';
      final def = parser.parse(yaml);
      expect(def.steps[0].maxItems, 20);
    });

    test('isMapStep true when map_over set', () {
      const yaml = '''
name: n
description: d
steps:
  - id: s
    name: S
    prompt: p
    map_over: results
''';
      final def = parser.parse(yaml);
      expect(def.steps[0].isMapStep, isTrue);
    });
  });
}
