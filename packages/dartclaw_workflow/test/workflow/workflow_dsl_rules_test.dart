import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_workflow/dartclaw_workflow.dart';
import 'package:dartclaw_workflow/src/workflow/schema_presets.dart';
import 'package:dartclaw_workflow/src/workflow/step_config_resolver.dart';
import 'package:dartclaw_workflow/src/workflow/workflow_dsl_rules.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../fitness_support.dart';
import 'workflow_validator_test_support.dart';

void main() {
  test('rule source enumerates the accepted DSL surface', () {
    expect(WorkflowDslRules.blocks.map((block) => block.name), [
      'workflow',
      'variable',
      'step',
      'inlineForeach',
      'inlineLoop',
      'output',
      'stepDefault',
      'gitStrategy',
      'gitPublish',
      'gitCleanup',
      'gitArtifacts',
      'gitWorktree',
      'mergeResolve',
    ]);
    expect(
      {
        for (final block in WorkflowDslRules.blocks)
          block.name: block.fields.where((field) => field.required).expand((field) => field.names).toList(),
      },
      {
        'workflow': ['name', 'description', 'steps'],
        'variable': <String>[],
        'step': ['id', 'name'],
        'inlineForeach': ['id', 'name', 'type', 'map_over', 'mapOver', 'steps'],
        'inlineLoop': ['id', 'name', 'type', 'maxIterations', 'exitGate', 'steps'],
        'output': <String>[],
        'stepDefault': ['match'],
        'gitStrategy': <String>[],
        'gitPublish': <String>[],
        'gitCleanup': <String>[],
        'gitArtifacts': <String>[],
        'gitWorktree': <String>[],
        'mergeResolve': <String>[],
      },
    );
    expect(WorkflowDslRules.step.field('type').enumValues, unorderedEquals(WorkflowTaskType.values));
    expect(WorkflowDslRules.output.field('format').enumValues, unorderedEquals(OutputFormat.values));
    expect(WorkflowDslRules.loopMaxIterationsPolicies, ['fail', 'continue', 'escalate']);
    expect(WorkflowDslRules.roleAliases, workflowRoleDefaultAliases);
    expect(WorkflowDslRules.stepDefault.field('provider').enumValues, isEmpty);
    expect(WorkflowDslRules.inlineForeach.field('type').enumValues, [WorkflowTaskType.foreach]);
    expect(WorkflowDslRules.inlineForeach.field('onFailure').enumValues, OnFailurePolicy.yamlValues);
    expect(WorkflowDslRules.inlineLoop.field('type').enumValues, [WorkflowTaskType.loop]);
    expect(WorkflowDslRules.inlineLoop.field('onMaxIterations').enumValues, WorkflowDslRules.loopMaxIterationsPolicies);
    expect(WorkflowDslRules.step.field('onError').enumValues, OnErrorPolicy.yamlValues);
    expect(WorkflowDslRules.step.field('onFailure').enumValues, OnFailurePolicy.yamlValues);
    expect(WorkflowDslRules.gitStrategy.field('promotion').enumValues, ['merge', 'rebase', 'none']);
    expect(WorkflowDslRules.mergeResolve.field('escalation').enumValues, MergeResolveEscalation.values);
    expect(WorkflowDslRules.outputShorthandValues, [...OutputFormat.values, ...schemaPresetValues]);
    expect(WorkflowDslRules.aggregateReviewOutputs.map((rule) => (rule.key, rule.format, rule.preset)), [
      ('review_report_path', OutputFormat.path, 'review_report_path'),
      ('findings_count', OutputFormat.json, 'findings_count'),
      ('gating_findings_count', OutputFormat.json, 'gating_findings_count'),
    ]);

    final prompt = WorkflowDslRules.step.field('prompt');
    expect(prompt.requiredForTypes, [WorkflowTaskType.agent]);
    expect(prompt.requiresValueFor(WorkflowTaskType.agent), isTrue);
    expect(prompt.requiresValueFor(WorkflowTaskType.bash), isFalse);
    expect(prompt.alternatives, ['skill']);
    expect(prompt.acceptsKindForType(WorkflowValueKind.stringList, WorkflowTaskType.agent), isTrue);
    expect(prompt.acceptsKindForType(WorkflowValueKind.stringList, WorkflowTaskType.bash), isFalse);
    expect(prompt.mutuallyExclusiveWith, ['script']);
    expect(WorkflowDslRules.step.field('script').applicableTypes, [WorkflowTaskType.bash]);
    expect(
      WorkflowDslRules.step.field('parallel').applicableTypes,
      unorderedEquals([
        WorkflowTaskType.agent,
        WorkflowTaskType.bash,
        WorkflowTaskType.foreach,
        WorkflowTaskType.loop,
        WorkflowTaskType.aggregateReviews,
      ]),
    );
    expect(WorkflowDslRules.step.field('parallel').mutuallyExclusiveWith, ['continueSession', 'continue_session']);
    expect(WorkflowDslRules.step.field('map_over').mutuallyExclusiveWith, ['parallel']);
    expect(
      WorkflowDslRules.step.field('continueSession').applicableTypes,
      unorderedEquals([
        WorkflowTaskType.agent,
        WorkflowTaskType.foreach,
        WorkflowTaskType.loop,
        WorkflowTaskType.aggregateReviews,
      ]),
    );
    expect(
      WorkflowDslRules.step.field('timeout').applicableTypes,
      unorderedEquals([
        WorkflowTaskType.bash,
        WorkflowTaskType.approval,
        WorkflowTaskType.foreach,
        WorkflowTaskType.loop,
        WorkflowTaskType.aggregateReviews,
      ]),
    );
    expect(WorkflowDslRules.step.field('turn_timeout').applicableTypes, [WorkflowTaskType.agent]);
    expect(prompt.kindApplicableTypes.keys, [WorkflowValueKind.stringList]);
    expect(
      prompt.kindApplicableTypes[WorkflowValueKind.stringList],
      unorderedEquals([
        WorkflowTaskType.agent,
        WorkflowTaskType.foreach,
        WorkflowTaskType.loop,
        WorkflowTaskType.aggregateReviews,
      ]),
    );
    expect([
      for (final block in WorkflowDslRules.blocks)
        for (final field in block.fields)
          if (field.applicableTypes.isNotEmpty) '${block.name}.${field.names.first}',
    ], unorderedEquals(['step.script', 'step.timeout', 'step.turn_timeout', 'step.parallel', 'step.continueSession']));
    expect([
      for (final block in WorkflowDslRules.blocks)
        for (final field in block.fields)
          if (field.kindApplicableTypes.isNotEmpty) '${block.name}.${field.names.first}',
    ], unorderedEquals(['step.prompt', 'step.timeout', 'step.turn_timeout', 'step.parallel', 'step.continueSession']));
    for (final name in ['timeout', 'turn_timeout', 'parallel', 'continueSession']) {
      expect(WorkflowDslRules.step.field(name).kindApplicableTypes, {
        WorkflowValueKind.nullValue: WorkflowTaskType.values,
      });
    }
    expect(
      [
        for (final block in WorkflowDslRules.blocks)
          for (final field in block.fields)
            if (field.ignoredValues.isNotEmpty) '${block.name}.${field.names.first}',
      ],
      ['step.parallel', 'step.map_over', 'step.continueSession'],
    );
    for (final name in ['parallel', 'continueSession']) {
      expect(WorkflowDslRules.step.field(name).ignoredValues, [false, null]);
    }
    expect(WorkflowDslRules.step.field('map_over').ignoredValues, [null]);
    expect(prompt.ignoredValues, isEmpty);
    expect(WorkflowDslRules.step.field('script').ignoredValues, isEmpty);
    expect(WorkflowDslRules.warnsInLoopTypes, [WorkflowTaskType.approval]);

    final timeout = WorkflowDslRules.step.field('timeout');
    expect(timeout.kinds, [WorkflowValueKind.integer]);
    expect(timeout.coercedKinds, [WorkflowValueKind.string]);
    expect(timeout.ignoredKinds, [
      WorkflowValueKind.boolean,
      WorkflowValueKind.number,
      WorkflowValueKind.mapping,
      WorkflowValueKind.list,
    ]);
    final foreachSteps = WorkflowDslRules.step.field('foreach_steps');
    expect(foreachSteps.kinds, [WorkflowValueKind.stringList]);
    expect(
      foreachSteps.ignoredKinds,
      unorderedEquals([
        WorkflowValueKind.string,
        WorkflowValueKind.boolean,
        WorkflowValueKind.integer,
        WorkflowValueKind.number,
        WorkflowValueKind.mapping,
      ]),
    );
    final schema = WorkflowDslRules.output.field('schema');
    expect(schema.kinds, [WorkflowValueKind.string]);
    expect(schema.coercedKinds, [WorkflowValueKind.mapping]);
    expect(
      schema.ignoredKinds,
      unorderedEquals([
        WorkflowValueKind.boolean,
        WorkflowValueKind.integer,
        WorkflowValueKind.number,
        WorkflowValueKind.list,
      ]),
    );
    expect(prompt.coercedKinds, [WorkflowValueKind.string]);
    expect(WorkflowDslRules.step.field('turn_timeout').coercedKinds, [WorkflowValueKind.string]);
    expect(WorkflowDslRules.stepDefault.field('turn_timeout').coercedKinds, [WorkflowValueKind.string]);
    expect(
      [
        for (final block in WorkflowDslRules.blocks)
          for (final field in block.fields)
            if (field.coercedKinds.isNotEmpty) '${block.name}.${field.names.first}',
      ],
      unorderedEquals([
        'step.prompt',
        'step.timeout',
        'step.turn_timeout',
        'output.schema',
        'stepDefault.turn_timeout',
      ]),
    );
    expect([
      for (final block in WorkflowDslRules.blocks)
        for (final field in block.fields)
          if (field.ignoredKinds.isNotEmpty) '${block.name}.${field.names.first}',
    ], unorderedEquals(['step.timeout', 'step.foreach_steps', 'output.schema', 'gitStrategy.merge_resolve']));

    expect(
      WorkflowDslRules.gitStrategy.field('merge_resolve').ignoredKinds,
      unorderedEquals([
        WorkflowValueKind.string,
        WorkflowValueKind.boolean,
        WorkflowValueKind.integer,
        WorkflowValueKind.number,
        WorkflowValueKind.list,
      ]),
    );
    for (final block in WorkflowDslRules.blocks) {
      expect(block.fields, isNotEmpty);
      for (final field in block.fields) {
        expect(field.names, isNotEmpty);
        expect(field.acceptedKinds, isNotEmpty);
        expect(
          field.acceptedKinds.contains(WorkflowValueKind.nullValue),
          !field.required,
          reason: '${block.name}.${field.names.first}',
        );
      }
    }
  });

  test('explicit null preserves the historical parser surface for every alias', () {
    const rejected = <String>{
      'workflow.name',
      'workflow.description',
      'workflow.steps',
      'step.id',
      'step.name',
      'step.prompt',
      'step.script',
      'inlineForeach.id',
      'inlineForeach.name',
      'inlineForeach.type',
      'inlineForeach.map_over',
      'inlineForeach.mapOver',
      'inlineForeach.steps',
      'inlineLoop.id',
      'inlineLoop.name',
      'inlineLoop.type',
      'inlineLoop.maxIterations',
      'inlineLoop.exitGate',
      'inlineLoop.steps',
      'output.pathPattern',
      'output.path_pattern',
      'output.preferPatterns',
      'output.prefer_patterns',
      'stepDefault.match',
    };
    final parser = WorkflowDefinitionParser();
    for (final block in WorkflowDslRules.blocks) {
      for (final field in block.fields) {
        for (final name in field.names) {
          final (root, target) = _nullFixture(block.name);
          for (final alias in field.names) {
            target.remove(alias);
          }
          target[name] = null;
          final key = '${block.name}.$name';
          if (rejected.contains(key)) {
            expect(() => parser.parse(jsonEncode(root)), throwsFormatException, reason: key);
          } else {
            expect(() => parser.parse(jsonEncode(root)), returnsNormally, reason: key);
          }
        }
      }
    }
    for (final step in [
      'skill: test\n    prompt: null',
      'type: bash\n    script: null',
      'type: approval\n    parallel: false',
      'type: bash\n    script: echo ok\n    continueSession: false',
      'prompt: run\n    outputs:\n      out:\n        format: path\n        pathPattern: null\n        preferPatterns: null',
    ]) {
      expect(() => parser.parse(_workflowWithStep(step)), returnsNormally, reason: step);
    }
  });

  test('merge-resolve ignored kinds preserve the historical empty configuration', () {
    final parser = WorkflowDefinitionParser();
    for (final value in [null, 'ignored', false, 1, 1.5, <Object>[]]) {
      final (root, _) = _nullFixture('workflow');
      root['gitStrategy'] = {'merge_resolve': value};
      final parsed = parser.parse(jsonEncode(root));
      root['gitStrategy'] = value == null ? <String, Object>{} : {'merge_resolve': <String, Object>{}};
      expect(parsed.toJson(), parser.parse(jsonEncode(root)).toJson(), reason: '$value');
    }
  });

  test('parser key surface is the exact declared surface', () {
    expect(
      {for (final block in WorkflowDslRules.blocks) block.name: block.keys.toSet()},
      {
        'workflow': {
          'name',
          'description',
          'variables',
          'steps',
          'maxTokens',
          'project',
          'stepDefaults',
          'gitStrategy',
        },
        'variable': {'required', 'description', 'default'},
        'step': {
          'id',
          'name',
          'skill',
          'type',
          'prompt',
          'script',
          'provider',
          'model',
          'effort',
          'timeout',
          'timeoutSeconds',
          'timeout_seconds',
          'turn_timeout',
          'parallel',
          'entryGate',
          'inputs',
          'outputs',
          'maxRetries',
          'allowedTools',
          'aggregateReviews',
          'map_over',
          'mapOver',
          'max_parallel',
          'maxParallel',
          'foreach_steps',
          'foreachSteps',
          'continueSession',
          'continue_session',
          'onError',
          'on_error',
          'workdir',
          'onFailure',
          'on_failure',
          'emitsOwnOutcome',
          'emits_own_outcome',
          'auto_frame_context',
          'autoFrameContext',
          'workflow_variables',
          'workflowVariables',
        },
        'inlineForeach': {
          'id',
          'name',
          'type',
          'map_over',
          'mapOver',
          'max_parallel',
          'maxParallel',
          'entryGate',
          'inputs',
          'outputs',
          'steps',
          'onFailure',
          'on_failure',
          'workflow_variables',
          'workflowVariables',
        },
        'inlineLoop': {'id', 'name', 'type', 'maxIterations', 'entryGate', 'exitGate', 'steps', 'onMaxIterations'},
        'output': {
          'format',
          'schema',
          'source',
          'description',
          'pathPattern',
          'path_pattern',
          'preferPatterns',
          'prefer_patterns',
        },
        'stepDefault': {
          'match',
          'provider',
          'model',
          'effort',
          'maxRetries',
          'timeout',
          'timeout_seconds',
          'timeoutSeconds',
          'turn_timeout',
          'allowedTools',
        },
        'gitStrategy': {
          'integrationBranch',
          'integration_branch',
          'bootstrap',
          'worktree',
          'promotion',
          'publish',
          'cleanup',
          'artifacts',
          'merge_resolve',
          'mergeResolve',
        },
        'gitPublish': {'enabled'},
        'gitCleanup': {'enabled'},
        'gitArtifacts': {'commit', 'commitMessage', 'commit_message', 'project'},
        'gitWorktree': {'mode'},
        'mergeResolve': {'enabled', 'max_attempts', 'token_ceiling', 'escalation'},
      },
    );
  });

  test('existing parser and validator sites read field metadata', () {
    final stepRule = _stepRuleWith([
      const WorkflowFieldRule(
        ['prompt'],
        [WorkflowValueKind.stringList],
        coercedKinds: [WorkflowValueKind.string],
        alternatives: ['skill'],
        mutuallyExclusiveWith: ['script'],
      ),
      const WorkflowFieldRule(
        ['script'],
        [WorkflowValueKind.string],
        applicableTypes: [WorkflowTaskType.agent, WorkflowTaskType.bash],
      ),
      const WorkflowFieldRule(['parallel'], [WorkflowValueKind.boolean], applicableTypes: WorkflowTaskType.values),
      const WorkflowFieldRule(['map_over', 'mapOver'], [WorkflowValueKind.string], maxOutputs: 2),
      const WorkflowFieldRule(
        ['continueSession', 'continue_session'],
        [WorkflowValueKind.string, WorkflowValueKind.boolean],
        applicableTypes: WorkflowTaskType.values,
      ),
      const WorkflowFieldRule(
        ['timeout', 'timeoutSeconds', 'timeout_seconds'],
        [WorkflowValueKind.integer],
        coercedKinds: [WorkflowValueKind.string],
        applicableTypes: WorkflowTaskType.values,
      ),
      const WorkflowFieldRule(
        ['turn_timeout'],
        [WorkflowValueKind.integer],
        coercedKinds: [WorkflowValueKind.string],
        applicableTypes: WorkflowTaskType.values,
      ),
    ]);
    final parser = WorkflowDefinitionParser(stepRule: stepRule);
    expect(parser.parse(_workflowWithStep('type: agent\n    script: echo ok')).steps.single.prompt, 'echo ok');
    expect(parser.parse(_workflowWithStep('type: agent')).steps.single.prompts, isNull);
    expect(parser.parse(_workflowWithStep('type: agent\n    timeout: 10')).steps.single.timeoutSeconds, 10);
    expect(
      parser
          .parse(_workflowWithStep('type: bash\n    script: echo ok\n    turn_timeout: 10'))
          .steps
          .single
          .turnTimeoutSeconds,
      10,
    );

    final definition = buildDef(
      steps: const [
        WorkflowStep(id: 'source', name: 'Source', prompts: ['source'], outputs: {'items': OutputConfig()}),
        WorkflowStep(
          id: 'map',
          name: 'Map',
          taskType: WorkflowTaskType.foreach,
          mapOver: 'items',
          foreachSteps: ['child'],
          parallel: true,
          outputs: {'one': OutputConfig(), 'two': OutputConfig()},
        ),
        WorkflowStep(id: 'child', name: 'Child', prompts: ['child']),
        WorkflowStep(
          id: 'bash',
          name: 'Bash',
          taskType: WorkflowTaskType.bash,
          prompts: ['one', 'two'],
          continueSession: 'source',
        ),
        WorkflowStep(
          id: 'approval',
          name: 'Approval',
          taskType: WorkflowTaskType.approval,
          prompts: ['one', 'two'],
          parallel: true,
          continueSession: 'source',
        ),
        WorkflowStep(id: 'promptless', name: 'Promptless'),
      ],
    );
    expect(WorkflowDefinitionValidator(stepRule: stepRule).validate(definition).errors, isEmpty);
  });

  test('one rule-source field edit makes a field parseable, applicable, and persistent', () {
    final stepRule = _stepRuleWith([
      const WorkflowFieldRule(['test_flag'], [WorkflowValueKind.string], applicableTypes: [WorkflowTaskType.bash]),
    ]);
    final parser = WorkflowDefinitionParser(stepRule: stepRule);
    final validator = WorkflowDefinitionValidator(stepRule: stepRule);
    final bash = parser.parse(_workflowWithStep('type: bash\n    script: echo ok\n    test_flag: enabled'));
    expect(bash.steps.single.ruleValues, {'test_flag': 'enabled'});
    expect(validator.validate(bash).errors, isEmpty);
    final restored = WorkflowDefinition.fromJson(bash.toJson());
    expect(restored.steps.single.ruleValues, {'test_flag': 'enabled'});

    final agent = parser.parse(_workflowWithStep('prompt: run\n    test_flag: enabled'));
    expect(
      validator.validate(agent).errors,
      contains(
        isA<WorkflowValidationError>()
            .having((error) => error.stepId, 'stepId', 'step')
            .having((error) => error.message, 'message', contains('test_flag')),
      ),
    );
  });

  test('merge-resolve unknown keys come from its declared block', () {
    final rule = WorkflowBlockRule('mergeResolve', [
      ...WorkflowDslRules.mergeResolve.fields,
      const WorkflowFieldRule(['extension_key'], [WorkflowValueKind.string]),
    ]);
    expect(MergeResolveConfig.fromJson({'extension_key': 'value'}, rule: rule).unknownFields, isEmpty);
    expect(MergeResolveConfig.fromJson({'extension_key': 'value'}).unknownFields, ['extension_key']);
  });

  test('validator rule-call sequence stays unchanged', () {
    final calls = _validatorRuleCalls();
    expect(calls, [
      '_validateRequiredFields',
      '_validateUniqueStepIds',
      '_validateUniqueLoopIds',
      '_validateNormalizedNodes',
      '_validateProviderAliases',
      '_validateVariableReferences',
      '_validateContextKeyConsistency',
      '_validateLoopGateExpressions',
      '_validateLoopReferences',
      '_validateLoopMaxIterations',
      '_validateLoopStepOverlap',
      '_validateLoopMaxIterationsPolicy',
      '_validateStepTimeoutFields',
      '_validateStepDefaults',
      '_validateGitStrategy',
      '_validateStepDefaultsOrdering',
      '_validateStepEntryGates',
      '_validateOutputConfigs',
      '_warnCodexAllowedToolsPolicy',
      '_validateMapOverReferences',
      '_validateMapStepConstraints',
      '_validateAggregateReviewsConstraints',
      '_validateAggregateReviewsPlacement',
      '_validateReviewSourcePrefixing',
      '_validateMultiPromptProviders',
      '_validateHybridStepRules',
    ]);
  });

  test('workflow documentation matches the declared DSL surface', () {
    final root = resolveRepoRoot();
    final architecture = File(p.join(root, 'dev', 'architecture', 'workflow-architecture.md')).readAsStringSync();
    final conventions = File(p.join(root, 'packages', 'dartclaw_workflow', 'CLAUDE.md')).readAsStringSync();
    final reference = File(p.join(root, 'docs', 'guide', 'workflows-reference.md')).readAsStringSync();
    expect(architecture, contains('workflow_dsl_rules.dart'));
    final parserResponsibilities = _markdownSection(
      architecture,
      'The parser does not do semantic checks such as:',
      'The separation matters operationally:',
    );
    expect(parserResponsibilities.split('\n').where((line) => line.startsWith('- ')), [
      '- whether `mapOver` references a prior context key',
      '- whether `continueSession` targets a valid step',
      '- whether a gate expression is well formed',
    ]);
    expect(
      parserResponsibilities,
      contains('Skill existence is checked by\n`workflow_skill_preflight.dart` during execution preflight.'),
    );
    final semantics = _markdownSection(architecture, '## 19. Validation Semantics', '## 20. Step Defaults');
    final documentedStages = RegExp(
      r'^\| `(_validate[A-Za-z0-9]+|_warnCodexAllowedToolsPolicy)` \|',
      multiLine: true,
    ).allMatches(semantics).map((match) => match.group(1)).toList();
    expect(documentedStages, _validatorRuleCalls());
    expect(semantics, contains('Skill names resolve in `workflow_skill_preflight.dart` at execution preflight'));
    final hybridTable = _markdownSection(semantics, 'The hybrid-step rules', 'The warning/error boundary');
    final hybridRows = hybridTable
        .split('\n')
        .where((line) => line.startsWith('| '))
        .skip(1)
        .map((line) => (line.split('|')[1].trim(), line.split('|')[2].trim()))
        .toList();
    expect(hybridRows, [
      ('approval step inside a loop', 'warning'),
      ('step type forbids parallel execution', 'error'),
      ('step type forbids a prompt list', 'error'),
      ('parallel combined with continueSession', 'error'),
      ('continueSession uses an unsupported concrete provider', 'error'),
      ('continueSession has no resolvable target', 'error'),
      ('continueSession references an unknown target', 'error'),
      ('continuing step type forbids continueSession', 'error'),
      ('continueSession target does not precede the step', 'error'),
      ('continueSession target is bash or approval', 'error'),
      ('continueSession providers differ', 'error'),
      ('continueSession crosses a loop boundary', 'error'),
      ('continueSession chain forms a cycle', 'error'),
    ]);
    final boundaries = _markdownSection(conventions, '## Boundaries', '## Conventions');
    expect(boundaries, contains('The authored DSL is exactly `WorkflowDslRules`'));
    expect(boundaries, contains('Generic rule-backed step values round-trip through `WorkflowStep.ruleValues`'));
    expect(boundaries, isNot(contains('New authoring fields land in two places')));
    expect(RegExp(r'_stepKeys|_outputConfigKeys|_stepDefaultKeys').allMatches(boundaries), isEmpty);
    expect(conventions, contains('Declarative DSL facts belong'));
    expect(conventions, contains('single declaration of accepted blocks'));

    final stepSection = _markdownSection(reference, '### Step Fields', '### Conditional Expressions');
    final declaredStepFields = {
      ...WorkflowDslRules.step.keys,
      ...WorkflowDslRules.inlineForeach.keys,
      ...WorkflowDslRules.inlineLoop.keys,
    };
    expect(_documentedFieldNames(stepSection), unorderedEquals(declaredStepFields));

    final outputSection = _markdownSection(
      reference,
      '### \u0060outputs\u0060 Fields',
      '### \u0060stepDefaults\u0060 Fields',
    );
    expect(_documentedFieldNames(outputSection), unorderedEquals(WorkflowDslRules.output.keys));
  });

  test('diagnostic sequence stays byte-identical', () {
    final fixtures = <(String, WorkflowDefinition)>[
      (
        'required-prompt',
        const WorkflowDefinition(
          name: 'required-prompt',
          description: 'required prompt',
          steps: [WorkflowStep(id: 'agent', name: 'Agent')],
        ),
      ),
      (
        'provider-aliases',
        buildDef(
          steps: const [
            WorkflowStep(id: 'step', name: 'Step', prompts: ['run'], provider: '@executer'),
          ],
          stepDefaults: const [StepConfigDefault(match: '*', provider: '@executer')],
        ),
      ),
      (
        'map-shape',
        buildDef(
          steps: const [
            WorkflowStep(id: 'source', name: 'Source', prompts: ['source'], outputs: {'items': OutputConfig()}),
            WorkflowStep(
              id: 'map',
              name: 'Map',
              taskType: WorkflowTaskType.foreach,
              mapOver: 'items',
              foreachSteps: ['child'],
              parallel: true,
              outputs: {'a': OutputConfig(), 'b': OutputConfig()},
            ),
            WorkflowStep(id: 'child', name: 'Child', prompts: ['child']),
          ],
        ),
      ),
      (
        'map-missing-children',
        buildDef(
          steps: const [
            WorkflowStep(id: 'source', name: 'Source', prompts: ['source'], outputs: {'items': OutputConfig()}),
            WorkflowStep(
              id: 'map',
              name: 'Map',
              prompts: ['map'],
              mapOver: 'items',
              outputs: {'items': OutputConfig()},
            ),
          ],
        ),
      ),
      (
        'aggregate-required-shape',
        buildDef(
          steps: const [
            WorkflowStep(
              id: 'aggregate',
              name: 'Aggregate',
              taskType: WorkflowTaskType.aggregateReviews,
              aggregateReviews: [],
              outputs: {'wrong': OutputConfig()},
            ),
          ],
        ),
      ),
      (
        'aggregate-output-formats-and-presets',
        buildDef(
          steps: [
            reviewSourceStep(id: 'review-a'),
            aggregateReviewsStep(
              outputs: const {
                'review_report_path': OutputConfig(format: OutputFormat.path, schema: 'narrative_text'),
                'findings_count': OutputConfig(format: OutputFormat.json, schema: 'gating_findings_count'),
                'gating_findings_count': OutputConfig(format: OutputFormat.json, schema: 'findings_count'),
              },
            ),
          ],
        ),
      ),
      (
        'hybrid-step-applicability',
        WorkflowDefinition(
          name: 'hybrid',
          description: 'hybrid',
          steps: const [
            WorkflowStep(id: 'prior', name: 'Prior', prompts: ['prior']),
            WorkflowStep(
              id: 'bash',
              name: 'Bash',
              taskType: WorkflowTaskType.bash,
              prompts: ['one', 'two'],
              continueSession: 'prior',
            ),
            WorkflowStep(
              id: 'approval',
              name: 'Approval',
              taskType: WorkflowTaskType.approval,
              prompts: ['one', 'two'],
              parallel: true,
              continueSession: 'prior',
            ),
          ],
          loops: const [
            WorkflowLoop(
              id: 'approval-loop',
              steps: ['approval'],
              maxIterations: 1,
              exitGate: 'approval.status == done',
            ),
          ],
        ),
      ),
      (
        'unknown-loop-policy',
        buildDef(
          loops: const [
            WorkflowLoop(
              id: 'unknown',
              steps: ['s1'],
              maxIterations: 2,
              exitGate: 's1.status == done',
              onMaxIterations: 'sometimes',
            ),
          ],
        ),
      ),
      ('nested-loop-policy', _nestedLoopPolicyDefinition(WorkflowLoop.onMaxIterationsContinue)),
      (
        'top-level-loop-policy',
        buildDef(
          loops: const [
            WorkflowLoop(
              id: 'top-level',
              steps: ['s1'],
              maxIterations: 2,
              exitGate: 's1.status == done',
              onMaxIterations: WorkflowLoop.onMaxIterationsEscalate,
            ),
          ],
        ),
      ),
    ];
    final rendered = fixtures
        .map((fixture) => _renderFixture(fixture.$1, WorkflowDefinitionValidator().validate(fixture.$2)))
        .join('\n');
    expect(rendered, equals(_golden('workflow_diagnostics.txt').readAsStringSync().trimRight()));
  });

  test('parser rejection layer and messages stay byte-identical', () {
    final diagnostics = [
      _parseDiagnostic(_workflowWithStep('prompt: run\n    unknown_field: true')),
      _parseDiagnostic(_workflowWithStep('type: nonesuch\n    prompt: run')),
      _parseDiagnostic(_workflowWithStep('type: custom\n    prompt: run')),
      _parseDiagnostic(_workflowWithStep('type: agent\n    script: echo no')),
      _parseDiagnostic(_workflowWithStep('type: bash\n    prompt: echo one\n    script: echo two')),
      _parseDiagnostic(_workflowWithStep('type: agent')),
      _parseDiagnostic(_workflowWithStep('type: agent\n    prompt: run\n    timeout: 10')),
      _parseDiagnostic(_workflowWithStep('type: bash\n    script: echo ok\n    turn_timeout: 10')),
    ];
    expect(diagnostics.join('\n'), equals(_golden('workflow_parser_diagnostics.txt').readAsStringSync().trimRight()));
  });

  test('shipped and maintainer workflows preserve reports including warnings', () {
    final root = resolveRepoRoot();
    final paths = <(String, String)>[
      for (final name in ['plan-and-implement', 'spec-and-implement', 'code-review'])
        (
          'built-in/$name',
          p.join(root, 'packages', 'dartclaw_workflow', 'lib', 'src', 'workflow', 'definitions', '$name.yaml'),
        ),
      for (final name in ['plan-and-implement', 'spec-and-implement', 'review-and-remediate', 'multi-agent-review'])
        ('maintainer/$name-inline', p.join(root, '.dartclaw', 'workflows', 'custom', '$name-inline.yaml')),
    ];
    final rendered = <String>[];
    for (final (name, path) in paths) {
      final definition = WorkflowDefinitionParser().parse(File(path).readAsStringSync(), sourcePath: path);
      rendered.add(_renderFixture(name, WorkflowDefinitionValidator().validate(definition)));
    }
    expect(rendered.join('\n'), equals(_golden('workflow_definition_reports.txt').readAsStringSync().trimRight()));
  });

  test('accepted coercions and ignored kinds stay unchanged', () {
    final duration = WorkflowDefinitionParser().parse(
      _workflowWithStep('type: bash\n    script: echo ok\n    timeoutSeconds: 90s'),
    );
    expect(duration.steps.single.timeoutSeconds, 90);

    final ignoredTimeout = WorkflowDefinitionParser().parse(
      _workflowWithStep('type: bash\n    script: echo ok\n    timeout: true'),
    );
    expect(ignoredTimeout.steps.single.timeoutSeconds, isNull);

    final ignoredForeachSteps = WorkflowDefinitionParser().parse(
      _workflowWithStep('prompt: run\n    map_over: items\n    foreach_steps: child'),
    );
    expect(ignoredForeachSteps.steps.single.foreachSteps, isNull);

    final ignoredSchemas = WorkflowDefinitionParser().parse(
      _workflowWithStep(
        'prompt: run\n'
        '    outputs:\n'
        '      scalar_schema:\n'
        '        schema: 42\n'
        '      list_schema:\n'
        '        schema: [one, two]',
      ),
    );
    expect(ignoredSchemas.steps.single.outputs!['scalar_schema']!.schema, isNull);
    expect(ignoredSchemas.steps.single.outputs!['list_schema']!.schema, isNull);

    final providers = WorkflowDefinitionParser().parse(
      '${_workflowWithStep('prompt: run\n    provider: local-provider')}'
      '\nstepDefaults:\n  - match: "*"\n    provider: other-provider\n',
    );
    expect(providers.steps.single.provider, 'local-provider');
    expect(providers.stepDefaults!.single.provider, 'other-provider');
    expect(WorkflowDefinitionValidator().validate(providers).errors, isEmpty);

    final controllers = WorkflowDefinitionParser().parse(_inlineControllerWorkflow());
    expect(controllers.steps.firstWhere((step) => step.id == 'foreach').taskType, WorkflowTaskType.foreach);
    expect(controllers.loops.single.id, 'nested-loop');
  });
}

