import 'package:dartclaw_workflow/dartclaw_workflow.dart';
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
    inputs: []
    outputs:
      research_result:
        format: text
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
    inputs:
      - research_result
    outputs:
      impl_result:
        format: text
    extraction:
      type: regex
      pattern: "\\\\d+"
loops:
  - id: refine-loop
    steps:
      - implement
    maxIterations: 3
    entryGate: research.findings_count > 0
    exitGate: implement.status == done
''';

const _inlineLoopYaml = '''
name: ordered-inline-loop
description: Inline loop authored in step order
steps:
  - id: gap-analysis
    name: Gap Analysis
    prompt: Analyze the current implementation
  - id: remediation-loop
    name: Remediation Loop
    type: loop
    maxIterations: 3
    entryGate: gap-analysis.findings_count > 0
    exitGate: re-review.status == accepted
    steps:
      - id: remediate
        name: Remediate
        prompt: Apply fixes from the review
      - id: re-review
        name: Re-review
        prompt: Check whether the fixes are sufficient
  - id: update-state
    name: Update State
    prompt: Record the final workflow status
''';

const _legacyLoopsNormalizationYaml = '''
name: legacy-loops-normalization
description: Legacy loops are normalized by authored step position
steps:
  - id: setup
    name: Setup
    prompt: Setup context
  - id: rem-a
    name: Remediate A
    prompt: Fix issue A
  - id: mid
    name: Mid Step
    prompt: Mid step
  - id: rem-b
    name: Remediate B
    prompt: Verify A
  - id: fin-a
    name: Finalize A
    prompt: Finalize A
  - id: rem-c
    name: Remediate C
    prompt: Fix issue C
  - id: rem-d
    name: Remediate D
    prompt: Verify C
  - id: fin-b
    name: Finalize B
    prompt: Finalize B
loops:
  - id: loop-b
    steps: [rem-c, rem-d]
    maxIterations: 2
    exitGate: rem-d.status == accepted
    finally: fin-b
  - id: loop-a
    steps: [rem-a, rem-b]
    maxIterations: 2
    exitGate: rem-b.status == accepted
    finally: fin-a
''';

const _gitStrategyYaml = '''
name: git-strategy-workflow
description: Workflow with reusable git strategy
project: "{{PROJECT}}"
gitStrategy:
  bootstrap: true
  worktree:
    mode: shared
  promotion: merge
  publish:
    enabled: true
steps:
  - id: step-1
    name: Step One
    prompt: Do something
''';

const _autoWorktreeYaml = '''
name: auto-worktree-workflow
description: Workflow with auto worktree mode
gitStrategy:
  bootstrap: true
  worktree: auto
