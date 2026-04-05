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
  });
}