String _renderDiagnostic(WorkflowValidationError error) =>
    '${error.type.name}|${error.stepId ?? ''}|${error.loopId ?? ''}|${error.message}';

String _renderFixture(String name, ValidationReport report) {
  final diagnostics = [...report.errors, ...report.warnings].map(_renderDiagnostic).toList();
  return ['[$name]', if (diagnostics.isEmpty) '<clean>' else ...diagnostics].join('\n');
}

File _golden(String name) =>
    File(p.join(resolveRepoRoot(), 'packages', 'dartclaw_workflow', 'test', 'workflow', 'goldens', name));

String _parseDiagnostic(String yaml) {
  try {
    WorkflowDefinitionParser().parse(yaml);
  } on FormatException catch (error) {
    return error.message;
  }
  return '<accepted>';
}

String _workflowWithStep(String fields) =>
    '''
name: test
description: test
steps:
  - id: step
    name: Step
    $fields
''';

WorkflowDefinition _nestedLoopPolicyDefinition(String policy) =>
    WorkflowDefinitionParser().parse(_inlineControllerWorkflow(onMaxIterations: policy));

String _inlineControllerWorkflow({String onMaxIterations = WorkflowLoop.onMaxIterationsFail}) =>
    '''
name: inline controllers
description: inline controller discriminators
steps:
  - id: source
    name: Source
    prompt: source
    outputs:
      items: lines
  - id: foreach
    name: Foreach
    type: foreach
    map_over: items
    outputs:
      results: json
    steps:
      - id: nested-loop
        name: Nested loop
        type: loop
        maxIterations: 2
        onMaxIterations: $onMaxIterations
        exitGate: child.status == done
        steps:
          - id: child
            name: Child
            prompt: child
''';

