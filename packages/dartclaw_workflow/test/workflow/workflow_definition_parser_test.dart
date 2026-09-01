import 'package:dartclaw_workflow/dartclaw_workflow.dart';
import 'package:test/test.dart';

import '_support/workflow_parser_test_support.dart';

void main() {
  late WorkflowDefinitionParser parser;

  setUp(() {
    parser = WorkflowDefinitionParser();
  });

  group('WorkflowDefinitionParser.parse', () {
    String aggregateReviewsYaml(String aggregateReviews) =>
        '''
name: aggregate-workflow
description: Workflow with review aggregation
steps:
  - id: review-aggregate
    name: Review Aggregate
    type: aggregate-reviews
    aggregateReviews: $aggregateReviews
    outputs:
      review_report_path: review_report_path
      findings_count: findings_count
      gating_findings_count: gating_findings_count
''';

    test('parses minimal YAML', () {
      final def = parser.parse(minimalWorkflowYaml);
      expectMinimalWorkflowDefinition(def);
    });

    test('parses full YAML with all features', () {
      final def = parser.parse(fullWorkflowYaml);
      expectFullWorkflowDefinition(def);
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

    test('rejects blank step and step-default providers', () {
      expectParseFormatError(stepYaml("prompt: Run\nprovider: '   '"), messageContains: ['provider', 'blank']);
      expectParseFormatError(
        workflowYaml(
          rootFields: '''
stepDefaults:
  - match: "*"
    provider: " "''',
          stepFields: 'prompt: Run',
        ),
        messageContains: ['stepDefaults.provider', 'blank'],
      );
    });

    test('parses aggregateReviews on aggregate-reviews steps', () {
      const yaml = '''
name: aggregate-workflow
description: Workflow with review aggregation
steps:
  - id: review-a
    name: Review A
    prompt: Review A
  - id: review-b
    name: Review B
    prompt: Review B
  - id: review-aggregate
    name: Review Aggregate
    type: aggregate-reviews
    aggregateReviews: [review-a, review-b]
    outputs:
      review_report_path: review_report_path
      findings_count: findings_count
      gating_findings_count: gating_findings_count
''';
      final def = parser.parse(yaml);
      final step = def.steps.last;
      expect(step.taskType, WorkflowTaskType.aggregateReviews);
      expect(step.aggregateReviews, ['review-a', 'review-b']);
    });

    test('rejects empty aggregateReviews list', () {
      expect(
        () => parser.parse(aggregateReviewsYaml('[]')),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            allOf(
              contains('review-aggregate'),
              contains('aggregateReviews must list at least one upstream step id'),
              contains('[]'),
            ),
          ),
        ),
      );
    });

    test('rejects non-list and non-string aggregateReviews values', () {
      expect(
        () => parser.parse(aggregateReviewsYaml('review-a')),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            allOf(contains('review-aggregate'), contains('aggregateReviews must be a list'), contains('review-a')),
          ),
        ),
      );

      expect(
        () => parser.parse(aggregateReviewsYaml('[review-a, 7]')),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            allOf(contains('review-aggregate'), contains('aggregateReviews entries must be non-empty strings')),
          ),
        ),
      );
    });

    test('malformed core sections throw FormatException with field paths', () {
      const yaml = '''
name: malformed-workflow
description: Malformed workflow
maxTokens: many
variables: []
steps:
  - id: step-1
    name: Step One
    prompt: Do something
''';

      expect(() => parser.parse(yaml), throwsA(isA<FormatException>()));
    });

    test('malformed outputs and string lists throw FormatException', () {
      const yaml = '''
name: malformed-workflow
description: Malformed workflow
steps:
  - id: step-1
    name: Step One
    prompt: Do something
    inputs: nope
    outputs: []
''';

      expect(() => parser.parse(yaml), throwsA(isA<FormatException>()));
    });

    test('parses gitStrategy.worktree: auto', () {
      final def = parser.parse(autoWorktreeWorkflowYaml);
      expect(def.gitStrategy?.worktreeMode, 'auto');
      expect(def.gitStrategy?.worktree?.mode, WorkflowGitWorktreeMode.auto);
    });

    test('parses gitStrategy.worktree string modes as enums with unchanged JSON', () {
      const yaml = '''
name: wf
description: d
gitStrategy:
  worktree: per-task
steps:
  - id: s
    name: S
    prompt: hi
''';
      final def = parser.parse(yaml);
      expect(def.gitStrategy?.worktree?.mode, WorkflowGitWorktreeMode.perTask);
      expect(def.toJson()['gitStrategy'], {'worktree': 'per-task'});
    });

    test('rejects unknown gitStrategy.worktree mode with known values', () {
      expectParseFormatError(
        workflowYaml(
          rootFields: '''
gitStrategy:
  worktree:
    mode: branch-per-step''',
          stepFields: 'prompt: hi',
        ),
        messageContains: ['shared', 'per-task', 'per-map-item', 'inline', 'auto'],
      );
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
    });

    test('parses workflow-level project', () {
      final def = parser.parse(gitStrategyWorkflowYaml);
      expect(def.project, '{{PROJECT}}');
    });

    test('rejects non-string workflow-level project', () {
      expectParseFormatError(
        workflowYaml(
          description: 'desc',
          rootFields: '''
project:
  nested: nope''',
          stepFields: 'prompt: Hello',
        ),
      );
    });

    // One authority rejects unknown fields — `_rejectUnknownFields` — but it
    // labels the block it was reading, and a block whose label never appears
    // here is a block whose parse path is unguarded. This table is the complete
    // enumeration of the twelve labels the parser can emit. Typo keys, not keys
    // the DSL once had: a retired key can be re-introduced, a typo cannot.
    for (final row in const [
      (label: 'workflow', key: 'lops', rootFields: 'lops: []', stepFields: null),
      (label: 'Step "s"', key: 'outpts', rootFields: null, stepFields: 'prompt: p\noutpts: []'),
      (
        label: 'variables.FEATURE',
        key: 'defualt',
        rootFields: 'variables:\n  FEATURE:\n    defualt: x',
        stepFields: null,
      ),
      (
        label: 'Step "s" output "k"',
        key: 'pathPatern',
        rootFields: null,
        stepFields: 'prompt: p\noutputs:\n  k:\n    format: path\n    pathPatern: x',
      ),
      (
        label: 'stepDefaults "*"',
        key: 'prompTt',
        rootFields: 'stepDefaults:\n  - match: "*"\n    prompTt: p',
        stepFields: null,
      ),
      (
        label: 'gitStrategy',
        key: 'integrationBrnach',
        rootFields: 'gitStrategy:\n  integrationBrnach: true',
        stepFields: null,
      ),
      (
        label: 'gitStrategy.worktree',
        key: 'baseReff',
        rootFields: 'gitStrategy:\n  worktree:\n    mode: shared\n    baseReff: main',
        stepFields: null,
      ),
      (
        label: 'gitStrategy.publish',
        key: 'enabld',
        rootFields: 'gitStrategy:\n  publish:\n    enabld: true',
        stepFields: null,
      ),
      (
        label: 'gitStrategy.artifacts',
        key: 'commmit',
        rootFields: 'gitStrategy:\n  artifacts:\n    commmit: true',
        stepFields: null,
      ),
      (
        label: 'gitStrategy.cleanup',
        key: 'branchs',
        rootFields: 'gitStrategy:\n  cleanup:\n    enabled: true\n    branchs: false',
        stepFields: null,
      ),
      (
        label: 'Foreach "s"',
        key: 'max_parallell',
        rootFields: null,
        stepFields:
            'type: foreach\nmap_over: items\nmax_parallell: 2\nsteps:\n  - id: child\n    name: Child\n    prompt: p',
      ),
      (
        label: 'Inline loop "s"',
        key: 'exitGaate',
        rootFields: null,
        stepFields: 'type: loop\nmaxIterations: 2\nexitGate: never\nexitGaate: never\nsteps:\n  - id: child\n    name: Child\n    prompt: p',
      ),
    ]) {
      test('the uniform field check names the ${row.label} block', () {
        final source = row.stepFields != null
            ? stepYaml(row.stepFields!)
            : workflowYaml(rootFields: row.rootFields!, stepFields: 'prompt: p');
        // One string, not three substrings: `under gitStrategy` is a prefix of
        // four other labels, and a key/label pair from different blocks would
        // otherwise satisfy a split assertion.
        expectParseFormatError(
          source,
          // The source path rides the same message and closes it, so the one
          // string pins the key, the block and the file together. A parse
          // failure that cannot name the file is not actionable for an author.
          sourcePath: 'wf.yaml',
          messageContains: ['Unknown field "${row.key}" under ${row.label} in "wf.yaml".'],
        );
      });
    }

    test('every preserved authoring key still parses into its model field', () {
      final step = parseStep(parser, '''
prompt: p
entryGate: spec_ready == true
onError: continue
onFailure: continue
parallel: true
turn_timeout: 90m
outputs:
  prd:
    format: path
    pathPattern: '**/*prd.md'
    preferPatterns: ['prd.md']''');

      expect(step.entryGate, 'spec_ready == true');
      expect(step.onError, OnErrorPolicy.continueWorkflow);
      expect(step.onFailure, OnFailurePolicy.continueWorkflow);
      expect(step.parallel, isTrue);
      expect(step.turnTimeoutSeconds, 5400);
      final resolver = step.outputs!['prd']!.resolverOverride;
      expect(resolver, isA<FileSystemOutput>());
      expect((resolver as FileSystemOutput).pathPattern, '**/*prd.md');
      expect(resolver.preferPatterns, ['prd.md']);

      final approval = parser.parse(stepYaml('type: approval\nprompt: Approve?')).steps.single;
      expect(approval.taskType, WorkflowTaskType.approval);
    });

    test('parses inline loop authoring', () {
      final definition = parser.parse(inlineLoopWorkflowYaml);

      expect(definition.nodes.map((node) => node.runtimeType).toList(), equals([ActionNode, LoopNode, ActionNode]));
      expect((definition.nodes[1] as LoopNode).loopId, 'remediation-loop');
      expect((definition.nodes[1] as LoopNode).stepIds, equals(['remediate', 're-review']));
      expect(definition.loops.single.entryGate, 'gap-analysis.findings_count > 0');
    });

    test('inline loop reads onMaxIterations; omitting the key defaults to fail (TI02)', () {
      const withContinue = '''
name: continue-loop
description: Inline loop opting into continue-on-exhaustion
steps:
  - id: remediation-loop
    name: Remediation Loop
    type: loop
    maxIterations: 3
    exitGate: re-review.status == accepted
    onMaxIterations: continue
    steps:
      - id: re-review
        name: Re-review
        prompt: Check the fixes
''';
      final withDef = parser.parse(withContinue);
      expect(withDef.loops.single.onMaxIterations, 'continue');

      // The default inline loop fixture omits the key.
      final defaulted = parser.parse(inlineLoopWorkflowYaml);
      expect(defaulted.loops.single.onMaxIterations, 'fail');
    });

    test('parses reusable gitStrategy blocks for user-authored workflows', () {
      final definition = parser.parse(gitStrategyWorkflowYaml);
      expect(
        definition.toJson()['gitStrategy'],
        equals({
          'integrationBranch': true,
          'worktree': 'shared',
          'promotion': 'merge',
          'publish': {'enabled': true},
        }),
      );
    });

    test('rejects conflicting gitStrategy.integrationBranch spellings', () {
      final yaml = workflowYaml(
        rootFields: '''
gitStrategy:
  integrationBranch: true
  integration_branch: false''',
      );

      expect(
        () => parser.parse(yaml),
        throwsA(
          isA<FormatException>()
              .having(
                (e) => e.message,
                'message',
                allOf(contains('gitStrategy.integrationBranch'), contains('gitStrategy.integration_branch')),
              )
              .having((e) => e.message, 'message', isNot(contains('gitStrategy.bootstrap'))),
        ),
      );
    });

    test('accepts legacy gitStrategy.bootstrap as an input alias', () {
      final definition = parser.parse(
        workflowYaml(
          rootFields: '''
gitStrategy:
  bootstrap: true''',
        ),
      );

      expect(definition.gitStrategy!.integrationBranch, isTrue);
      expect(definition.gitStrategy!.toJson(), containsPair('integrationBranch', true));
      expect(definition.gitStrategy!.toJson(), isNot(contains('bootstrap')));
    });

    test('rejects conflicting gitStrategy.bootstrap alias', () {
      final yaml = workflowYaml(
        rootFields: '''
gitStrategy:
  integrationBranch: true
  bootstrap: false''',
      );

      expect(
        () => parser.parse(yaml),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            allOf(contains('gitStrategy.integrationBranch'), contains('gitStrategy.bootstrap')),
          ),
        ),
      );
    });

    test('accepts agreeing gitStrategy.integrationBranch spellings', () {
      final definition = parser.parse(
        workflowYaml(
          rootFields: '''
gitStrategy:
  integrationBranch: true
  integration_branch: true''',
        ),
      );

      expect(definition.gitStrategy!.integrationBranch, isTrue);
    });

    for (final row in const [
      (name: 'cleanup.enabled: false', rootFields: 'gitStrategy:\n  cleanup:\n    enabled: false', enabled: false),
      (name: 'cleanup.enabled: true', rootFields: 'gitStrategy:\n  cleanup:\n    enabled: true', enabled: true),
      (name: 'cleanup omitted', rootFields: 'gitStrategy:\n  integrationBranch: true', enabled: true),
    ]) {
      test('parses gitStrategy.${row.name}', () {
        final def = parser.parse(workflowYaml(rootFields: row.rootFields));
        if (row.name == 'cleanup omitted') expect(def.gitStrategy?.cleanup, isNull);
        expect(def.gitStrategy?.cleanupEnabled, row.enabled);
        if (row.name != 'cleanup omitted') expect(def.gitStrategy?.cleanup, row.enabled);
      });
    }

    for (final row in const [
      (
        name: 'unknown subkey',
        rootFields: 'gitStrategy:\n  cleanup:\n    enabled: true\n    branches: false',
        messageContains: ['Unknown field', '"branches"', 'gitStrategy.cleanup'],
      ),
      (
        name: 'non-boolean enabled',
        rootFields: 'gitStrategy:\n  cleanup:\n    enabled: "true"',
        messageContains: ['gitStrategy.cleanup.enabled'],
      ),
      (
        name: 'non-mapping cleanup',
        rootFields: 'gitStrategy:\n  cleanup: preserve-on-failure',
        messageContains: ['gitStrategy.cleanup'],
      ),
    ]) {
      test('rejects gitStrategy.cleanup ${row.name}', () {
        expectParseFormatError(workflowYaml(rootFields: row.rootFields), messageContains: row.messageContains);
      });
    }

    test('agent step turn_timeout parses and timeout is refused', () {
      final step = parseStep(parser, 'prompt: p\nturn_timeout: "30m"');
      expect(step.turnTimeoutSeconds, 1800);
      expect(
        () => parseStep(parser, 'prompt: p\ntimeout: "30m"'),
        throwsA(isA<FormatException>().having((error) => error.message, 'message', contains('turn_timeout'))),
      );
    });

    test('turn_timeout rejects negative values but accepts zero', () {
      expect(parseStep(parser, 'prompt: p\nturn_timeout: 0').turnTimeoutSeconds, 0);
      expect(
        () => parseStep(parser, 'prompt: p\nturn_timeout: -1'),
        throwsA(isA<FormatException>().having((error) => error.message, 'message', contains('zero or greater'))),
      );
    });

    test('parses parallel: true', () {
      final step = parseStep(parser, 'prompt: p\nparallel: true');
      expect(step.parallel, true);
    });

    test('parses inputs as a string list and outputs as a map', () {
      final step = parseStep(parser, '''
prompt: p
inputs:
  - in_a
  - in_b
outputs:
  out_c:
    format: text
''');
      expect(step.inputs, ['in_a', 'in_b']);
      expect(step.outputKeys, ['out_c']);
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

    test('parses task type field as enum and preserves wire JSON', () {
      final expected = {
        'agent': WorkflowTaskType.agent,
        'bash': WorkflowTaskType.bash,
        'approval': WorkflowTaskType.approval,
        'foreach': WorkflowTaskType.foreach,
        'loop': WorkflowTaskType.loop,
        'aggregate-reviews': WorkflowTaskType.aggregateReviews,
      };
      for (final entry in expected.entries) {
        final yaml = switch (entry.value) {
          WorkflowTaskType.agent => stepYaml('type: agent\nprompt: p'),
          WorkflowTaskType.bash => stepYaml('type: bash\nscript: echo ok'),
          WorkflowTaskType.approval => stepYaml('type: approval'),
          WorkflowTaskType.foreach => stepYaml('''
type: foreach
map_over: items
steps:
  - id: child
    name: Child
    prompt: p'''),
          WorkflowTaskType.loop => stepYaml('''
type: loop
maxIterations: 1
exitGate: done
steps:
  - id: child
    name: Child
    prompt: p'''),
          WorkflowTaskType.aggregateReviews =>
            '''
name: n
description: d
steps:
  - id: review-a
    name: Review A
    prompt: p
  - id: s
    name: S
    type: aggregate-reviews
    aggregateReviews: [review-a]
''',
        };
        final definition = parser.parse(yaml);
        if (entry.value == WorkflowTaskType.loop) {
          expect(definition.loops.single.id, 's');
          continue;
        }
        final matchingStep = definition.steps.firstWhere((candidate) => candidate.id == 's');
        expect(matchingStep.taskType, entry.value);
        if (entry.value == WorkflowTaskType.agent) {
          expect(matchingStep.toJson().containsKey('type'), isFalse);
        } else {
          expect(matchingStep.toJson()['type'], entry.key);
        }
      }
    });

    test('rejects unknown task type with known values', () {
      expectParseFormatError(
        stepYaml('prompt: p\ntype: typo'),
        messageContains: ['typo', 'agent', 'bash', 'approval', 'foreach', 'loop', 'aggregate-reviews'],
      );
    });

    test('rejects legacy custom task type with rename hint', () {
      expectParseFormatError(
        stepYaml('prompt: p\ntype: custom'),
        messageContains: ['custom', 'agent-step marker has been renamed', '"agent"'],
      );
    });

    for (final testCase in const [
      (name: 'missing name', yaml: 'description: d\nsteps:\n  - id: s\n    name: S\n    prompt: p\n'),
      (name: 'missing description', yaml: 'name: n\nsteps:\n  - id: s\n    name: S\n    prompt: p\n'),
      (name: 'missing steps', yaml: 'name: n\ndescription: d\n'),
      (name: 'empty steps list', yaml: 'name: n\ndescription: d\nsteps: []\n'),
      (name: 'step missing id', yaml: 'name: n\ndescription: d\nsteps:\n  - name: S\n    prompt: p\n'),
    ]) {
      test('${testCase.name} throws FormatException', () {
        expect(() => parser.parse(testCase.yaml), throwsFormatException);
      });
    }

    test('step missing prompt throws FormatException', () {
      expectParseFormatError(stepYaml(''));
    });

    test('bash step accepts script as prompt alias', () {
      final step = parseStep(parser, 'type: bash\nscript: echo ok');
      expect(step.taskType, WorkflowTaskType.bash);
      expect(step.prompts, ['echo ok']);
    });

    test('bash step rejects both prompt and script', () {
      expectParseFormatError(stepYaml('type: bash\nprompt: echo ok\nscript: echo also-ok'));
    });

    test('agent step rejects script', () {
      expectParseFormatError(stepYaml('script: echo ok'));
    });

    group('outputs map parsing (S01)', () {
      for (final testCase in const [
        (
          name: 'map with format and preset schema',
          yaml: '''
outputs:
  result:
    format: json
    schema: verdict''',
          key: 'result',
          format: OutputFormat.json,
          preset: 'verdict',
          outputMode: null,
        ),
        (
          name: 'shorthand format syntax',
          yaml: 'outputs:\n  result: json',
          key: 'result',
          format: OutputFormat.json,
          preset: null,
          outputMode: null,
        ),
        (
          name: 'shorthand preset syntax',
          yaml: 'outputs:\n  diff_summary: diff_summary',
          key: 'diff_summary',
          format: OutputFormat.text,
          preset: 'diff_summary',
          outputMode: OutputMode.prompt,
        ),
        (
          name: 'json preset shorthand structured default',
          yaml: 'outputs:\n  findings_count: findings_count',
          key: 'findings_count',
          format: OutputFormat.json,
          preset: 'findings_count',
          outputMode: OutputMode.structured,
        ),
        (
          name: 'format keyword precedence over preset lookup',
          yaml: 'outputs:\n  raw: json',
          key: 'raw',
          format: OutputFormat.json,
          preset: null,
          outputMode: null,
        ),
      ]) {
        test('parses outputs ${testCase.name}', () {
          final output = parseStep(parser, 'prompt: p\n${testCase.yaml}').outputs![testCase.key]!;
          expect(output.format, testCase.format);
          expect(output.presetName, testCase.preset);
          expect(output.description, isNull);
          if (testCase.outputMode != null) expect(output.outputMode, testCase.outputMode);
        });
      }

      test('throws on unknown shorthand output identifier', () {
        const yaml = '''
name: n
description: d
steps:
  - id: parse
    name: Parse
    prompt: p
    outputs:
      thing: not_a_real_preset
''';
        expect(
          () => parser.parse(yaml),
          throwsA(
            isA<FormatException>()
                .having((e) => e.message, 'message', contains('Step "parse" output "thing"'))
                .having((e) => e.message, 'message', contains('not_a_real_preset'))
                .having((e) => e.message, 'message', contains('format keywords'))
                .having((e) => e.message, 'message', contains('registered schema preset')),
          ),
        );
      });

      test('parses lines format', () {
        expect(
          parseStep(parser, 'prompt: p\noutputs:\n  items:\n    format: lines').outputs!['items']!.format,
          OutputFormat.lines,
        );
      });

      test('S05: rejects the retired review_findings output key, naming review_report_path', () {
        for (final key in const ['review_findings', 'review-code.review_findings']) {
          expectParseFormatError(
            stepYaml('prompt: p\noutputs:\n  $key: review_report_path'),
            messageContains: ['review_findings', 'review_report_path', 'retired'],
          );
        }
      });

      test('parses inline schema as map', () {
        final config = parseStep(parser, r'''
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
          type: string''').outputs!['result']!;
        expect(config.format, OutputFormat.json);
        expect(config.inlineSchema, isNotNull);
        expect(config.inlineSchema!['type'], 'object');
        expect(config.inlineSchema!['required'], ['name']);
      });

      test('object-form output infers format from schema preset', () {
        final inferred = parseStep(parser, '''
prompt: p
outputs:
  findings_count:
    schema: non_negative_integer''').outputs!['findings_count']!;
        final explicit = parseStep(parser, '''
prompt: p
outputs:
  findings_count:
    format: json
    schema: non_negative_integer''').outputs!['findings_count']!;

        expect(inferred.format, OutputFormat.json);
        expect(inferred.outputMode, OutputMode.structured);
        expect(inferred.toJson(), explicit.toJson());
      });

      test('a format: path output round-trips its declared selector through json', () {
        final config = parseStep(parser, '''
prompt: p
outputs:
  spec_path:
    format: path
    pathPattern: '**/*.md'
    preferPatterns: ['spec.md']''').outputs!['spec_path']!;

        final resolver = config.resolverOverride;
        expect(resolver, isA<FileSystemOutput>());
        final fileSystemResolver = resolver! as FileSystemOutput;
        expect(fileSystemResolver.pathPattern, '**/*.md');
        expect(fileSystemResolver.preferPatterns, ['spec.md']);
        expect(fileSystemResolver.listMode, isFalse);

        final roundTrippedResolver = OutputConfig.fromJson(config.toJson()).resolverOverride as FileSystemOutput;
        expect(roundTrippedResolver.pathPattern, '**/*.md');
        expect(roundTrippedResolver.preferPatterns, ['spec.md']);
      });

      test('format path with pathPattern infers filesystem resolver', () {
        final inferred = parseStep(parser, '''
prompt: p
outputs:
  spec_path:
    format: path
    pathPattern: "**/*.md"''').outputs!['spec_path']!;

        final resolver = outputResolverFor('spec_path', inferred);
        expect(resolver, isA<FileSystemOutput>());
        expect((resolver as FileSystemOutput).pathPattern, '**/*.md');
        expect(resolver.matches('docs/spec.md'), isTrue);
      });

      test('format path with preferPatterns infers filesystem resolver', () {
        final inferred = parseStep(parser, '''
prompt: p
outputs:
  plan:
    format: path
    preferPatterns: ["plan.json"]''').outputs!['plan']!;

        final resolver = outputResolverFor('plan', inferred);
        expect(resolver, isA<FileSystemOutput>());
        expect((resolver as FileSystemOutput).preferPatterns, ['plan.json']);
      });

      test('rejects the path selector on a non-path output', () {
        expectParseFormatError(
          stepYaml('prompt: p\noutputs:\n  result:\n    format: text\n    pathPattern: "**/*.md"'),
          messageContains: ['pathPattern/preferPatterns', 'format: path'],
        );
      });

      test('throws on unknown format', () {
        expectParseFormatError(stepYaml('prompt: p\noutputs:\n  result:\n    format: invalid_format'));
      });

      test('mixes shorthand and map-form output entries', () {
        final outputs = parseStep(parser, '''
prompt: p
outputs:
  a: text
  b: lines
  c:
    format: path
    description: A path''').outputs!;
        expect(outputs['a']!.format, OutputFormat.text);
        expect(outputs['a']!.description, isNull);
        expect(outputs['b']!.format, OutputFormat.lines);
        expect(outputs['c']!.format, OutputFormat.path);
        expect(outputs['c']!.description, 'A path');
      });

      test('null outputs when field absent (backward compat)', () {
        expect(parseStep(parser, 'prompt: p').outputs, isNull);
      });

      group('outputs parsing', () {
        test('outputs-only step derives outputKeys from outputs.keys', () {
          final step = parseStep(parser, '''
prompt: p
outputs:
  summary:
    format: text
  count:
    format: json
    schema: non_negative_integer''');
          expect(step.outputKeys.toSet(), {'summary', 'count'});
        });

        test('unknown field error takes precedence over malformed outputs', () {
          final yaml = stepYaml('''
prompt: p
outpts: [summary]
outputs:
  summary:
    format: nope''');
          expect(
            () => parser.parse(yaml),
            throwsA(
              isA<FormatException>().having(
                (e) => e.message,
                'message',
                allOf(contains('Unknown field "outpts" under Step "s"'), isNot(contains('unknown format'))),
              ),
            ),
          );
        });

        test('absence of outputs YAML key leaves outputs null', () {
          final step = parseStep(parser, 'prompt: p');
          expect(step.outputs, isNull);
          expect(step.outputKeys, isEmpty);
        });
      });
    });

    group('multi-prompt (S02)', () {
      test('scalar string prompt normalizes to 1-element list', () {
        final step = parseStep(parser, 'prompt: Do the thing');
        expect(step.prompts, ['Do the thing']);
        expect(step.isMultiPrompt, false);
      });

      test('list prompt parses into multi-element list', () {
        final step = parseStep(parser, '''
prompt:
  - First prompt
  - Second prompt
  - Third prompt''');
        expect(step.prompts, ['First prompt', 'Second prompt', 'Third prompt']);
        expect(step.isMultiPrompt, true);
      });

      test('empty list prompt throws FormatException', () {
        expectParseFormatError(stepYaml('prompt: []'));
      });

      test('list with empty string element throws FormatException', () {
        expectParseFormatError(stepYaml("prompt:\n  - First\n  - ''"));
      });
    });
  });

  group('stepDefaults parsing', () {
    test('parses stepDefaults with multiple entries', () {
      final yaml = workflowYaml(
        stepFields: 'prompt: p',
        tailFields: '''
stepDefaults:
  - match: "review*"
    model: claude-opus-4
    turn_timeout: 900
  - match: "*"
    provider: claude''',
      );
      final def = parser.parse(yaml);
      expect(def.stepDefaults, isNotNull);
      expect(def.stepDefaults!.length, 2);
      expect(def.stepDefaults![0].match, 'review*');
      expect(def.stepDefaults![0].model, 'claude-opus-4');
      expect(def.stepDefaults![0].turnTimeoutSeconds, 900);
      expect(def.stepDefaults![1].match, '*');
      expect(def.stepDefaults![1].provider, 'claude');
    });

    test('parses without stepDefaults (backward compat)', () {
      final def = parser.parse(minimalWorkflowYaml);
      expect(def.stepDefaults, isNull);
    });

    test('stepDefaults turn_timeout accepts durations and zero but rejects negative values', () {
      final durationDefinition = parser.parse(
        workflowYaml(stepFields: 'prompt: p', tailFields: 'stepDefaults:\n  - match: "*"\n    turn_timeout: 90m'),
      );
      expect(durationDefinition.stepDefaults!.single.turnTimeoutSeconds, 5400);

      final definition = parser.parse(
        workflowYaml(stepFields: 'prompt: p', tailFields: 'stepDefaults:\n  - match: "*"\n    turn_timeout: 0'),
      );
      expect(definition.stepDefaults!.single.turnTimeoutSeconds, 0);
      expectParseFormatError(
        workflowYaml(stepFields: 'prompt: p', tailFields: 'stepDefaults:\n  - match: "*"\n    turn_timeout: -1'),
        messageContains: const ['zero or greater'],
      );
    });

    test('stepDefaults timeout matching an agent names turn_timeout', () {
      final definition = parser.parse(
        workflowYaml(stepFields: 'prompt: p', tailFields: 'stepDefaults:\n  - match: "*"\n    timeout: 60'),
      );

      final errors = WorkflowDefinitionValidator().validate(definition).errors;

      expect(
        errors,
        contains(
          isA<WorkflowValidationError>()
              .having((error) => error.type, 'type', WorkflowValidationErrorType.hybridStepConstraint)
              .having((error) => error.message, 'message', contains('use turn_timeout')),
        ),
      );
    });

    test('throws FormatException when stepDefaults is not a list', () {
      expectParseFormatError(
        workflowYaml(
          tailFields: '''
stepDefaults:
  match: "*"''',
        ),
        messageContains: const ['Field "stepDefaults" must be a list'],
      );
    });

    test('throws FormatException when stepDefaults entry missing match field', () {
      expectParseFormatError(
        workflowYaml(
          tailFields: '''
stepDefaults:
  - model: claude-opus-4''',
        ),
      );
    });
  });

  group('skill field parsing (S04)', () {
    test('parses skill field when present', () {
      final step = parseStep(parser, 'skill: dartclaw-review\nprompt: Also do this.');
      expect(step.skill, 'dartclaw-review');
      expect(step.prompt, 'Also do this.');
    });

    test('skill-only step (no prompt) is valid', () {
      final step = parseStep(parser, 'skill: dartclaw-review');
      expect(step.skill, 'dartclaw-review');
      expect(step.prompt, isNull);
      expect(step.prompts, isNull);
    });

    test('step without skill or prompt throws FormatException', () {
      expectParseFormatError(stepYaml(''));
    });

    test('step without skill requires non-empty prompt', () {
      expectParseFormatError(stepYaml("prompt: ''"));
    });

    test('step without skill field has null skill', () {
      final step = parseStep(parser, 'prompt: p');
      expect(step.skill, isNull);
    });
  });

  group('map step fields', () {
    for (final field in const ['map_over', 'mapOver']) {
      test('parses $field field', () {
        expect(parseStep(parser, 'prompt: p\n$field: items').mapOver, 'items');
      });
    }

    test('mapOver absent -> null (non-map step)', () {
      final step = parseStep(parser, 'prompt: p');
      expect(step.mapOver, isNull);
      expect(step.isMapStep, isFalse);
    });

    for (final testCase in [
      (value: '4', expected: 4, matcher: isA<int>()),
      (value: '"unlimited"', expected: 'unlimited', matcher: isA<String>()),
      (value: '"{{MAX_PARALLEL}}"', expected: '{{MAX_PARALLEL}}', matcher: null),
    ]) {
      test('parses max_parallel as ${testCase.expected}', () {
        final step = parseStep(parser, 'prompt: p\nmap_over: items\nmax_parallel: ${testCase.value}');
        expect(step.maxParallel, testCase.expected);
        final matcher = testCase.matcher;
        if (matcher != null) expect(step.maxParallel, matcher);
      });
    }

    test('max_parallel absent -> null', () {
      final step = parseStep(parser, 'prompt: p\nmap_over: items');
      expect(step.maxParallel, isNull);
    });

    test('max_parallel invalid type throws FormatException', () {
      // Nested-map value is a type error, not the "positive integer" bound error.
      expectParseFormatError(stepYaml('prompt: p\nmap_over: items\nmax_parallel:\n  nested: bad'));
    });

    // Numeric-bound rejections share the "positive integer" message.
    for (final (field, value) in const [('max_parallel', '0'), ('max_parallel', '-2')]) {
      test('$field: $value throws FormatException naming positive integer', () {
        expectParseFormatError(
          stepYaml('prompt: p\nmap_over: items\n$field: $value'),
          messageContains: const ['positive integer'],
        );
      });
    }

    test('isMapStep true when map_over set', () {
      final step = parseStep(parser, 'prompt: p\nmap_over: results');
      expect(step.isMapStep, isTrue);
    });
  });

  group('hybrid step fields (bash, approval, continueSession, onError, workdir)', () {
    test('bash step without prompt or skill parses successfully', () {
      final step = parser.parse(stepYaml('type: bash', stepId: 'run-tests', stepName: 'Run Tests')).steps.single;
      expect(step.id, 'run-tests');
      expect(step.taskType, WorkflowTaskType.bash);
      expect(step.prompts, isNull);
      expect(step.skill, isNull);
    });

    test('approval step without prompt or skill parses successfully', () {
      final step = parseStep(parser, 'type: approval');
      expect(step.taskType, WorkflowTaskType.approval);
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

    for (final testCase in const [
      (
        name: 'legacy continue_session boolean alias',
        yaml: 'prompt: p\ncontinue_session: true',
        field: 'continue',
        expected: '@previous',
      ),
      (name: 'continueSession absent default', yaml: 'prompt: p', field: 'continue', expected: null),
      (
        name: 'onError field',
        yaml: 'type: bash\nonError: continue',
        field: 'onError',
        expected: OnErrorPolicy.continueWorkflow,
      ),
      (
        name: 'on_error snake_case alias with legacy fail',
        yaml: 'type: bash\non_error: fail',
        field: 'onError',
        expected: OnErrorPolicy.pause,
      ),
      (name: 'onError absent default', yaml: 'prompt: p', field: 'onError', expected: null),
      (
        name: 'workdir field',
        yaml: 'type: bash\nworkdir: /tmp/workspace',
        field: 'workdir',
        expected: '/tmp/workspace',
      ),
      (name: 'workdir absent default', yaml: 'prompt: p', field: 'workdir', expected: null),
    ]) {
      test('parses ${testCase.name}', () {
        final step = parseStep(parser, testCase.yaml);
        final actual = switch (testCase.field) {
          'continue' => step.continueSession,
          'onError' => step.onError,
          'workdir' => step.workdir,
          _ => throw StateError('unknown field ${testCase.field}'),
        };
        expect(actual, testCase.expected);
      });
    }

    test('timeoutSeconds alias parses correctly', () {
      expect(parseStep(parser, 'type: bash\nscript: echo ok\ntimeoutSeconds: 45').timeoutSeconds, 45);
    });

    test('timeout_seconds alias parses correctly', () {
      expect(parseStep(parser, 'type: bash\nscript: echo ok\ntimeout_seconds: 45').timeoutSeconds, 45);
    });

    test('hybrid bash step with all new fields', () {
      final yaml = workflowYaml(
        rootFields: '''
variables:
  WORKSPACE:
    required: true''',
        stepFields: r'''
type: bash
workdir: '{{WORKSPACE}}'
onError: continue
maxRetries: 2''',
      );
      final def = parser.parse(yaml);
      final step = def.steps[0];
      expect(step.taskType, WorkflowTaskType.bash);
      expect(step.workdir, '{{WORKSPACE}}');
      expect(step.onError, OnErrorPolicy.continueWorkflow);
      expect(step.maxRetries, 2);
      expect(step.prompts, isNull);
    });

    test('rejects unknown onError value listing valid values (S03)', () {
      expectParseFormatError(stepYaml('type: bash\nonError: retry'), messageContains: const ['pause, continue']);
    });

    test('legacy research/coding step values are rejected with valid type list', () {
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
      expect(
        () => parser.parse(yaml),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            allOf(contains('research'), contains('agent'), contains('bash'), contains('aggregate-reviews')),
          ),
        ),
      );
    });

    test('step without skill or prompt still throws for non-hybrid types', () {
      expectParseFormatError(stepYaml('type: research'));
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
      expect(controller.taskType, WorkflowTaskType.foreach);
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

    test('foreach parses max_parallel', () {
      const yaml = '''
name: n
description: d
steps:
  - id: fe
    name: FE
    type: foreach
    map_over: items
    max_parallel: 2
    steps:
      - id: child
        name: Child
        prompt: Process {{map.item}}
''';
      final def = parser.parse(yaml);
      expect(def.steps[0].maxParallel, 2);
    });

    for (final testCase in const [
      (
        name: 'nested foreach inside foreach',
        stepFields: '''
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
        prompt: Do thing''',
      ),
      (
        name: 'foreach without map_over',
        stepFields: '''
type: foreach
steps:
  - id: child
    name: Child
    prompt: Do thing''',
      ),
      (name: 'foreach with empty steps list', stepFields: 'type: foreach\nmap_over: items\nsteps: []'),
      (name: 'foreach without steps field', stepFields: 'type: foreach\nmap_over: items'),
    ]) {
      test('${testCase.name} throws FormatException', () {
        expectParseFormatError(stepYaml(testCase.stepFields));
      });
    }

    test('nested loop inside foreach parses as a foreach-owned loop (S01)', () {
      final def = parser.parse(
        stepYaml('''
type: foreach
map_over: items
steps:
  - id: review
    name: Review
    prompt: Review {{map.item}}
  - id: remediation
    name: Remediation Loop
    type: loop
    maxIterations: 3
    exitGate: "gating_findings_count == 0"
    steps:
      - id: remediate
        name: Remediate
        prompt: Fix findings
      - id: re-review
        name: Re-review
        prompt: Re-review'''),
      );
      // The inline loop is registered in definition.loops with its body steps.
      final loop = def.loops.singleWhere((l) => l.id == 'remediation');
      expect(loop.steps, ['remediate', 're-review']);
      // A loop controller step appears in the flat steps list.
      final controller = def.steps.singleWhere((s) => s.id == 'remediation');
      expect(controller.taskType, WorkflowTaskType.loop);
      // The foreach controller references the loop controller in foreachSteps.
      final foreach = def.steps.singleWhere((s) => s.taskType == WorkflowTaskType.foreach);
      expect(foreach.foreachSteps, contains('remediation'));
      // The loop body steps are present in the flat steps list.
      expect(def.steps.map((s) => s.id), containsAll(['remediate', 're-review']));
      // Node graph: a foreach node, no standalone loop node for the nested loop.
      expect(def.nodes.whereType<ForeachNode>().length, 1);
      expect(def.nodes.whereType<LoopNode>(), isEmpty);
    });

    test('loop nested in a foreach-nested loop is rejected (S02)', () {
      expectParseFormatError(
        stepYaml('''
type: foreach
map_over: items
steps:
  - id: outer-loop
    name: Outer Loop
    type: loop
    maxIterations: 2
    exitGate: "done == true"
    steps:
      - id: inner-loop
        name: Inner Loop
        type: loop
        maxIterations: 2
        exitGate: "done == true"
        steps:
          - id: leaf
            name: Leaf
            prompt: Do thing'''),
        messageContains: const ['cannot contain nested inline loops'],
      );
    });

    test('foreach nested in foreach reports the foreach-specific message (S02)', () {
      expectParseFormatError(
        stepYaml('''
type: foreach
map_over: items
steps:
  - id: inner
    name: Inner
    type: foreach
    map_over: sub
    steps:
      - id: leaf
        name: Leaf
        prompt: Do thing'''),
        messageContains: const ['cannot contain nested foreach steps'],
      );
    });

    test('parses entryGate on any step', () {
      final def = parser.parse(entryGateWorkflowYaml);
      expect(def.steps[0].entryGate, isNull);
      expect(def.steps[1].entryGate, 'prd_source == synthesized');
    });

    test('parses gitStrategy.artifacts', () {
      final def = parser.parse(gitArtifactsWorkflowYaml);
      final artifacts = def.gitStrategy!.artifacts!;
      expect(artifacts.commit, isTrue);
      expect(artifacts.commitMessage, 'chore(workflow): artifacts for run {{runId}}');
      expect(artifacts.project, '{{DOC_PROJECT}}');
      expect(def.gitStrategy!.worktree!.mode, WorkflowGitWorktreeMode.perMapItem);
    });

    test('both surviving gitStrategy.worktree forms still parse', () {
      const stepsBlock = 'steps:\n  - id: s\n    name: S\n    prompt: p\n';
      for (final worktree in const ['worktree: per-map-item', 'worktree:\n    mode: per-map-item']) {
        final def = parser.parse('name: n\ndescription: d\ngitStrategy:\n  $worktree\n$stepsBlock');
        expect(def.gitStrategy!.worktree!.mode, WorkflowGitWorktreeMode.perMapItem);
        expect(def.gitStrategy!.worktree!.toJsonValue(), 'per-map-item');
      }
    });

    test('rejects unknown worktree mode with field context', () {
      expect(
        () => parser.parse(badWorktreeModeWorkflowYaml, sourcePath: 'bad-worktree.yaml'),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            allOf(
              contains('gitStrategy.worktree.mode'),
              contains('branch-per-step'),
              contains('bad-worktree.yaml'),
              allOf(
                contains('shared'),
                contains('per-task'),
                contains('per-map-item'),
                contains('inline'),
                contains('auto'),
              ),
            ),
          ),
        ),
      );
    });
  });
}