steps:
  - id: stories
    name: Stories
    prompt: Produce stories
  - id: implement
    name: Implement
    prompt: Implement {{map.item}}
    mapOver: items
    max_parallel: 2
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
      expect(research.outputKeys, ['research_result']);
      expect(research.maxTokens, 10000);
      expect(research.maxRetries, 2);
      expect(research.allowedTools, ['Bash', 'Read']);

      final implement = def.steps[1];
      expect(implement.id, 'implement');
      expect(implement.type, 'coding');
      expect(implement.review, StepReviewMode.codingOnly);
      expect(implement.parallel, true);
      expect(implement.inputs, ['research_result']);
      expect(implement.extraction!.type, ExtractionType.regex);
      expect(implement.extraction!.pattern, r'\d+');

      // Loops
      expect(def.loops.length, 1);
      expect(def.loops[0].id, 'refine-loop');
      expect(def.loops[0].steps, ['implement']);
      expect(def.loops[0].maxIterations, 3);
      expect(def.loops[0].entryGate, 'research.findings_count > 0');
      expect(def.loops[0].exitGate, 'implement.status == done');
    });

    test('defaults json+schema outputs to structured mode', () {
      const yaml = '''
name: structured-workflow
description: Workflow with one-shot structured output
steps:
  - id: review
    name: Review
    prompt: Review the change
    outputs:
      verdict:
        format: json
        schema: verdict
''';
      final def = parser.parse(yaml);
      final step = def.steps.single;
      expect(step.outputs?['verdict']?.outputMode, OutputMode.structured);
      expect(step.outputs?['verdict']?.presetName, 'verdict');
    });

    test('parses gitStrategy.worktree: auto', () {
      final def = parser.parse(_autoWorktreeYaml);
      expect(def.gitStrategy?.worktreeMode, 'auto');
    });

    test('threads gitStrategy.merge_resolve from YAML through to WorkflowGitStrategy', () {
      const yaml = '''
name: wf
description: d
gitStrategy:
  promotion: merge
  merge_resolve:
    enabled: true
    max_attempts: 3
    token_ceiling: 200000
    escalation: fail
    verification:
      format: dart format --set-exit-if-changed .
      analyze: dart analyze
      test: dart test
steps:
  - id: s1
    name: S
    prompt: hi
''';
      final def = parser.parse(yaml);
      final mr = def.gitStrategy!.mergeResolve;
      expect(mr.enabled, isTrue);
      expect(mr.maxAttempts, 3);
      expect(mr.tokenCeiling, 200000);
      expect(mr.escalation, MergeResolveEscalation.fail);
      expect(mr.verification.format, 'dart format --set-exit-if-changed .');
      expect(mr.verification.analyze, 'dart analyze');
      expect(mr.verification.test, 'dart test');
    });

    test('parses workflow-level project', () {
      final def = parser.parse(_gitStrategyYaml);
      expect(def.project, '{{PROJECT}}');
    });

    test('rejects non-string workflow-level project', () {
      const yaml = '''
name: wf
description: desc
project:
  nested: nope
steps:
  - id: s1
    name: Step
    prompt: Hello
''';
      expect(() => parser.parse(yaml), throwsFormatException);
    });

    test('rejects removed executionMode at workflow root', () {
      const yaml = '''
name: wf
description: d
executionMode: streaming
steps:
  - id: s
    name: S
    prompt: p
''';
      expect(
        () => parser.parse(yaml),
        throwsA(
          isA<FormatException>().having((error) => error.message, 'message', contains('executionMode was removed')),
        ),
      );
    });

    test('rejects removed executionMode on a step', () {
      const yaml = '''
name: wf
description: d
steps:
  - id: s
    name: S
    prompt: p
    executionMode: streaming
''';
      expect(
        () => parser.parse(yaml),
        throwsA(
          isA<FormatException>().having((error) => error.message, 'message', contains('executionMode was removed')),
        ),
      );
    });

    test('parses inline loop authoring and preserves definition round-trip', () {
      final definition = parser.parse(_inlineLoopYaml);
      final roundTrip = WorkflowDefinition.fromJson(definition.toJson());

      expect(roundTrip.toJson(), equals(definition.toJson()));
      expect(definition.nodes.map((node) => node.runtimeType).toList(), equals([ActionNode, LoopNode, ActionNode]));
      expect((definition.nodes[1] as LoopNode).loopId, 'remediation-loop');
      expect((definition.nodes[1] as LoopNode).stepIds, equals(['remediate', 're-review']));
      expect(definition.loops.single.entryGate, 'gap-analysis.findings_count > 0');
    });

    test('normalizes legacy loops by first authored loop step order', () {
      final definition = parser.parse(_legacyLoopsNormalizationYaml);
      expect(definition.loops.map((loop) => loop.id).toList(), equals(['loop-a', 'loop-b']));
      expect(definition.nodes.whereType<LoopNode>().map((node) => node.loopId).toList(), equals(['loop-a', 'loop-b']));
    });

    test('parses reusable gitStrategy blocks for user-authored workflows', () {
      final definition = parser.parse(_gitStrategyYaml);
      expect(
        definition.toJson()['gitStrategy'],
        equals({
          'bootstrap': true,
          'worktree': 'shared',
          'promotion': 'merge',
          'publish': {'enabled': true},
        }),
      );
    });

    test('rejects gitStrategy.finalReview with a clear removal message', () {
      const yaml = '''
name: wf
description: d
gitStrategy:
  bootstrap: true
  finalReview: true
steps:
  - id: s
    name: S
    prompt: p
''';
      expect(
        () => parser.parse(yaml),
        throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('gitStrategy.finalReview'))),
      );
    });

    test('parses gitStrategy.cleanup.enabled: false', () {
      const yaml = '''
name: wf
description: d
gitStrategy:
  bootstrap: true
  cleanup:
    enabled: false
steps:
  - id: s
    name: S
    prompt: p
''';
      final def = parser.parse(yaml);
      expect(def.gitStrategy?.cleanup?.enabled, isFalse);
      expect(def.gitStrategy?.cleanupEnabled, isFalse);
    });

    test('parses gitStrategy.cleanup.enabled: true', () {
      const yaml = '''
name: wf
description: d
gitStrategy:
  cleanup:
    enabled: true
steps:
  - id: s
    name: S
    prompt: p
''';
      final def = parser.parse(yaml);
      expect(def.gitStrategy?.cleanup?.enabled, isTrue);
      expect(def.gitStrategy?.cleanupEnabled, isTrue);
    });

    test('gitStrategy.cleanup round-trips through toJson/fromJson', () {
      const yaml = '''
name: wf
description: d
gitStrategy:
  cleanup:
    enabled: false
steps:
  - id: s
    name: S
    prompt: p
''';
      final parsed = parser.parse(yaml);
      final roundTripped = WorkflowDefinition.fromJson(parsed.toJson());
      expect(roundTripped.gitStrategy?.cleanup?.enabled, isFalse);
      expect(roundTripped.gitStrategy?.cleanupEnabled, isFalse);
    });

    test('gitStrategy.cleanup defaults to enabled when omitted', () {
      const yaml = '''
name: wf
description: d
gitStrategy:
  bootstrap: true
steps:
  - id: s
    name: S
    prompt: p
''';
      final def = parser.parse(yaml);
      expect(def.gitStrategy?.cleanup, isNull);
      expect(def.gitStrategy?.cleanupEnabled, isTrue);
    });

    test('rejects unknown subkey under gitStrategy.cleanup', () {
      const yaml = '''
name: wf
description: d
gitStrategy:
  cleanup:
    enabled: true
    branches: false
steps:
  - id: s
    name: S
    prompt: p
''';
      expect(
        () => parser.parse(yaml),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            allOf(contains('Unknown field'), contains('"branches"'), contains('gitStrategy.cleanup')),
          ),
        ),
      );
    });

    test('rejects non-boolean gitStrategy.cleanup.enabled', () {
      const yaml = '''
name: wf
description: d
gitStrategy:
  cleanup:
    enabled: "true"
steps:
  - id: s
    name: S
    prompt: p
''';
      expect(
        () => parser.parse(yaml),
        throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('gitStrategy.cleanup.enabled'))),
      );
    });

    test('rejects non-mapping gitStrategy.cleanup', () {
      const yaml = '''
name: wf
description: d
gitStrategy:
  cleanup: preserve-on-failure
steps:
  - id: s
    name: S
    prompt: p
''';
      expect(
        () => parser.parse(yaml),
        throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('gitStrategy.cleanup'))),
      );
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

    test('parses inputs as a string list and outputs as a map', () {
      final yaml = '''
name: n
description: d
steps:
  - id: s
    name: S
    prompt: p
    inputs:
      - in_a
      - in_b
    outputs:
      out_c:
        format: text
''';
      final def = parser.parse(yaml);
      expect(def.steps[0].inputs, ['in_a', 'in_b']);
      expect(def.steps[0].outputKeys, ['out_c']);
    });

    test('parses workflowVariables (snake_case and camelCase aliases)', () {
      const yaml = '''
name: n
description: d
variables:
  REQUIREMENTS:
    required: true
    description: req
  FEATURE:
    required: true
    description: feat
steps:
  - id: snake
    name: Snake
    prompt: p
    workflow_variables:
      - REQUIREMENTS
  - id: camel
    name: Camel
    prompt: p
    workflowVariables: [FEATURE]
  - id: missing
    name: Missing
    prompt: p
''';
      final def = parser.parse(yaml);
      expect(def.steps[0].workflowVariables, ['REQUIREMENTS']);
      expect(def.steps[1].workflowVariables, ['FEATURE']);
      expect(def.steps[2].workflowVariables, isEmpty);
    });

    test('workflowVariables round-trips through toJson/fromJson', () {
      const yaml = '''
name: n
description: d
variables:
  REQUIREMENTS:
    required: true
    description: req
steps:
  - id: s
    name: S
    prompt: p
    workflowVariables: [REQUIREMENTS]
''';
      final def = parser.parse(yaml);
      final roundTripped = WorkflowStep.fromJson(def.steps[0].toJson());
      expect(roundTripped.workflowVariables, ['REQUIREMENTS']);
    });

    test('parses type field correctly', () {
      for (final type in ['research', 'analysis', 'writing', 'coding']) {
        final yaml =
            '''
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
    outputs:
      result:
        format: invalid_format
''';
        expect(() => parser.parse(yaml), throwsFormatException);
      });

      test('mixes shorthand and map-form output entries', () {
        const yaml = '''
name: n
description: d
steps:
  - id: s
    name: S
    prompt: p
    outputs:
      a: text
      b: lines
      c:
        format: path
        description: A path
''';
        final def = WorkflowDefinitionParser().parse(yaml);
        final outputs = def.steps[0].outputs!;
        expect(outputs['a']!.format, OutputFormat.text);
        expect(outputs['a']!.description, isNull);
        expect(outputs['b']!.format, OutputFormat.lines);
        expect(outputs['c']!.format, OutputFormat.path);
        expect(outputs['c']!.description, 'A path');
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

      group('setValue parsing', () {
        test('absent setValue leaves hasSetValue false', () {
          const yaml = '''
name: n
description: d
steps:
  - id: s
    name: S
    prompt: p
    outputs:
      k:
        format: text
''';
          final def = parser.parse(yaml);
          final config = def.steps[0].outputs!['k']!;
          expect(config.hasSetValue, isFalse);
          expect(config.setValue, isNull);
        });

        test('setValue: null is parsed as explicit null', () {
          const yaml = '''
name: n
description: d
steps:
  - id: s
    name: S
    prompt: p
    outputs:
      k:
        format: text
        setValue: null
''';
          final def = parser.parse(yaml);
          final config = def.steps[0].outputs!['k']!;
          expect(config.hasSetValue, isTrue);
          expect(config.setValue, isNull);
        });

        test('setValue parses string, number, bool literals', () {
          const yaml = '''
name: n
description: d
steps:
  - id: a
    name: A
    prompt: p
    outputs:
      k:
        format: text
        setValue: "literal"
  - id: b
    name: B
    prompt: p
    outputs:
      k:
        format: text
        setValue: 42
  - id: c
    name: C
    prompt: p
    outputs:
      k:
        format: text
        setValue: true
''';
          final def = parser.parse(yaml);
          expect(def.steps[0].outputs!['k']!.setValue, 'literal');
          expect(def.steps[1].outputs!['k']!.setValue, 42);
          expect(def.steps[2].outputs!['k']!.setValue, true);
        });

        test('setValue parses list and map literals deeply', () {
          const yaml = '''
name: n
description: d
steps:
  - id: a
    name: A
    prompt: p
    outputs:
      k:
        format: text
        setValue: [a, b, c]
  - id: b
    name: B
    prompt: p
    outputs:
      k:
        format: text
        setValue:
          nested:
            inner: value
          list:
            - 1
            - 2
''';
          final def = parser.parse(yaml);
          final listValue = def.steps[0].outputs!['k']!.setValue;
          expect(listValue, ['a', 'b', 'c']);
          final mapValue = def.steps[1].outputs!['k']!.setValue as Map;
          expect(mapValue['nested'], {'inner': 'value'});
          expect(mapValue['list'], [1, 2]);
        });

        test('outputs-only step derives outputKeys from outputs.keys', () {
          const yaml = '''
name: n
description: d
steps:
  - id: s
    name: S
    prompt: p
    outputs:
      summary:
        format: text
      count:
        format: json
        schema: non-negative-integer
''';
          final def = WorkflowDefinitionParser().parse(yaml);
          final step = def.steps[0];
          expect(step.outputKeys.toSet(), {'summary', 'count'});
        });

        test('parser throws FormatException on legacy contextInputs: with migration message', () {
          const regularYaml = '''
name: n
description: d
steps:
  - id: s
    name: S
    prompt: p
    contextInputs: [foo]
''';
          expect(
            () => WorkflowDefinitionParser().parse(regularYaml),
            throwsA(
              isA<FormatException>().having(
                (e) => e.message,
                'message',
                allOf(
                  contains("Step 's': contextInputs: is removed"),
                  contains('declare context-read keys under inputs:'),
                  contains('inputs: [project_index, prd]'),
                ),
              ),
            ),
          );
          const foreachYaml = '''
name: n
description: d
steps:
  - id: ctrl
    name: Controller
    type: foreach
    map_over: items
    contextInputs: [foo]
    steps:
      - id: child
        name: Child
        prompt: p
''';
          expect(
            () => WorkflowDefinitionParser().parse(foreachYaml),
            throwsA(
              isA<FormatException>().having(
                (e) => e.message,
                'message',
                contains("Step 'ctrl': contextInputs: is removed"),
              ),
            ),
          );
          const loopYaml = '''
name: n
description: d
steps:
  - id: lp
    name: Loop
    type: loop
    maxIterations: 2
    exitGate: never
    contextInputs: [foo]
    steps:
      - id: child
        name: Child
        prompt: p
''';
          expect(
            () => WorkflowDefinitionParser().parse(loopYaml),
            throwsA(
              isA<FormatException>().having(
                (e) => e.message,
                'message',
                contains("Step 'lp': contextInputs: is removed"),
              ),
            ),
          );
        });

        test('contextOutputs removal error takes precedence over malformed outputs', () {
          const yaml = '''
name: n
description: d
steps:
  - id: s
    name: S
    prompt: p
    contextOutputs: [summary]
    outputs:
      summary:
        format: nope
''';
          expect(
            () => WorkflowDefinitionParser().parse(yaml),
            throwsA(
              isA<FormatException>().having(
                (e) => e.message,
                'message',
                allOf(contains('contextOutputs: is removed'), isNot(contains('unknown format'))),
              ),
            ),
          );
        });

        test('absence of outputs YAML key leaves outputs null', () {
          const yaml = '''
name: n
description: d
steps:
  - id: s
    name: S
    prompt: p
''';
          final def = WorkflowDefinitionParser().parse(yaml);
          expect(def.steps[0].outputs, isNull);
          expect(def.steps[0].outputKeys, isEmpty);
        });

        test('set_value snake_case alias parses identically to setValue', () {
          const yaml = '''
name: n
description: d
steps:
  - id: s
    name: S
    prompt: p
    outputs:
      k:
        format: text
        set_value: "alias-form"
''';
          final def = parser.parse(yaml);
          final config = def.steps[0].outputs!['k']!;
          expect(config.hasSetValue, isTrue);
          expect(config.setValue, 'alias-form');
        });
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

  group('loop finalizer parsing', () {
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

    test('legacy loop missing id throws FormatException', () {
      const yaml = '''
name: n
description: d
steps:
  - id: loop-step
    name: Loop Step
    prompt: p
loops:
  - steps:
      - loop-step
    maxIterations: 3
    exitGate: loop-step.done == true
''';
      expect(() => parser.parse(yaml), throwsA(isA<FormatException>()));
    });

    test('legacy loop missing maxIterations throws FormatException', () {
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
    exitGate: loop-step.done == true
''';
      expect(() => parser.parse(yaml), throwsA(isA<FormatException>()));
    });

    test('legacy loop maxIterations zero throws FormatException', () {
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
    maxIterations: 0
    exitGate: loop-step.done == true
''';
      expect(() => parser.parse(yaml), throwsA(isA<FormatException>()));
    });

    test('legacy loop maxIterations negative throws FormatException', () {
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
    maxIterations: -5
    exitGate: loop-step.done == true
''';
      expect(() => parser.parse(yaml), throwsA(isA<FormatException>()));
    });

    test('loops as non-list scalar throws FormatException', () {
      const yaml = '''
name: n
description: d
steps:
  - id: s
    name: S
    prompt: p
loops: not_a_list
''';
      expect(
        () => parser.parse(yaml),
        throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('"loops"'))),
      );
    });
  });

  group('stepDefaults parsing', () {
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

  group('step maxCostUsd parsing', () {
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
    skill: andthen-review
    prompt: Also do this.
''';
      final def = parser.parse(yaml);
      expect(def.steps[0].skill, 'andthen-review');
      expect(def.steps[0].prompt, 'Also do this.');
    });

    test('skill-only step (no prompt) is valid', () {
      const yaml = '''
name: n
description: d
steps:
  - id: s
    name: S
    skill: andthen-review
''';
      final def = parser.parse(yaml);
      expect(def.steps[0].skill, 'andthen-review');
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

  group('map step fields', () {
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

    test('parses `as:` loop variable name on a map step', () {
      const yaml = '''
name: n
description: d
steps:
  - id: s
    name: S
    prompt: 'Implement {{story.item.spec_path}}'
    map_over: story_specs
    as: story
''';
      final def = parser.parse(yaml);
      expect(def.steps[0].mapAlias, 'story');
    });

    test('parses camelCase alias `mapAlias:` as the same field', () {
      const yaml = '''
name: n
description: d
steps:
  - id: s
    name: S
    prompt: p
    map_over: items
    mapAlias: thing
''';
      final def = parser.parse(yaml);
      expect(def.steps[0].mapAlias, 'thing');
    });

    test('absent `as:` defaults to null (legacy `map.*` only)', () {
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
      expect(def.steps[0].mapAlias, isNull);
    });

    test('rejects invalid identifier on `as:`', () {
      const yaml = '''
name: n
description: d
steps:
  - id: s
    name: S
    prompt: p
    map_over: items
    as: "has-hyphen"
''';
      expect(() => parser.parse(yaml), throwsFormatException);
    });

    test('rejects reserved prefix `as: map`', () {
      const yaml = '''
name: n
description: d
steps:
  - id: s
    name: S
    prompt: p
    map_over: items
    as: map
''';
      expect(() => parser.parse(yaml), throwsFormatException);
    });

    test('rejects reserved prefix `as: context`', () {
      const yaml = '''
name: n
description: d
steps:
  - id: s
    name: S
    prompt: p
    map_over: items
    as: context
''';
      expect(() => parser.parse(yaml), throwsFormatException);
    });

    test('parses `as:` on an inline `type: foreach` controller', () {
      // Regression: inline foreach goes through _parseInlineForeachStep, not
      // _parseStep. The alias must propagate through the foreach-specific path.
      const yaml = '''
name: n
description: d
steps:
  - id: story-pipeline
    name: Per-Story Pipeline
    type: foreach
    map_over: stories
    as: story
    steps:
      - id: implement
        name: Implement
        prompt: 'Implement {{story.item.spec_path}}'
''';
      final def = parser.parse(yaml);
      final controller = def.steps.firstWhere((s) => s.id == 'story-pipeline');
      expect(controller.mapAlias, 'story');
      expect(controller.isForeachController, isTrue);
    });

    test('parses `mapAlias:` camelCase alias on inline foreach', () {
      const yaml = '''
name: n
description: d
steps:
  - id: fe
    name: FE
    type: foreach
    map_over: items
    mapAlias: thing
    steps:
      - id: step
        name: Step
        prompt: p
''';
      final def = parser.parse(yaml);
      final controller = def.steps.firstWhere((s) => s.id == 'fe');
      expect(controller.mapAlias, 'thing');
    });

    test('rejects reserved `as: context` on inline foreach', () {
      const yaml = '''
name: n
description: d
steps:
  - id: fe
    name: FE
    type: foreach
    map_over: items
    as: context
    steps:
      - id: step
        name: Step
        prompt: p
''';
      expect(() => parser.parse(yaml), throwsFormatException);
    });

    test('rejects empty string `as: ""`', () {
      const yaml = '''
name: n
description: d
steps:
  - id: s
    name: S
    prompt: p
    map_over: items
    as: ""
''';
      expect(() => parser.parse(yaml), throwsFormatException);
    });

    test('rejects whitespace-only `as: "   "`', () {
      const yaml = '''
name: n
description: d
steps:
  - id: s
    name: S
    prompt: p
    map_over: items
    as: "   "
''';
      expect(() => parser.parse(yaml), throwsFormatException);
    });

    test('rejects non-string `as: 42`', () {
      const yaml = '''
name: n
description: d
steps:
  - id: s
    name: S
    prompt: p
    map_over: items
    as: 42
''';
      expect(() => parser.parse(yaml), throwsFormatException);
    });

    test('accepts single-letter `as: m` (substring of reserved "map")', () {
      // Guard against over-eager prefix matching on reserved names.
      const yaml = '''
name: n
description: d
steps:
  - id: s
    name: S
    prompt: 'hi {{m.item.x}}'
    map_over: items
    as: m
''';
      final def = parser.parse(yaml);
      expect(def.steps[0].mapAlias, 'm');
    });

    test('accepts `as: map_foo` (starts with "map" but not a dotted map ref)', () {
      const yaml = '''
name: n
description: d
steps:
  - id: s
    name: S
    prompt: 'hi {{map_foo.item.x}}'
    map_over: items
    as: map_foo
''';
      final def = parser.parse(yaml);
      expect(def.steps[0].mapAlias, 'map_foo');
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

    test('max_parallel 0 throws FormatException', () {
      const yaml = '''
name: n
description: d
steps:
  - id: s
    name: S
    prompt: p
    map_over: items
    max_parallel: 0
''';
      expect(
        () => parser.parse(yaml),
        throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('positive integer'))),
      );
    });

    test('max_parallel negative throws FormatException', () {
      const yaml = '''
name: n
description: d
steps:
  - id: s
    name: S
    prompt: p
    map_over: items
    max_parallel: -2
''';
      expect(
        () => parser.parse(yaml),
        throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('positive integer'))),
      );
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

  group('hybrid step fields (bash, approval, continueSession, onError, workdir)', () {
    test('bash step without prompt or skill parses successfully', () {
      const yaml = '''
name: n
description: d
steps:
  - id: run-tests
    name: Run Tests
    type: bash
''';
      final def = parser.parse(yaml);
      final step = def.steps[0];
      expect(step.id, 'run-tests');
      expect(step.type, 'bash');
      expect(step.prompts, isNull);
      expect(step.skill, isNull);
    });

    test('approval step without prompt or skill parses successfully', () {
      const yaml = '''
name: n
description: d
steps:
  - id: await-approval
    name: Await Approval
    type: approval
''';
      final def = parser.parse(yaml);
      final step = def.steps[0];
      expect(step.type, 'approval');
      expect(step.prompts, isNull);
      expect(step.skill, isNull);
    });

    test('continueSession step reference parses correctly', () {
      const yaml = '''
name: n
description: d
steps:
  - id: s1
    name: Step One
    prompt: First prompt
  - id: s2
    name: Step Two
    prompt: Follow up
    continueSession: s1
''';
      final def = parser.parse(yaml);
      expect(def.steps[0].continueSession, isNull);
      expect(def.steps[1].continueSession, 's1');
    });

    test('legacy continue_session boolean alias parses correctly', () {
      const yaml = '''
name: n
description: d
steps:
  - id: s1
    name: Step One
    prompt: p
    continue_session: true
''';
      final def = parser.parse(yaml);
      expect(def.steps[0].continueSession, '@previous');
    });

    test('continueSession defaults to null when absent', () {
      const yaml = '''
name: n
description: d
steps:
  - id: s
    name: S
    prompt: p
''';
      final def = parser.parse(yaml);
      expect(def.steps[0].continueSession, isNull);
    });

    test('onError field parses correctly', () {
      const yaml = '''
name: n
description: d
steps:
  - id: s
    name: S
    type: bash
    onError: continue
''';
      final def = parser.parse(yaml);
      expect(def.steps[0].onError, 'continue');
    });

    test('on_error (snake_case alias) parses correctly', () {
      const yaml = '''
name: n
description: d
steps:
  - id: s
    name: S
    type: bash
    on_error: retry
''';
      final def = parser.parse(yaml);
      expect(def.steps[0].onError, 'retry');
    });

    test('onError defaults to null when absent', () {
      const yaml = '''
name: n
description: d
steps:
  - id: s
    name: S
    prompt: p
''';
      final def = parser.parse(yaml);
      expect(def.steps[0].onError, isNull);
    });

    test('workdir field parses correctly', () {
      const yaml = '''
name: n
description: d
steps:
  - id: s
    name: S
    type: bash
    workdir: /tmp/workspace
''';
      final def = parser.parse(yaml);
      expect(def.steps[0].workdir, '/tmp/workspace');
    });

    test('timeoutSeconds alias parses correctly', () {
      const yaml = '''
name: n
description: d
steps:
  - id: s
    name: S
    prompt: p
    timeoutSeconds: 45
''';
      final def = parser.parse(yaml);
      expect(def.steps[0].timeoutSeconds, 45);
    });

    test('workdir defaults to null when absent', () {
      const yaml = '''
name: n
description: d
steps:
  - id: s
    name: S
    prompt: p
''';
      final def = parser.parse(yaml);
      expect(def.steps[0].workdir, isNull);
    });

    test('hybrid bash step with all new fields', () {
      const yaml = r'''
name: n
description: d
variables:
  WORKSPACE:
    required: true
steps:
  - id: build
    name: Build Project
    type: bash
    workdir: '{{WORKSPACE}}'
    onError: retry
    maxRetries: 2
''';
      final def = parser.parse(yaml);
      final step = def.steps[0];
      expect(step.type, 'bash');
      expect(step.workdir, '{{WORKSPACE}}');
      expect(step.onError, 'retry');
      expect(step.maxRetries, 2);
      expect(step.prompts, isNull);
    });

    test('legacy research/coding steps still parse unchanged (backward compat)', () {
      const yaml = '''
name: n
description: d
steps:
  - id: s1
    name: Research
    prompt: Do research
    type: research
  - id: s2
    name: Coding
    prompt: Write code
    type: coding
''';
      final def = parser.parse(yaml);
      expect(def.steps[0].type, 'research');
      expect(def.steps[0].continueSession, isNull);
      expect(def.steps[0].onError, isNull);
      expect(def.steps[0].workdir, isNull);
      expect(def.steps[1].type, 'coding');
    });

    test('step without skill or prompt still throws for non-hybrid types', () {
      const yaml = '''
name: n
description: d
steps:
  - id: s
    name: S
    type: research
''';
      expect(() => parser.parse(yaml), throwsA(isA<FormatException>()));
    });
  });

  group('foreach step parsing', () {
    test('parses valid inline foreach step with child steps', () {
      const yaml = '''
name: foreach-wf
description: Foreach test
steps:
  - id: plan
    name: Plan
    prompt: Make a plan
  - id: story-pipeline
    name: Story Pipeline
    type: foreach
    map_over: stories
    outputs:
      story_results:
        format: json
    steps:
      - id: implement
        name: Implement
        prompt: Build {{map.item}}
        type: coding
      - id: validate
        name: Validate
        prompt: Validate {{map.item}}
      - id: review
        name: Review
        prompt: Review {{map.item}}
  - id: publish
    name: Publish
    prompt: Publish
''';
      final def = parser.parse(yaml);
      // Controller + 3 child steps + plan + publish = 6 steps total.
      expect(def.steps.length, 6);

      final controller = def.steps[1];
      expect(controller.id, 'story-pipeline');
      expect(controller.type, 'foreach');
      expect(controller.mapOver, 'stories');
      expect(controller.isForeachController, isTrue);
      expect(controller.foreachSteps, ['implement', 'validate', 'review']);
      expect(controller.outputKeys, ['story_results']);

      // Child steps follow controller in step list.
      expect(def.steps[2].id, 'implement');
      expect(def.steps[3].id, 'validate');
      expect(def.steps[4].id, 'review');

      // Normalization produces ForeachNode.
      expect(def.nodes.length, 3); // ActionNode(plan), ForeachNode, ActionNode(publish)
      expect(def.nodes[1], isA<ForeachNode>());
      final foreachNode = def.nodes[1] as ForeachNode;
      expect(foreachNode.stepId, 'story-pipeline');
      expect(foreachNode.childStepIds, ['implement', 'validate', 'review']);
    });

    test('foreach with max_parallel and max_items parses correctly', () {
      const yaml = '''
name: n
description: d
steps:
  - id: fe
    name: FE
    type: foreach
    map_over: items
    max_parallel: 2
    max_items: 50
    steps:
      - id: child
        name: Child
        prompt: Process {{map.item}}
''';
      final def = parser.parse(yaml);
      final controller = def.steps[0];
      expect(controller.maxParallel, 2);
      expect(controller.maxItems, 50);
    });

    test('nested foreach inside foreach throws FormatException', () {
      const yaml = '''
name: n
description: d
steps:
  - id: outer
    name: Outer
    type: foreach
    map_over: items
    steps:
      - id: inner
        name: Inner
        type: foreach
        map_over: sub_items
        steps:
          - id: leaf
            name: Leaf
            prompt: Do thing
''';
      expect(() => parser.parse(yaml), throwsFormatException);
    });

    test('nested loop inside foreach throws FormatException', () {
      const yaml = '''
name: n
description: d
steps:
  - id: outer
    name: Outer
    type: foreach
    map_over: items
    steps:
      - id: inner
        name: Inner
        type: loop
        steps:
          - id: leaf
            name: Leaf
            prompt: Do thing
        exitGate: leaf.done == true
''';
      expect(() => parser.parse(yaml), throwsFormatException);
    });

    test('foreach without map_over throws FormatException', () {
      const yaml = '''
name: n
description: d
steps:
  - id: fe
    name: FE
    type: foreach
    steps:
      - id: child
        name: Child
        prompt: Do thing
''';
      expect(() => parser.parse(yaml), throwsFormatException);
    });

    test('foreach with empty steps list throws FormatException', () {
      const yaml = '''
name: n
description: d
steps:
  - id: fe
    name: FE
    type: foreach
    map_over: items
    steps: []
''';
      expect(() => parser.parse(yaml), throwsFormatException);
    });

    test('foreach without steps field throws FormatException', () {
      const yaml = '''
name: n
description: d
steps:
  - id: fe
    name: FE
    type: foreach
    map_over: items
''';
      expect(() => parser.parse(yaml), throwsFormatException);
    });

    test('foreach round-trips through toJson/fromJson', () {
      const yaml = '''
name: foreach-roundtrip
description: RT test
steps:
  - id: fe
    name: FE
    type: foreach
    map_over: items
    steps:
      - id: c1
        name: C1
        prompt: First
      - id: c2
        name: C2
        prompt: Second
''';
      final def = parser.parse(yaml);
      final restored = WorkflowDefinition.fromJson(def.toJson());
      expect(restored.nodes.length, def.nodes.length);
      expect(restored.nodes[0], isA<ForeachNode>());
      final foreachNode = restored.nodes[0] as ForeachNode;
      expect(foreachNode.stepId, 'fe');
      expect(foreachNode.childStepIds, ['c1', 'c2']);
    });

    test('parses entryGate on any step', () {
      const yaml = '''
name: gated
description: step-level entryGate
steps:
  - id: prd
    name: PRD
    prompt: Produce PRD
  - id: review-prd
    name: Review PRD
    prompt: Review
    entryGate: "prd_source == synthesized"
    inputs: [prd]
''';
      final def = parser.parse(yaml);
      expect(def.steps[0].entryGate, isNull);
      expect(def.steps[1].entryGate, 'prd_source == synthesized');
      final restored = WorkflowDefinition.fromJson(def.toJson());
      expect(restored.steps[1].entryGate, 'prd_source == synthesized');
    });

    test('parses gitStrategy.artifacts + externalArtifactMount', () {
      const yaml = '''
name: with-artifacts
description: artifact block
gitStrategy:
  bootstrap: true
  worktree:
    mode: per-map-item
    externalArtifactMount:
      mode: per-story-copy
      fromProject: "{{DOC_PROJECT}}"
      source: "{{map.item.spec_path}}"
  artifacts:
    commit: true
    commitMessage: "chore(workflow): artifacts for run {{runId}}"
    project: "{{DOC_PROJECT}}"
steps:
  - id: s1
    name: S1
    prompt: hi
''';
      final def = parser.parse(yaml);
      final artifacts = def.gitStrategy!.artifacts!;
      expect(artifacts.commit, isTrue);
      expect(artifacts.commitMessage, 'chore(workflow): artifacts for run {{runId}}');
      expect(artifacts.project, '{{DOC_PROJECT}}');
      final mount = def.gitStrategy!.externalArtifactMount!;
      expect(mount.mode, 'per-story-copy');
      expect(mount.fromProject, '{{DOC_PROJECT}}');
      expect(mount.source, '{{map.item.spec_path}}');
    });

    test('rejects unknown externalArtifactMount mode', () {
      const yaml = '''
name: bad-mount
description: invalid mode
gitStrategy:
  worktree:
    externalArtifactMount:
      mode: symlink
      fromProject: OTHER
steps:
  - id: s
    name: S
    prompt: hi
''';
      expect(() => parser.parse(yaml), throwsA(isA<FormatException>()));
    });
  });
}