WorkflowBlockRule _stepRuleWith(List<WorkflowFieldRule> replacements) {
  final remaining = replacements.toList();
  final fields = <WorkflowFieldRule>[];
  for (final field in WorkflowDslRules.step.fields) {
    final index = remaining.indexWhere((replacement) => replacement.names.any(field.names.contains));
    fields.add(index < 0 ? field : remaining.removeAt(index));
  }
  return WorkflowBlockRule('step', [...fields, ...remaining]);
}

String _markdownSection(String source, String start, String end) {
  final startIndex = source.indexOf(start);
  final endIndex = source.indexOf(end, startIndex + start.length);
  expect(startIndex, isNonNegative, reason: 'missing $start');
  expect(endIndex, greaterThan(startIndex), reason: 'missing $end');
  return source.substring(startIndex, endIndex);
}

Set<String> _documentedFieldNames(String section) => {
  for (final line in section.split('\n'))
    if (line.startsWith('| \u0060'))
      for (final match in RegExp(r'\u0060([^\u0060]+)\u0060').allMatches(line.split('|')[1])) match.group(1)!,
};

List<String?> _validatorRuleCalls() {
  final source = File(
    p.join(
      resolveRepoRoot(),
      'packages',
      'dartclaw_workflow',
      'lib',
      'src',
      'workflow',
      'workflow_definition_validator.dart',
    ),
  ).readAsStringSync();
  final calls = RegExp(
    r'^\s{4,}(_validate[A-Za-z0-9]+|_warnCodexAllowedToolsPolicy)\(',
    multiLine: true,
  ).allMatches(source).map((match) => match.group(1)).toList();
  return calls;
}

