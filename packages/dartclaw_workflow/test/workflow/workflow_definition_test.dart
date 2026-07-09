import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show
        ActionNode,
        ForeachNode,
        LoopNode,
        MapNode,
        MergeResolveConfig,
        MergeResolveEscalation,
        OnErrorPolicy,
        OutputConfig,
        OutputFormat,
        ParallelGroupNode,
        StepConfigDefault,
        WorkflowDefinition,
        WorkflowExternalArtifactMountMode,
        WorkflowGitExternalArtifactMount,
        WorkflowGitStrategy,
        WorkflowGitWorktreeMode,
        WorkflowGitWorktreeStrategy,
        WorkflowLoop,
        WorkflowNode,
        WorkflowStep,
        WorkflowTaskType,
        WorkflowVariable;
import 'package:test/test.dart';

const _basicStep = WorkflowStep(id: 's', name: 'S', prompts: ['p']);

void main() {
  group('WorkflowVariable', () {
    for (final testCase in const [
      (
        name: 'with default value',
        variable: WorkflowVariable(required: true, description: 'A variable', defaultValue: 'default'),
        required: true,
        description: 'A variable',
        defaultValue: 'default',
      ),
      (
        name: 'with no default value',
        variable: WorkflowVariable(required: false, description: 'optional var'),
        required: false,
        description: 'optional var',
        defaultValue: null,
      ),
    ]) {
      test('round-trips ${testCase.name}', () {
        final restored = WorkflowVariable.fromJson(testCase.variable.toJson());
        expect(restored.required, testCase.required);
        expect(restored.description, testCase.description);
        expect(restored.defaultValue, testCase.defaultValue);
      });
    }

    test('defaults apply when fields missing in json', () {
      final restored = WorkflowVariable.fromJson({});
      expect(restored.required, true);
      expect(restored.description, '');
      expect(restored.defaultValue, isNull);
    });
  });

  group('WorkflowLoop', () {
    test('round-trips via toJson/fromJson', () {
      const loop = WorkflowLoop(
        id: 'loop-1',
        steps: ['step-a', 'step-b'],
        maxIterations: 5,
        entryGate: 'step-a.findings_count > 0',
        exitGate: 'step-a.status == done',
      );
      final restored = WorkflowLoop.fromJson(loop.toJson());
      expect(restored.id, 'loop-1');
      expect(restored.steps, ['step-a', 'step-b']);
      expect(restored.maxIterations, 5);
      expect(restored.entryGate, 'step-a.findings_count > 0');
      expect(restored.exitGate, 'step-a.status == done');
      expect(restored.finally_, isNull);
    });

    test('round-trips with finally_ field', () {
      const loop = WorkflowLoop(
        id: 'loop-1',
        steps: ['loop-step'],
        maxIterations: 3,
        exitGate: 'loop-step.done == true',
        finally_: 'summarize',
      );
      final json = loop.toJson();
      expect(json['finally'], 'summarize');
      expect(json.containsKey('finally_'), false);
      final restored = WorkflowLoop.fromJson(json);
      expect(restored.finally_, 'summarize');
    });

    test('finally_ absent from json when null', () {
      const loop = WorkflowLoop(id: 'l', steps: ['s'], maxIterations: 1, exitGate: 'e');
      final json = loop.toJson();
      expect(json.containsKey('finally'), false);
    });

    test('onMaxIterations defaults to fail; toJson omits the default', () {
      const loop = WorkflowLoop(id: 'l', steps: ['s'], maxIterations: 1, exitGate: 'e');
      expect(loop.onMaxIterations, 'fail');
      final json = loop.toJson();
      expect(json.containsKey('onMaxIterations'), false);
      final restored = WorkflowLoop.fromJson(json);
      expect(restored.onMaxIterations, 'fail');
    });

    test('onMaxIterations: continue round-trips and is emitted in json', () {
      const loop = WorkflowLoop(id: 'l', steps: ['s'], maxIterations: 2, exitGate: 'e', onMaxIterations: 'continue');
      final json = loop.toJson();
      expect(json['onMaxIterations'], 'continue');
      final restored = WorkflowLoop.fromJson(json);
      expect(restored.onMaxIterations, 'continue');
    });

    test('onMaxIterations: escalate round-trips and is emitted in json', () {
      const loop = WorkflowLoop(
        id: 'l',
        steps: ['s'],
        maxIterations: 2,
        exitGate: 'e',
        onMaxIterations: WorkflowLoop.onMaxIterationsEscalate,
      );
      final json = loop.toJson();
      expect(json['onMaxIterations'], WorkflowLoop.onMaxIterationsEscalate);
      final restored = WorkflowLoop.fromJson(json);
      expect(restored.onMaxIterations, WorkflowLoop.onMaxIterationsEscalate);
    });

    test('fromJson of a missing onMaxIterations key defaults to fail', () {
      final restored = WorkflowLoop.fromJson({
        'id': 'l',
        'steps': ['s'],
        'maxIterations': 1,
        'exitGate': 'e',
      });
      expect(restored.onMaxIterations, 'fail');
    });
  });

  group('WorkflowGitStrategy', () {
    test('round-trips with gitStrategy (S16b)', () {
      const def = WorkflowDefinition(
        name: 'wf',
        description: 'desc',
        steps: [_basicStep],
        gitStrategy: WorkflowGitStrategy(
          integrationBranch: true,
          worktree: WorkflowGitWorktreeStrategy(mode: WorkflowGitWorktreeMode.shared),
          promotion: 'merge',
          publish: true,
        ),
      );
      final json = def.toJson();
      expect(json.containsKey('gitStrategy'), true);
      final restored = WorkflowDefinition.fromJson(json);
      expect(restored.gitStrategy, isNotNull);
      expect(restored.gitStrategy!.integrationBranch, isTrue);
      expect(restored.gitStrategy!.worktreeMode, 'shared');
      expect(restored.gitStrategy!.promotion, 'merge');
      expect(restored.gitStrategy!.publish, isTrue);
    });

    test('invalid gitStrategy worktree mode fails during model hydration', () {
      expect(() => WorkflowGitWorktreeStrategy.fromJson('invalid-worktree'), throwsFormatException);
    });

    test('cleanup.enabled round-trips through toJson/fromJson', () {
      const def = WorkflowDefinition(
        name: 'wf',
        description: 'd',
        steps: [_basicStep],
        gitStrategy: WorkflowGitStrategy(cleanup: false),
      );
      final restored = WorkflowDefinition.fromJson(def.toJson());
      expect(restored.gitStrategy?.cleanup, isFalse);
      expect(restored.gitStrategy?.cleanupEnabled, isFalse);
    });

    test('effectiveWorktreeMode resolves auto and explicit modes', () {
      const autoStrategy = WorkflowGitStrategy(
        worktree: WorkflowGitWorktreeStrategy(mode: WorkflowGitWorktreeMode.auto),
      );
      const sharedStrategy = WorkflowGitStrategy(
        worktree: WorkflowGitWorktreeStrategy(mode: WorkflowGitWorktreeMode.shared),
      );
      const perMapItemStrategy = WorkflowGitStrategy(
        worktree: WorkflowGitWorktreeStrategy(mode: WorkflowGitWorktreeMode.perMapItem),
      );

      expect(autoStrategy.effectiveWorktreeMode(maxParallel: 3, isMap: true), 'per-map-item');
      expect(autoStrategy.effectiveWorktreeMode(maxParallel: 1, isMap: true), 'inline');
      expect(autoStrategy.effectiveWorktreeMode(maxParallel: null, isMap: true), 'per-map-item');
      expect(autoStrategy.effectiveWorktreeMode(maxParallel: null, isMap: false), 'inline');
      expect(
        const WorkflowGitStrategy(
          integrationBranch: true,
          worktree: WorkflowGitWorktreeStrategy(mode: WorkflowGitWorktreeMode.auto),
        ).effectiveWorktreeMode(maxParallel: null, isMap: false),
        'shared',
        reason: 'integration-branch workflow-level steps should not switch the operator checkout',
      );
      expect(
        const WorkflowGitStrategy().effectiveWorktreeMode(maxParallel: 2, isMap: true),
        'per-map-item',
        reason: 'omitted worktree config should behave like auto',
      );
      expect(sharedStrategy.effectiveWorktreeMode(maxParallel: 3, isMap: true), 'shared');
      expect(perMapItemStrategy.effectiveWorktreeMode(maxParallel: 1, isMap: true), 'per-map-item');
    });

    test('integrationBranch spellings must agree in json', () {
      expect(
        () => WorkflowGitStrategy.fromJson({'integrationBranch': true, 'integration_branch': false}),
        throwsA(
          isA<ArgumentError>()
              .having(
                (e) => e.message,
                'message',
                allOf(contains('gitStrategy.integrationBranch'), contains('gitStrategy.integration_branch')),
              )
              .having((e) => e.message, 'message', isNot(contains('gitStrategy.bootstrap'))),
        ),
      );
    });

    test('legacy bootstrap key hydrates as an integrationBranch input alias', () {
      final strategy = WorkflowGitStrategy.fromJson({'bootstrap': true});

      expect(strategy.integrationBranch, isTrue);
      expect(strategy.toJson(), equals({'integrationBranch': true}));
    });

    test('legacy bootstrap key must agree with integrationBranch in json', () {
      expect(
        () => WorkflowGitStrategy.fromJson({'integrationBranch': true, 'bootstrap': false}),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            allOf(contains('gitStrategy.integrationBranch'), contains('gitStrategy.bootstrap')),
          ),
        ),
      );
    });

    test('agreeing integrationBranch spellings hydrate as one value', () {
      final strategy = WorkflowGitStrategy.fromJson({'integrationBranch': true, 'integration_branch': true});

      expect(strategy.integrationBranch, isTrue);
    });
  });

  group('WorkflowNode', () {
    for (final testCase in const [
      (name: 'action', node: ActionNode(stepId: 'step-1'), matcher: TypeMatcher<ActionNode>(), key: 'step-1'),
      (name: 'map', node: MapNode(stepId: 'story-spec'), matcher: TypeMatcher<MapNode>(), key: 'story-spec'),
      (
        name: 'parallel group',
        node: ParallelGroupNode(stepIds: ['review-a', 'review-b']),
        matcher: TypeMatcher<ParallelGroupNode>(),
        key: ['review-a', 'review-b'],
      ),
      (
        name: 'loop',
        node: LoopNode(loopId: 'remediation-loop', stepIds: ['remediate', 're-review'], finallyStepId: 'summarize'),
        matcher: TypeMatcher<LoopNode>(),
        key: 'remediation-loop',
      ),
    ]) {
      test('${testCase.name} node round-trips via toJson/fromJson', () {
        final restored = WorkflowNode.fromJson(testCase.node.toJson());
        expect(restored, testCase.matcher);
        switch (restored) {
          case ActionNode():
            expect(restored.stepId, testCase.key);
          case MapNode():
            expect(restored.stepId, testCase.key);
          case ParallelGroupNode():
            expect(restored.stepIds, testCase.key);
          case LoopNode():
            expect(restored.loopId, testCase.key);
            expect(restored.stepIds, ['remediate', 're-review']);
            expect(restored.finallyStepId, 'summarize');
          case ForeachNode():
            fail('foreach is covered by its dedicated child-step assertions');
        }
      });
    }

    test('foreach node round-trips via toJson/fromJson (S19)', () {
      const node = ForeachNode(stepId: 'story-pipeline', childStepIds: ['implement', 'quick-review']);
      final json = node.toJson();
      expect(json['type'], 'foreach');
      expect(json['stepId'], 'story-pipeline');
      expect(json['childStepIds'], ['implement', 'quick-review']);

      final restored = WorkflowNode.fromJson(json);
      expect(restored, isA<ForeachNode>());
      final foreach = restored as ForeachNode;
      expect(foreach.stepId, 'story-pipeline');
      expect(foreach.childStepIds, ['implement', 'quick-review']);
      expect(foreach.stepIds, ['story-pipeline', 'implement', 'quick-review']);
    });
  });

  group('StepConfigDefault (S03)', () {
    test('round-trips with all fields', () {
      const d = StepConfigDefault(
        match: 'review*',
        provider: 'claude',
        model: 'claude-opus-4',
        maxTokens: 8000,
        maxRetries: 2,
        timeoutSeconds: 900,
        allowedTools: ['Read', 'Grep'],
      );
      final json = d.toJson();
      final restored = StepConfigDefault.fromJson(json);
      expect(restored.match, 'review*');
      expect(restored.provider, 'claude');
      expect(restored.model, 'claude-opus-4');
      expect(restored.maxTokens, 8000);
      expect(restored.maxRetries, 2);
      expect(restored.timeoutSeconds, 900);
      expect(restored.allowedTools, ['Read', 'Grep']);
    });

    test('round-trips with only match (all optionals null)', () {
      const d = StepConfigDefault(match: '*');
      final restored = StepConfigDefault.fromJson(d.toJson());
      expect(restored.match, '*');
      expect(restored.provider, isNull);
      expect(restored.model, isNull);
      expect(restored.maxTokens, isNull);
      expect(restored.maxRetries, isNull);
      expect(restored.timeoutSeconds, isNull);
      expect(restored.allowedTools, isNull);
    });

    test('null fields omitted from json', () {
      const d = StepConfigDefault(match: 'impl*');
      final json = d.toJson();
      expect(json.containsKey('provider'), false);
      expect(json.containsKey('model'), false);
      expect(json.containsKey('maxTokens'), false);
      expect(json.containsKey('maxRetries'), false);
      expect(json.containsKey('timeoutSeconds'), false);
      expect(json.containsKey('allowedTools'), false);
    });
  });

  group('WorkflowStep', () {
    test('round-trips with all fields', () {
      const step = WorkflowStep(
        id: 'step-1',
        name: 'My Step',
        prompts: ['Do {{VAR}} and {{context.key}}'],
        taskType: WorkflowTaskType.bash,
        provider: 'claude',
        model: 'claude-opus',
        timeoutSeconds: 1800,
        parallel: true,
        gate: 'prev.status == done',
        inputs: ['in_key'],
        outputs: {'out_key': OutputConfig()},
        maxTokens: 10000,
        maxRetries: 3,
        allowedTools: ['Bash', 'Read'],
        aggregateReviews: ['review-a', 'review-b'],
        workflowVariables: ['REQUIREMENTS'],
        entryGate: 'prd_source == synthesized',
      );
      final json = step.toJson();
      final restored = WorkflowStep.fromJson(json);

      expect(restored.id, 'step-1');
      expect(restored.name, 'My Step');
      expect(restored.prompt, 'Do {{VAR}} and {{context.key}}');
      expect(restored.taskType, WorkflowTaskType.bash);
      expect(restored.provider, 'claude');
      expect(restored.model, 'claude-opus');
      expect(restored.timeoutSeconds, 1800);
      expect(restored.parallel, true);
      expect(restored.gate, 'prev.status == done');
      expect(restored.inputs, ['in_key']);
      expect(restored.outputKeys, contains('out_key'));
      expect(restored.maxTokens, 10000);
      expect(restored.maxRetries, 3);
      expect(restored.allowedTools, ['Bash', 'Read']);
      expect(restored.aggregateReviews, ['review-a', 'review-b']);
      expect(restored.workflowVariables, ['REQUIREMENTS']);
      expect(restored.entryGate, 'prd_source == synthesized');
    });

    test('round-trips with only required fields (defaults applied)', () {
      const step = WorkflowStep(id: 'step-1', name: 'Step One', prompts: ['Just do it']);
      final restored = WorkflowStep.fromJson(step.toJson());
      expect(restored.taskType, WorkflowTaskType.agent);
      expect(restored.parallel, false);
      expect(restored.inputs, isEmpty);
      expect(restored.outputKeys, isEmpty);
      expect(restored.maxTokens, isNull);
      expect(restored.allowedTools, isNull);
    });

    test('implicit default type is omitted from json', () {
      const step = WorkflowStep(id: 'step-1', name: 'Step One', prompts: ['Just do it']);
      final json = step.toJson();
      expect(json.containsKey('type'), isFalse);
    });

    test('timeout stored as seconds integer', () {
      const step = WorkflowStep(id: 's', name: 'S', prompts: ['p'], timeoutSeconds: 1800);
      final json = step.toJson();
      expect(json['timeout'], 1800);
      final restored = WorkflowStep.fromJson(json);
      expect(restored.timeoutSeconds, 1800);
    });

    test('skill field round-trips (S04)', () {
      const step = WorkflowStep(id: 's', name: 'S', skill: 'dartclaw-review-code', prompts: ['Do the review']);
      final json = step.toJson();
      expect(json['skill'], 'dartclaw-review-code');
      final restored = WorkflowStep.fromJson(json);
      expect(restored.skill, 'dartclaw-review-code');
    });

    test('skill-only step (no prompts) round-trips (S04)', () {
      const step = WorkflowStep(id: 's', name: 'S', skill: 'dartclaw-review-code');
      final json = step.toJson();
      expect(json.containsKey('prompts'), isFalse);
      final restored = WorkflowStep.fromJson(json);
      expect(restored.skill, 'dartclaw-review-code');
      expect(restored.prompts, isNull);
      expect(restored.prompt, isNull);
    });

    test('step without skill has null skill field (S04)', () {
      const step = _basicStep;
      expect(step.skill, isNull);
      final json = step.toJson();
      expect(json.containsKey('skill'), isFalse);
      final restored = WorkflowStep.fromJson(json);
      expect(restored.skill, isNull);
    });
  });

  group('WorkflowDefinition', () {
    WorkflowDefinition buildDefinition() {
      return const WorkflowDefinition(
        name: 'my-workflow',
        description: 'A test workflow',
        variables: {'VAR': WorkflowVariable(description: 'A variable')},
        project: '{{PROJECT}}',
        steps: [
          WorkflowStep(id: 'step-1', name: 'Step One', prompts: ['Do {{VAR}}']),
          WorkflowStep(id: 'step-2', name: 'Step Two', prompts: ['Use {{context.result}}']),
        ],
        loops: [
          WorkflowLoop(id: 'loop-1', steps: ['step-2'], maxIterations: 3, exitGate: 'step-2.done == true'),
        ],
        maxTokens: 50000,
      );
    }

    test('round-trips via toJson/fromJson', () {
      final def = buildDefinition();
      final json = def.toJson();
      final restored = WorkflowDefinition.fromJson(json);

      expect(restored.name, 'my-workflow');
      expect(restored.description, 'A test workflow');
      expect(restored.variables.length, 1);
      expect(restored.variables['VAR']!.description, 'A variable');
      expect(restored.steps.length, 2);
      expect(restored.steps[0].id, 'step-1');
      expect(restored.steps[1].id, 'step-2');
      expect(restored.loops.length, 1);
      expect(restored.loops[0].id, 'loop-1');
      expect(restored.nodes, hasLength(2));
      expect(restored.nodes.first, isA<ActionNode>());
      expect(restored.nodes.last, isA<LoopNode>());
      expect(restored.maxTokens, 50000);
      expect(restored.project, '{{PROJECT}}');
    });

    test('copyWith updates and clears workflow-level project', () {
      final def = buildDefinition();
      final updated = def.copyWith(project: 'docs-project');
      expect(updated.project, 'docs-project');

      final cleared = updated.copyWith(project: null);
      expect(cleared.project, isNull);
    });

    test('round-trips with no loops', () {
      const def = WorkflowDefinition(name: 'simple', description: 'Simple', steps: [_basicStep]);
      final restored = WorkflowDefinition.fromJson(def.toJson());
      expect(restored.loops, isEmpty);
      expect(restored.nodes.single, isA<ActionNode>());
      expect(restored.maxTokens, isNull);
      expect(restored.stepDefaults, isNull);
    });

    test('round-trips with stepDefaults (S03)', () {
      const def = WorkflowDefinition(
        name: 'wf',
        description: 'desc',
        steps: [_basicStep],
        stepDefaults: [
          StepConfigDefault(match: 'review*', model: 'claude-opus-4'),
          StepConfigDefault(match: '*', provider: 'claude'),
        ],
      );
      final json = def.toJson();
      expect(json.containsKey('stepDefaults'), true);
      final restored = WorkflowDefinition.fromJson(json);
      expect(restored.stepDefaults, isNotNull);
      expect(restored.stepDefaults!.length, 2);
      expect(restored.stepDefaults![0].match, 'review*');
      expect(restored.stepDefaults![0].model, 'claude-opus-4');
      expect(restored.stepDefaults![1].match, '*');
      expect(restored.stepDefaults![1].provider, 'claude');
    });

    test('normalizes action, map, parallel, and loop nodes when nodes are omitted from json', () {
      const def = WorkflowDefinition(
        name: 'normalized',
        description: 'Normalized nodes',
        steps: [
          WorkflowStep(id: 'setup', name: 'Setup', prompts: ['p']),
          WorkflowStep(id: 'fanout', name: 'Fanout', prompts: ['p'], mapOver: 'stories'),
          WorkflowStep(id: 'review-a', name: 'Review A', prompts: ['p'], parallel: true),
          WorkflowStep(id: 'review-b', name: 'Review B', prompts: ['p'], parallel: true),
          WorkflowStep(id: 'remediate', name: 'Remediate', prompts: ['p']),
          WorkflowStep(id: 're-review', name: 'Re-review', prompts: ['p']),
        ],
        loops: [
          WorkflowLoop(
            id: 'loop-1',
            steps: ['remediate', 're-review'],
            maxIterations: 3,
            exitGate: 're-review.status == accepted',
          ),
        ],
      );

      final legacyJson = def.toJson()..remove('nodes');
      final restored = WorkflowDefinition.fromJson(legacyJson);

      expect(
        restored.nodes.map((node) => node.runtimeType).toList(),
        equals([ActionNode, MapNode, ParallelGroupNode, LoopNode]),
      );
      expect((restored.nodes[2] as ParallelGroupNode).stepIds, ['review-a', 'review-b']);
      expect((restored.nodes[3] as LoopNode).stepIds, ['remediate', 're-review']);
    });

    test('normalizes foreach controller into ForeachNode and excludes child steps from top-level (S19)', () {
      const def = WorkflowDefinition(
        name: 'foreach-norm',
        description: 'Foreach normalization',
        steps: [
          WorkflowStep(id: 'plan', name: 'Plan', prompts: ['p'], outputs: {'stories': OutputConfig()}),
          WorkflowStep(
            id: 'story-pipeline',
            name: 'Story Pipeline',
            taskType: WorkflowTaskType.foreach,
            mapOver: 'stories',
            foreachSteps: ['implement', 'validate', 'review'],
            outputs: {'story_results': OutputConfig()},
          ),
          WorkflowStep(id: 'implement', name: 'Implement', prompts: ['p'], taskType: WorkflowTaskType.agent),
          WorkflowStep(id: 'validate', name: 'Validate', prompts: ['p']),
          WorkflowStep(id: 'review', name: 'Review', prompts: ['p']),
          WorkflowStep(id: 'publish', name: 'Publish', prompts: ['p']),
        ],
      );

      expect(def.nodes.map((n) => n.runtimeType).toList(), equals([ActionNode, ForeachNode, ActionNode]));
      final foreachNode = def.nodes[1] as ForeachNode;
      expect(foreachNode.stepId, 'story-pipeline');
      expect(foreachNode.childStepIds, ['implement', 'validate', 'review']);

      // Round-trip preserves foreach normalization.
      final restored = WorkflowDefinition.fromJson(def.toJson());
      expect(restored.nodes.map((n) => n.runtimeType).toList(), equals([ActionNode, ForeachNode, ActionNode]));
      final restoredForeach = restored.nodes[1] as ForeachNode;
      expect(restoredForeach.stepId, 'story-pipeline');
      expect(restoredForeach.childStepIds, ['implement', 'validate', 'review']);
    });

    test('stepDefaults absent from json when null (S03)', () {
      const def = WorkflowDefinition(name: 'wf', description: 'd', steps: [_basicStep]);
      final json = def.toJson();
      expect(json.containsKey('stepDefaults'), false);
      expect(WorkflowDefinition.fromJson(json).stepDefaults, isNull);
    });

    test('gitStrategy absent from json when null (S16b)', () {
      const def = WorkflowDefinition(name: 'wf', description: 'd', steps: [_basicStep]);
      final json = def.toJson();
      expect(json.containsKey('gitStrategy'), false);
      expect(WorkflowDefinition.fromJson(json).gitStrategy, isNull);
    });
  });

  group('OutputFormat (S01)', () {
    test('fromYaml maps known values and rejects unknown values', () {
      for (final testCase in const [
        (yaml: 'text', expected: OutputFormat.text),
        (yaml: 'json', expected: OutputFormat.json),
        (yaml: 'lines', expected: OutputFormat.lines),
        (yaml: 'invalid', expected: null),
      ]) {
        expect(OutputFormat.fromYaml(testCase.yaml), testCase.expected);
      }
    });
  });

  group('OutputConfig (S01)', () {
    test('defaults to text format with no schema', () {
      const config = OutputConfig();
      expect(config.format, OutputFormat.text);
      expect(config.schema, isNull);
      expect(config.hasSchema, false);
      expect(config.presetName, isNull);
      expect(config.inlineSchema, isNull);
    });

    test('round-trips via toJson/fromJson with preset schema', () {
      const config = OutputConfig(format: OutputFormat.json, schema: 'verdict');
      final json = config.toJson();
      final restored = OutputConfig.fromJson(json);
      expect(restored.format, OutputFormat.json);
      expect(restored.presetName, 'verdict');
      expect(restored.hasSchema, true);
    });

    test('round-trips via toJson/fromJson with inline schema', () {
      final schema = {
        'type': 'object',
        'properties': {
          'key': {'type': 'string'},
        },
      };
      final config = OutputConfig(format: OutputFormat.json, schema: schema);
      final json = config.toJson();
      final restored = OutputConfig.fromJson(json);
      expect(restored.format, OutputFormat.json);
      expect(restored.inlineSchema, isNotNull);
      expect(restored.inlineSchema!['type'], 'object');
    });

    test('round-trips via toJson/fromJson with no schema', () {
      const config = OutputConfig(format: OutputFormat.lines);
      final restored = OutputConfig.fromJson(config.toJson());
      expect(restored.format, OutputFormat.lines);
      expect(restored.schema, isNull);
    });

    test('presetName returns null when schema is not a string', () {
      final config = OutputConfig(schema: {'type': 'object'});
      expect(config.presetName, isNull);
    });

    test('inlineSchema returns null when schema is a string', () {
      const config = OutputConfig(schema: 'verdict');
      expect(config.inlineSchema, isNull);
    });

    group('setValue', () {
      test('defaults to unset and omits the key in JSON', () {
        const config = OutputConfig();
        expect(config.hasSetValue, isFalse);
        expect(config.setValue, isNull);
        expect(config.toJson().containsKey('setValue'), isFalse);
      });

      test('round-trips explicit null distinctly from unset', () {
        const config = OutputConfig(setValue: null);
        expect(config.hasSetValue, isTrue);
        expect(config.setValue, isNull);
        final json = config.toJson();
        expect(json.containsKey('setValue'), isTrue);
        expect(json['setValue'], isNull);
        final restored = OutputConfig.fromJson(json);
        expect(restored.hasSetValue, isTrue);
        expect(restored.setValue, isNull);
      });

      test('round-trips literal values across JSON-encodable types', () {
        for (final value in <Object?>[
          'x',
          42,
          3.14,
          true,
          false,
          0,
          '',
          <Object?>['a', 'b'],
          <String, Object?>{'k': 1},
        ]) {
          final config = OutputConfig(setValue: value);
          expect(config.hasSetValue, isTrue, reason: 'hasSetValue for $value');
          expect(config.setValue, value);
          final restored = OutputConfig.fromJson(config.toJson());
          expect(restored.hasSetValue, isTrue, reason: 'restored hasSetValue for $value');
          expect(restored.setValue, value, reason: 'restored value for $value');
        }
      });

      test('three states (unset, explicit null, explicit "x") remain distinguishable after round-trip', () {
        const unset = OutputConfig();
        const explicitNull = OutputConfig(setValue: null);
        const explicitX = OutputConfig(setValue: 'x');

        final restoredUnset = OutputConfig.fromJson(unset.toJson());
        final restoredNull = OutputConfig.fromJson(explicitNull.toJson());
        final restoredX = OutputConfig.fromJson(explicitX.toJson());

        expect(restoredUnset.hasSetValue, isFalse);
        expect(restoredNull.hasSetValue, isTrue);
        expect(restoredNull.setValue, isNull);
        expect(restoredX.hasSetValue, isTrue);
        expect(restoredX.setValue, 'x');
      });
    });
  });

  group('WorkflowStep outputs (S01)', () {
    test('round-trips outputs map with preset schema', () {
      final step = WorkflowStep(
        id: 's',
        name: 'S',
        prompts: const ['p'],
        outputs: const {'result': OutputConfig(format: OutputFormat.json, schema: 'verdict')},
      );
      final restored = WorkflowStep.fromJson(step.toJson());
      expect(restored.outputs, isNotNull);
      expect(restored.outputs!['result']!.format, OutputFormat.json);
      expect(restored.outputs!['result']!.presetName, 'verdict');
    });

    test('workflow step json omits evaluator field', () {
      const step = _basicStep;
      final json = step.toJson();
      expect(json.containsKey('evaluator'), false);
    });

    test('outputs null when not set (backward compat)', () {
      const step = _basicStep;
      final json = step.toJson();
      expect(json.containsKey('outputs'), false);
      final restored = WorkflowStep.fromJson(json);
      expect(restored.outputs, isNull);
    });

    test('workflow step round-trip remains evaluator-free', () {
      const step = _basicStep;
      final restored = WorkflowStep.fromJson(step.toJson());
      expect(restored.toJson().containsKey('evaluator'), false);
    });

    test('outputExamples round-trip through step json', () {
      const step = WorkflowStep(
        id: 's',
        name: 'S',
        prompts: ['p'],
        outputExamples: [
          '<workflow-context>{"prd":"a.md"}</workflow-context>',
          '<workflow-context>{"prd":""}</workflow-context>',
        ],
      );
      final restored = WorkflowStep.fromJson(step.toJson());
      expect(restored.outputExamples, step.outputExamples);
    });
  });

  group('WorkflowStep multi-prompt (S02)', () {
    test('single-string prompt normalized to 1-element list on fromJson', () {
      final json = <String, dynamic>{
        'id': 's',
        'name': 'S',
        'prompt': 'Do it',
        'type': 'agent',
        'review': 'codingOnly',
        'parallel': false,
        'inputs': <String>[],
      };
      final step = WorkflowStep.fromJson(json);
      expect(step.prompts, ['Do it']);
      expect(step.prompt, 'Do it');
      expect(step.isMultiPrompt, false);
    });

    test('multi-string prompt list preserved on fromJson', () {
      final json = <String, dynamic>{
        'id': 's',
        'name': 'S',
        'prompts': ['First', 'Second', 'Third'],
        'type': 'agent',
        'review': 'codingOnly',
        'parallel': false,
        'inputs': <String>[],
      };
      final step = WorkflowStep.fromJson(json);
      expect(step.prompts, ['First', 'Second', 'Third']);
      expect(step.prompt, 'First');
      expect(step.isMultiPrompt, true);
    });

    test('toJson serializes multi-prompt as list', () {
      const step = WorkflowStep(id: 's', name: 'S', prompts: ['A', 'B']);
      final json = step.toJson();
      expect(json['prompts'], ['A', 'B']);
      expect(json.containsKey('prompt'), false);
    });

    test('round-trip: multi-prompt step preserves all prompts', () {
      const step = WorkflowStep(id: 's', name: 'S', prompts: ['Step one', 'Step two', 'Step three']);
      final restored = WorkflowStep.fromJson(step.toJson());
      expect(restored.prompts, ['Step one', 'Step two', 'Step three']);
      expect(restored.isMultiPrompt, true);
    });

    test('single-prompt isMultiPrompt is false', () {
      const step = _basicStep;
      expect(step.isMultiPrompt, false);
    });

    test('multi-prompt prompt getter returns first element', () {
      const step = WorkflowStep(id: 's', name: 'S', prompts: ['first', 'second']);
      expect(step.prompt, 'first');
    });
  });

  group('WorkflowStep map fields (S06)', () {
    test('defaults: mapOver null, maxParallel null, maxItems null', () {
      const step = _basicStep;
      expect(step.mapOver, isNull);
      expect(step.maxParallel, isNull);
      expect(step.maxItems, isNull);
      expect(step.isMapStep, false);
    });

    test('mapOver set marks step as map step', () {
      const step = WorkflowStep(id: 's', name: 'S', prompts: ['p'], mapOver: 'stories');
      expect(step.mapOver, 'stories');
      expect(step.isMapStep, true);
    });

    for (final testCase in const [
      (name: 'mapOver string', step: WorkflowStep(id: 's', name: 'S', prompts: ['p'], mapOver: 'stories')),
      (name: 'maxParallel as int', step: WorkflowStep(id: 's', name: 'S', prompts: ['p'], maxParallel: 3)),
      (
        name: 'maxParallel as "unlimited" string',
        step: WorkflowStep(id: 's', name: 'S', prompts: ['p'], maxParallel: 'unlimited'),
      ),
      (
        name: 'maxParallel as template string',
        step: WorkflowStep(id: 's', name: 'S', prompts: ['p'], maxParallel: '{{MAX_PARALLEL}}'),
      ),
      (name: 'maxItems custom value', step: WorkflowStep(id: 's', name: 'S', prompts: ['p'], maxItems: 15)),
    ]) {
      test('round-trip: ${testCase.name}', () {
        final restored = WorkflowStep.fromJson(testCase.step.toJson());
        expect(restored.mapOver, testCase.step.mapOver);
        expect(restored.maxParallel, testCase.step.maxParallel);
        expect(restored.maxItems, testCase.step.maxItems);
      });
    }

    test('toJson omits mapOver when null', () {
      const step = _basicStep;
      final json = step.toJson();
      expect(json.containsKey('mapOver'), false);
      expect(json.containsKey('maxParallel'), false);
      expect(json.containsKey('maxItems'), false);
    });

    test('toJson omits maxItems when unset', () {
      const step = WorkflowStep(id: 's', name: 'S', prompts: ['p'], mapOver: 'items');
      final json = step.toJson();
      expect(json.containsKey('maxItems'), false);
    });

    test('fromJson leaves maxItems uncapped when absent', () {
      final json = <String, dynamic>{
        'id': 's',
        'name': 'S',
        'prompts': ['p'],
      };
      final step = WorkflowStep.fromJson(json);
      expect(step.maxItems, isNull);
    });

    test('round-trip: all map fields set together', () {
      const step = WorkflowStep(id: 's', name: 'S', prompts: ['p'], mapOver: 'stories', maxParallel: 4, maxItems: 50);
      final restored = WorkflowStep.fromJson(step.toJson());
      expect(restored.mapOver, 'stories');
      expect(restored.maxParallel, 4);
      expect(restored.maxItems, 50);
    });
  });

  group('WorkflowStep hybrid fields (S01 / 0.16.1)', () {
    test('continueSession defaults to null', () {
      const step = _basicStep;
      expect(step.continueSession, isNull);
      final json = step.toJson();
      expect(json.containsKey('continueSession'), false);
      final restored = WorkflowStep.fromJson(json);
      expect(restored.continueSession, isNull);
    });

    test('continueSession step reference round-trips', () {
      const step = WorkflowStep(id: 's', name: 'S', prompts: ['p'], continueSession: 'plan');
      final json = step.toJson();
      expect(json['continueSession'], 'plan');
      final restored = WorkflowStep.fromJson(json);
      expect(restored.continueSession, 'plan');
    });

    test('legacy continueSession: true still round-trips as previous-step sentinel', () {
      final restored = WorkflowStep.fromJson({'id': 's', 'name': 'S', 'prompt': 'p', 'continueSession': true});
      expect(restored.continueSession, '@previous');
      expect(restored.toJson()['continueSession'], isTrue);
    });

    test('onError defaults to null', () {
      const step = _basicStep;
      expect(step.onError, isNull);
      final json = step.toJson();
      expect(json.containsKey('onError'), false);
      expect(WorkflowStep.fromJson(json).onError, isNull);
    });

    for (final (policy, wire) in const [(OnErrorPolicy.continueWorkflow, 'continue'), (OnErrorPolicy.pause, 'pause')]) {
      test('onError: $wire round-trips', () {
        final step = WorkflowStep(id: 's', name: 'S', taskType: WorkflowTaskType.bash, onError: policy);
        final json = step.toJson();
        expect(json['onError'], wire);
        expect(WorkflowStep.fromJson(json).onError, policy);
      });
    }

    test('legacy onError "fail" in json deserializes to pause', () {
      final json = {'id': 's', 'name': 'S', 'type': 'bash', 'onError': 'fail'};
      expect(WorkflowStep.fromJson(json).onError, OnErrorPolicy.pause);
    });

    test('unknown persisted onError value deserializes to null (resume-safe, not a throw)', () {
      // A snapshot from before onError was typed may carry a value the enum no
      // longer accepts (e.g. the previously-tolerated 'retry'); fromJson must
      // degrade to null rather than throw so an in-flight run still resumes.
      final json = {'id': 's', 'name': 'S', 'type': 'bash', 'onError': 'retry'};
      expect(WorkflowStep.fromJson(json).onError, isNull);
    });

    test('workdir defaults to null', () {
      const step = _basicStep;
      expect(step.workdir, isNull);
      final json = step.toJson();
      expect(json.containsKey('workdir'), false);
      expect(WorkflowStep.fromJson(json).workdir, isNull);
    });

    test('workdir round-trips', () {
      const step = WorkflowStep(id: 's', name: 'S', taskType: WorkflowTaskType.bash, workdir: '/tmp/workspace');
      final json = step.toJson();
      expect(json['workdir'], '/tmp/workspace');
      expect(WorkflowStep.fromJson(json).workdir, '/tmp/workspace');
    });

    test('bash type with all new hybrid fields round-trips', () {
      const step = WorkflowStep(
        id: 'build',
        name: 'Build',
        taskType: WorkflowTaskType.bash,
        onError: OnErrorPolicy.continueWorkflow,
        workdir: '/workspace',
        maxRetries: 2,
      );
      final json = step.toJson();
      expect(json['type'], 'bash');
      expect(json['onError'], 'continue');
      expect(json['workdir'], '/workspace');
      final restored = WorkflowStep.fromJson(json);
      expect(restored.taskType, WorkflowTaskType.bash);
      expect(restored.onError, OnErrorPolicy.continueWorkflow);
      expect(restored.workdir, '/workspace');
      expect(restored.maxRetries, 2);
      expect(restored.prompts, isNull);
    });

    test('approval type round-trips without prompt', () {
      const step = WorkflowStep(id: 'gate', name: 'Gate', taskType: WorkflowTaskType.approval);
      final json = step.toJson();
      expect(json['type'], 'approval');
      expect(json.containsKey('prompts'), false);
      final restored = WorkflowStep.fromJson(json);
      expect(restored.taskType, WorkflowTaskType.approval);
      expect(restored.prompts, isNull);
    });

    test('unknown legacy semantic task type is rejected', () {
      final json = <String, dynamic>{
        'id': 'research',
        'name': 'Research',
        'prompt': 'Do research on {{PROJECT}}',
        'type': 'research',
        'review': 'codingOnly',
        'parallel': false,
        'inputs': <String>[],
      };
      expect(
        () => WorkflowStep.fromJson(json),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            allOf(contains('research'), contains('agent'), contains('bash'), contains('aggregate-reviews')),
          ),
        ),
      );
    });

    test('unknown step type throws during model hydration', () {
      expect(
        () => WorkflowStep.fromJson({'id': 's', 'name': 'S', 'type': 'unknown-future-type', 'prompt': 'p'}),
        throwsFormatException,
        reason: 'Unknown type should be rejected before validation',
      );
    });

    test('legacy semantic and custom types throw during model hydration', () {
      for (final type in ['coding', 'analysis', 'research', 'writing', 'automation', 'custom']) {
        expect(
          () => WorkflowStep.fromJson({'id': 's-$type', 'name': 'S', 'type': type, 'prompt': 'p'}),
          throwsFormatException,
        );
      }
    });
  });

  group('Workflow flag enums', () {
    test('WorkflowTaskType preserves exact wire values', () {
      final expected = {
        WorkflowTaskType.agent: 'agent',
        WorkflowTaskType.bash: 'bash',
        WorkflowTaskType.approval: 'approval',
        WorkflowTaskType.foreach: 'foreach',
        WorkflowTaskType.loop: 'loop',
        WorkflowTaskType.aggregateReviews: 'aggregate-reviews',
      };

      for (final entry in expected.entries) {
        expect(entry.key.toJson(), entry.value);
        expect(WorkflowTaskType.fromJsonString(entry.value), entry.key);
      }

      expect(
        () => WorkflowTaskType.fromJsonString('typo'),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            allOf(
              contains('agent'),
              contains('bash'),
              contains('approval'),
              contains('foreach'),
              contains('loop'),
              contains('aggregate-reviews'),
            ),
          ),
        ),
      );
    });

    test('WorkflowExternalArtifactMountMode preserves exact wire values', () {
      expect(
        WorkflowExternalArtifactMountMode.fromJsonString('per-story-copy'),
        WorkflowExternalArtifactMountMode.perStoryCopy,
      );
      expect(WorkflowExternalArtifactMountMode.perStoryCopy.toJson(), 'per-story-copy');
      expect(
        WorkflowExternalArtifactMountMode.fromJsonString('bind-mount'),
        WorkflowExternalArtifactMountMode.bindMount,
      );
      expect(WorkflowExternalArtifactMountMode.bindMount.toJson(), 'bind-mount');
      expect(
        () => WorkflowExternalArtifactMountMode.fromJsonString('symlink'),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            allOf(contains('per-story-copy'), contains('bind-mount')),
          ),
        ),
      );
    });

    test('WorkflowGitWorktreeMode preserves exact wire values', () {
      final expected = {
        WorkflowGitWorktreeMode.shared: 'shared',
        WorkflowGitWorktreeMode.perTask: 'per-task',
        WorkflowGitWorktreeMode.perMapItem: 'per-map-item',
        WorkflowGitWorktreeMode.inline: 'inline',
        WorkflowGitWorktreeMode.auto: 'auto',
      };

      for (final entry in expected.entries) {
        expect(entry.key.toJson(), entry.value);
        expect(WorkflowGitWorktreeMode.fromJsonString(entry.value), entry.key);
      }

      expect(
        () => WorkflowGitWorktreeMode.fromJsonString('branch-per-step'),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            allOf(
              contains('shared'),
              contains('per-task'),
              contains('per-map-item'),
              contains('inline'),
              contains('auto'),
            ),
          ),
        ),
      );
    });

    test('WorkflowStep parses enums and emits unchanged JSON strings', () {
      final bash = WorkflowStep.fromJson({'id': 'build', 'name': 'Build', 'type': 'bash', 'prompt': 'echo ok'});
      expect(bash.taskType, WorkflowTaskType.bash);
      expect(bash.toJson()['type'], 'bash');

      final foreach = WorkflowStep.fromJson({
        'id': 'story-pipeline',
        'name': 'Story Pipeline',
        'type': 'foreach',
        'mapOver': 'stories',
        'foreachSteps': ['implement'],
      });
      expect(foreach.taskType, WorkflowTaskType.foreach);
      expect(foreach.toJson()['type'], 'foreach');
    });

    test('WorkflowGitExternalArtifactMount parses enums and emits unchanged JSON strings', () {
      final copy = WorkflowGitExternalArtifactMount.fromJson({
        'enabled': true,
        'mode': 'per-story-copy',
        'fromProject': '{{DOC_PROJECT}}',
        'source': '.andthen/artifacts',
        'toPath': '.andthen/artifacts',
      });
      expect(copy.mode, WorkflowExternalArtifactMountMode.perStoryCopy);
      expect(copy.toJson()['mode'], 'per-story-copy');

      final bind = WorkflowGitExternalArtifactMount.fromJson({
        'enabled': true,
        'mode': 'bind-mount',
        'fromProject': '{{DOC_PROJECT}}',
        'source': '.andthen/artifacts',
        'toPath': '.andthen/artifacts',
      });
      expect(bind.mode, WorkflowExternalArtifactMountMode.bindMount);
      expect(bind.toJson()['mode'], 'bind-mount');
    });

    test('WorkflowGitWorktreeStrategy parses enums and emits unchanged JSON strings', () {
      final stringMode = WorkflowGitWorktreeStrategy.fromJson('per-task');
      expect(stringMode.mode, WorkflowGitWorktreeMode.perTask);
      expect(stringMode.toJsonValue(), 'per-task');

      final mapMode = WorkflowGitWorktreeStrategy.fromJson({
        'mode': 'per-map-item',
        'externalArtifactMount': {
          'enabled': true,
          'mode': 'bind-mount',
          'fromProject': '{{DOC_PROJECT}}',
          'source': '.andthen/artifacts',
          'toPath': '.andthen/artifacts',
        },
      });
      expect(mapMode.mode, WorkflowGitWorktreeMode.perMapItem);
      expect(mapMode.toJsonValue(), {
        'mode': 'per-map-item',
        'externalArtifactMount': {
          'mode': 'bind-mount',
          'fromProject': '{{DOC_PROJECT}}',
          'source': '.andthen/artifacts',
          'toPath': '.andthen/artifacts',
        },
      });
    });
  });

  group('MergeResolveEscalation', () {
    test('tryParse maps known values and rejects reserved/unknown values', () {
      for (final testCase in const [
        (value: 'serialize-remaining', expected: MergeResolveEscalation.serializeRemaining),
        (value: 'fail', expected: MergeResolveEscalation.fail),
        (value: 'pause', expected: null),
        (value: 'yolo', expected: null),
        (value: null, expected: null),
      ]) {
        expect(MergeResolveEscalation.tryParse(testCase.value), testCase.expected);
      }
    });

    test('toYamlString round-trips', () {
      expect(MergeResolveEscalation.serializeRemaining.toYamlString(), 'serialize-remaining');
      expect(MergeResolveEscalation.fail.toYamlString(), 'fail');
    });
  });

  group('MergeResolveConfig', () {
    test('const default materializes BPC-18 defaults', () {
      const cfg = MergeResolveConfig();
      expect(cfg.enabled, isFalse);
      expect(cfg.maxAttempts, 2);
      expect(cfg.tokenCeiling, 100000);
      expect(cfg.escalation, MergeResolveEscalation.serializeRemaining);
      expect(cfg.unknownFields, isEmpty);
    });

    test('fromJson with every field set', () {
      final cfg = MergeResolveConfig.fromJson({
        'enabled': true,
        'max_attempts': 3,
        'token_ceiling': 200000,
        'escalation': 'fail',
      });
      expect(cfg.enabled, isTrue);
      expect(cfg.maxAttempts, 3);
      expect(cfg.tokenCeiling, 200000);
      expect(cfg.escalation, MergeResolveEscalation.fail);
      expect(cfg.rawEscalation, 'fail');
    });

    test('fromJson captures unknown top-level keys', () {
      final cfg = MergeResolveConfig.fromJson({'foo': 1, 'enabled': true});
      expect(cfg.unknownFields, ['foo']);
    });

    test('fromJson with pause escalation preserves rawEscalation', () {
      final cfg = MergeResolveConfig.fromJson({'escalation': 'pause'});
      expect(cfg.rawEscalation, 'pause');
      expect(cfg.escalation, isNull);
    });

    test('fromJson with unknown escalation preserves rawEscalation', () {
      final cfg = MergeResolveConfig.fromJson({'escalation': 'yolo'});
      expect(cfg.rawEscalation, 'yolo');
      expect(cfg.escalation, isNull);
    });

    test('fromJson defaults absent escalation to serializeRemaining (BPC-18)', () {
      final cfg = MergeResolveConfig.fromJson({'enabled': true});
      expect(cfg.escalation, MergeResolveEscalation.serializeRemaining);
      expect(cfg.rawEscalation, isNull);
    });

    test('fromJson handles Map<Object?, Object?>', () {
      final raw = <Object?, Object?>{'enabled': true, 'max_attempts': 4};
      final cfg = MergeResolveConfig.fromJson(raw);
      expect(cfg.enabled, isTrue);
      expect(cfg.maxAttempts, 4);
    });

    test('toJson omits default fields', () {
      const cfg = MergeResolveConfig();
      expect(cfg.toJson(), isEmpty);
    });

    test('toJson emits non-default fields', () {
      final cfg = MergeResolveConfig.fromJson({
        'enabled': true,
        'max_attempts': 3,
        'token_ceiling': 200000,
        'escalation': 'fail',
      });
      final json = cfg.toJson();
      expect(json['enabled'], isTrue);
      expect(json['max_attempts'], 3);
      expect(json['token_ceiling'], 200000);
      expect(json['escalation'], 'fail');
    });
  });

  group('WorkflowGitStrategy.mergeResolve', () {
    test('fromJson with merge_resolve block parses enabled:true', () {
      final strategy = WorkflowGitStrategy.fromJson({
        'promotion': 'merge',
        'merge_resolve': {'enabled': true},
      });
      expect(strategy.mergeResolve.enabled, isTrue);
    });

    test('default accessor returns BPC-18 defaults when block absent', () {
      final strategy = WorkflowGitStrategy();
      expect(strategy.mergeResolve.enabled, isFalse);
      expect(strategy.mergeResolve.maxAttempts, 2);
    });

    test('round-trip preserves all merge_resolve fields', () {
      final strategy = WorkflowGitStrategy.fromJson({
        'promotion': 'merge',
        'merge_resolve': {'enabled': true, 'max_attempts': 3, 'token_ceiling': 200000, 'escalation': 'fail'},
      });
      final json = strategy.toJson();
      final restored = WorkflowGitStrategy.fromJson(json);
      expect(restored.mergeResolve.enabled, isTrue);
      expect(restored.mergeResolve.maxAttempts, 3);
      expect(restored.mergeResolve.tokenCeiling, 200000);
      expect(restored.mergeResolve.escalation, MergeResolveEscalation.fail);
    });

    test('toJson omits merge_resolve key when block was absent', () {
      final strategy = WorkflowGitStrategy(promotion: 'merge');
      expect(strategy.toJson().containsKey('merge_resolve'), isFalse);
    });
  });
}