(Map<String, Object?>, Map<String, Object?>) _nullFixture(String block) {
  final step = <String, Object?>{'id': 's', 'name': 'S', 'prompt': 'p'};
  final root = <String, Object?>{
    'name': 'probe',
    'description': 'probe',
    'steps': [step],
  };
  if (block == 'workflow') return (root, root);
  if (block == 'step') return (root, step);
  if (block == 'inlineForeach' || block == 'inlineLoop') {
    final container = <String, Object?>{
      'id': 'container',
      'name': 'Container',
      'type': block == 'inlineForeach' ? 'foreach' : 'loop',
      'steps': [step],
    };
    if (block == 'inlineForeach') {
      container['map_over'] = 'items';
    } else {
      container['maxIterations'] = 2;
      container['exitGate'] = 's.status == done';
    }
    root['steps'] = [container];
    return (root, container);
  }
  if (block == 'variable') {
    final target = <String, Object?>{'required': false, 'description': 'd', 'default': 'value'};
    root['variables'] = {'VALUE': target};
    return (root, target);
  }
  if (block == 'output') {
    final target = <String, Object?>{'format': 'json'};
    step['outputs'] = {'out': target};
    return (root, target);
  }
  if (block == 'stepDefault') {
    final target = <String, Object?>{'match': '*'};
    root['stepDefaults'] = [target];
    return (root, target);
  }
  final git = <String, Object?>{};
  root['gitStrategy'] = git;
  if (block == 'gitStrategy') return (root, git);
  final target = <String, Object?>{};
  final key = switch (block) {
    'gitPublish' => 'publish',
    'gitCleanup' => 'cleanup',
    'gitArtifacts' => 'artifacts',
    'gitWorktree' => 'worktree',
    'mergeResolve' => 'merge_resolve',
    _ => throw StateError(block),
  };
  git[key] = target;
  return (root, target);
}
