import 'package:dartclaw_models/dartclaw_models.dart';
import 'package:test/test.dart';

void main() {
  group('StepReviewMode', () {
    test('fromYaml maps coding-only to codingOnly', () {
      expect(StepReviewMode.fromYaml('coding-only'), StepReviewMode.codingOnly);
    });

    test('fromYaml maps always', () {
      expect(StepReviewMode.fromYaml('always'), StepReviewMode.always);
    });

    test('fromYaml maps never', () {
      expect(StepReviewMode.fromYaml('never'), StepReviewMode.never);
    });

    test('fromYaml returns null for unknown', () {
      expect(StepReviewMode.fromYaml('invalid'), isNull);
    });
  });

  group('ExtractionConfig', () {
    test('round-trips via toJson/fromJson', () {
      const config = ExtractionConfig(type: ExtractionType.regex, pattern: r'\d+');
      final json = config.toJson();
      final restored = ExtractionConfig.fromJson(json);
      expect(restored.type, ExtractionType.regex);
      expect(restored.pattern, r'\d+');
    });

    test('supports all extraction types', () {
      for (final type in ExtractionType.values) {
        final config = ExtractionConfig(type: type, pattern: 'p');
        final restored = ExtractionConfig.fromJson(config.toJson());
        expect(restored.type, type);
      }
    });
  });

  group('WorkflowVariable', () {
    test('round-trips via toJson/fromJson with default value', () {
      const v = WorkflowVariable(required: true, description: 'A variable', defaultValue: 'default');
      final restored = WorkflowVariable.fromJson(v.toJson());
      expect(restored.required, true);
      expect(restored.description, 'A variable');
      expect(restored.defaultValue, 'default');
    });

    test('round-trips with no default value', () {
      const v = WorkflowVariable(required: false, description: 'optional var');
      final restored = WorkflowVariable.fromJson(v.toJson());
      expect(restored.required, false);
      expect(restored.defaultValue, isNull);
    });

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

    test('round-trips with finally_ field (S03)', () {
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

    test('finally_ absent from json when null (S03)', () {
      const loop = WorkflowLoop(id: 'l', steps: ['s'], maxIterations: 1, exitGate: 'e');
      final json = loop.toJson();
      expect(json.containsKey('finally'), false);
    });
  });

  group('WorkflowNode', () {
    test('action node round-trips via toJson/fromJson', () {
      const node = ActionNode(stepId: 'step-1');
      final restored = WorkflowNode.fromJson(node.toJson());
      expect(restored, isA<ActionNode>());
      expect((restored as ActionNode).stepId, 'step-1');
    });

    test('map node round-trips via toJson/fromJson', () {
      const node = MapNode(stepId: 'story-spec');
      final restored = WorkflowNode.fromJson(node.toJson());
      expect(restored, isA<MapNode>());
      expect((restored as MapNode).stepId, 'story-spec');
    });

    test('parallel group node round-trips via toJson/fromJson', () {
      const node = ParallelGroupNode(stepIds: ['review-a', 'review-b']);
      final restored = WorkflowNode.fromJson(node.toJson());
      expect(restored, isA<ParallelGroupNode>());
      expect((restored as ParallelGroupNode).stepIds, ['review-a', 'review-b']);
    });

    test('loop node round-trips via toJson/fromJson', () {
      const node = LoopNode(
        loopId: 'remediation-loop',
        stepIds: ['remediate', 're-review'],
        finallyStepId: 'summarize',
      );
      final restored = WorkflowNode.fromJson(node.toJson());
      expect(restored, isA<LoopNode>());
      expect((restored as LoopNode).loopId, 'remediation-loop');
      expect(restored.stepIds, ['remediate', 're-review']);
      expect(restored.finallyStepId, 'summarize');
    });

    test('foreach node round-trips via toJson/fromJson (S19)', () {
      const node = ForeachNode(
        stepId: 'story-pipeline',
        childStepIds: ['implement', 'verify-refine', 'quick-review'],
      );
      final json = node.toJson();
      expect(json['type'], 'foreach');
      expect(json['stepId'], 'story-pipeline');
      expect(json['childStepIds'], ['implement', 'verify-refine', 'quick-review']);

      final restored = WorkflowNode.fromJson(json);
      expect(restored, isA<ForeachNode>());
      final foreach = restored as ForeachNode;
      expect(foreach.stepId, 'story-pipeline');
      expect(foreach.childStepIds, ['implement', 'verify-refine', 'quick-review']);
      expect(foreach.stepIds, ['story-pipeline', 'implement', 'verify-refine', 'quick-review']);
    });
  });

  group('StepConfigDefault (S03)', () {
    test('round-trips with all fields', () {
      const d = StepConfigDefault(
        match: 'review*',
        provider: 'claude',
        model: 'claude-opus-4',
        maxTokens: 8000,
        maxCostUsd: 2.5,
        maxRetries: 2,
        allowedTools: ['Read', 'Grep'],
      );
      final json = d.toJson();
      final restored = StepConfigDefault.fromJson(json);
      expect(restored.match, 'review*');
      expect(restored.provider, 'claude');
      expect(restored.model, 'claude-opus-4');
      expect(restored.maxTokens, 8000);
      expect(restored.maxCostUsd, 2.5);
      expect(restored.maxRetries, 2);
      expect(restored.allowedTools, ['Read', 'Grep']);
    });

    test('round-trips with only match (all optionals null)', () {
      const d = StepConfigDefault(match: '*');
      final restored = StepConfigDefault.fromJson(d.toJson());
      expect(restored.match, '*');
      expect(restored.provider, isNull);
      expect(restored.model, isNull);
      expect(restored.maxTokens, isNull);
      expect(restored.maxCostUsd, isNull);
      expect(restored.maxRetries, isNull);
      expect(restored.allowedTools, isNull);
    });

    test('null fields omitted from json', () {
      const d = StepConfigDefault(match: 'impl*');
      final json = d.toJson();
      expect(json.containsKey('provider'), false);
      expect(json.containsKey('model'), false);
      expect(json.containsKey('maxTokens'), false);
      expect(json.containsKey('maxCostUsd'), false);
      expect(json.containsKey('maxRetries'), false);
      expect(json.containsKey('allowedTools'), false);
    });

    test('maxCostUsd int-as-num round-trips to double', () {
      final json = {'match': 'review*', 'maxCostUsd': 2};
      final restored = StepConfigDefault.fromJson(json);
      expect(restored.maxCostUsd, 2.0);
      expect(restored.maxCostUsd, isA<double>());
    });
  });

  group('WorkflowStep', () {
    test('round-trips with all fields', () {
      const step = WorkflowStep(
        id: 'step-1',
        name: 'My Step',
        prompts: ['Do {{VAR}} and {{context.key}}'],
        type: 'coding',
        project: '{{PROJECT}}',
        provider: 'claude',
        model: 'claude-opus',
        timeoutSeconds: 1800,
        review: StepReviewMode.always,
        parallel: true,
        gate: 'prev.status == done',
        contextInputs: ['in_key'],
        contextOutputs: ['out_key'],
        extraction: ExtractionConfig(type: ExtractionType.jsonpath, pattern: r'$.result'),
        maxTokens: 10000,
        maxRetries: 3,
        allowedTools: ['Bash', 'Read'],
      );
      final json = step.toJson();
      final restored = WorkflowStep.fromJson(json);

      expect(restored.id, 'step-1');
      expect(restored.name, 'My Step');
      expect(restored.prompt, 'Do {{VAR}} and {{context.key}}');
      expect(restored.type, 'coding');
      expect(restored.project, '{{PROJECT}}');
      expect(restored.provider, 'claude');
      expect(restored.model, 'claude-opus');
      expect(restored.timeoutSeconds, 1800);
      expect(restored.review, StepReviewMode.always);
      expect(restored.parallel, true);
      expect(restored.gate, 'prev.status == done');
      expect(restored.contextInputs, ['in_key']);
      expect(restored.contextOutputs, ['out_key']);
      expect(restored.extraction!.type, ExtractionType.jsonpath);
      expect(restored.extraction!.pattern, r'$.result');
      expect(restored.maxTokens, 10000);
      expect(restored.maxRetries, 3);
      expect(restored.allowedTools, ['Bash', 'Read']);
    });

    test('round-trips with only required fields (defaults applied)', () {
      const step = WorkflowStep(id: 'step-1', name: 'Step One', prompts: ['Just do it']);
      final restored = WorkflowStep.fromJson(step.toJson());
      expect(restored.type, 'research');
      expect(restored.review, StepReviewMode.codingOnly);
      expect(restored.parallel, false);
      expect(restored.contextInputs, isEmpty);
      expect(restored.contextOutputs, isEmpty);
      expect(restored.extraction, isNull);
      expect(restored.maxTokens, isNull);
      expect(restored.allowedTools, isNull);
    });

    test('timeout stored as seconds integer', () {
      const step = WorkflowStep(id: 's', name: 'S', prompts: ['p'], timeoutSeconds: 1800);
      final json = step.toJson();
      expect(json['timeout'], 1800);
      final restored = WorkflowStep.fromJson(json);
      expect(restored.timeoutSeconds, 1800);
    });

    test('round-trips maxCostUsd (S03)', () {
      const step = WorkflowStep(id: 's', name: 'S', prompts: ['p'], maxCostUsd: 1.5);
      final json = step.toJson();
      expect(json['maxCostUsd'], 1.5);
      final restored = WorkflowStep.fromJson(json);
      expect(restored.maxCostUsd, 1.5);
    });

    test('maxCostUsd absent from json when null (S03)', () {
      const step = WorkflowStep(id: 's', name: 'S', prompts: ['p']);
      final json = step.toJson();
      expect(json.containsKey('maxCostUsd'), false);
      expect(WorkflowStep.fromJson(json).maxCostUsd, isNull);
    });

    test('maxCostUsd int-as-num in json normalizes to double (S03)', () {
      final json = {'id': 's', 'name': 'S', 'prompt': 'p', 'maxCostUsd': 2};
      final restored = WorkflowStep.fromJson(json);
      expect(restored.maxCostUsd, 2.0);
      expect(restored.maxCostUsd, isA<double>());
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
      const step = WorkflowStep(id: 's', name: 'S', prompts: ['p']);
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
    });

    test('round-trips with no loops', () {
      const def = WorkflowDefinition(
        name: 'simple',
        description: 'Simple',
        steps: [
          WorkflowStep(id: 's', name: 'S', prompts: ['p']),
        ],
      );
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
        steps: [
          WorkflowStep(id: 's', name: 'S', prompts: ['p']),
        ],
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

    test('round-trips with gitStrategy (S16b)', () {
      const def = WorkflowDefinition(
        name: 'wf',
        description: 'desc',
        steps: [
          WorkflowStep(id: 's', name: 'S', prompts: ['p']),
        ],
        gitStrategy: WorkflowGitStrategy(
          bootstrap: true,
          worktree: 'shared',
          promotion: 'merge',
          publish: WorkflowGitPublishStrategy(enabled: true),
        ),
      );
      final json = def.toJson();
      expect(json.containsKey('gitStrategy'), true);
      final restored = WorkflowDefinition.fromJson(json);
      expect(restored.gitStrategy, isNotNull);
      expect(restored.gitStrategy!.bootstrap, isTrue);
      expect(restored.gitStrategy!.worktree, 'shared');
      expect(restored.gitStrategy!.promotion, 'merge');
      expect(restored.gitStrategy!.publish?.enabled, isTrue);
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
          WorkflowStep(id: 'plan', name: 'Plan', prompts: ['p'], contextOutputs: ['stories']),
          WorkflowStep(
            id: 'story-pipeline',
            name: 'Story Pipeline',
            type: 'foreach',
            mapOver: 'stories',
            foreachSteps: ['implement', 'validate', 'review'],
            contextOutputs: ['story_results'],
          ),
          WorkflowStep(id: 'implement', name: 'Implement', prompts: ['p'], type: 'coding'),
          WorkflowStep(id: 'validate', name: 'Validate', prompts: ['p']),
          WorkflowStep(id: 'review', name: 'Review', prompts: ['p']),
          WorkflowStep(id: 'publish', name: 'Publish', prompts: ['p']),
        ],
      );

      expect(
        def.nodes.map((n) => n.runtimeType).toList(),
        equals([ActionNode, ForeachNode, ActionNode]),
      );
      final foreachNode = def.nodes[1] as ForeachNode;
      expect(foreachNode.stepId, 'story-pipeline');
      expect(foreachNode.childStepIds, ['implement', 'validate', 'review']);

      // Round-trip preserves foreach normalization.
      final restored = WorkflowDefinition.fromJson(def.toJson());
      expect(
        restored.nodes.map((n) => n.runtimeType).toList(),
        equals([ActionNode, ForeachNode, ActionNode]),
      );
      final restoredForeach = restored.nodes[1] as ForeachNode;
      expect(restoredForeach.stepId, 'story-pipeline');
      expect(restoredForeach.childStepIds, ['implement', 'validate', 'review']);
    });

    test('stepDefaults absent from json when null (S03)', () {
      const def = WorkflowDefinition(
        name: 'wf',
        description: 'd',
        steps: [
          WorkflowStep(id: 's', name: 'S', prompts: ['p']),
        ],
      );
      final json = def.toJson();
      expect(json.containsKey('stepDefaults'), false);
      expect(WorkflowDefinition.fromJson(json).stepDefaults, isNull);
    });

    test('gitStrategy absent from json when null (S16b)', () {
      const def = WorkflowDefinition(
        name: 'wf',
        description: 'd',
        steps: [
          WorkflowStep(id: 's', name: 'S', prompts: ['p']),
        ],
      );
      final json = def.toJson();
      expect(json.containsKey('gitStrategy'), false);
      expect(WorkflowDefinition.fromJson(json).gitStrategy, isNull);
    });
  });

  group('OutputFormat (S01)', () {
    test('fromYaml maps text', () {
      expect(OutputFormat.fromYaml('text'), OutputFormat.text);
    });

    test('fromYaml maps json', () {
      expect(OutputFormat.fromYaml('json'), OutputFormat.json);
    });

    test('fromYaml maps lines', () {
      expect(OutputFormat.fromYaml('lines'), OutputFormat.lines);
    });

    test('fromYaml returns null for unknown', () {
      expect(OutputFormat.fromYaml('invalid'), isNull);
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
  });

  group('WorkflowStep outputs (S01)', () {
    test('round-trips outputs map with preset schema', () {
      final step = WorkflowStep(
        id: 's',
        name: 'S',
        prompts: const ['p'],
        contextOutputs: const ['result'],
        outputs: const {'result': OutputConfig(format: OutputFormat.json, schema: 'verdict')},
      );
      final restored = WorkflowStep.fromJson(step.toJson());
      expect(restored.outputs, isNotNull);
      expect(restored.outputs!['result']!.format, OutputFormat.json);
      expect(restored.outputs!['result']!.presetName, 'verdict');
    });

    test('workflow step json omits evaluator field', () {
      const step = WorkflowStep(id: 's', name: 'S', prompts: ['p']);
      final json = step.toJson();
      expect(json.containsKey('evaluator'), false);
    });

    test('outputs null when not set (backward compat)', () {
      const step = WorkflowStep(id: 's', name: 'S', prompts: ['p']);
      final json = step.toJson();
      expect(json.containsKey('outputs'), false);
      final restored = WorkflowStep.fromJson(json);
      expect(restored.outputs, isNull);
    });

    test('workflow step round-trip remains evaluator-free', () {
      const step = WorkflowStep(id: 's', name: 'S', prompts: ['p']);
      final restored = WorkflowStep.fromJson(step.toJson());
      expect(restored.toJson().containsKey('evaluator'), false);
    });
  });

  group('WorkflowStep multi-prompt (S02)', () {
    test('single-string prompt normalized to 1-element list on fromJson', () {
      final json = <String, dynamic>{
        'id': 's',
        'name': 'S',
        'prompt': 'Do it',
        'type': 'research',
        'review': 'codingOnly',
        'parallel': false,
        'contextInputs': <String>[],
        'contextOutputs': <String>[],
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
        'type': 'research',
        'review': 'codingOnly',
        'parallel': false,
        'contextInputs': <String>[],
        'contextOutputs': <String>[],
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
      const step = WorkflowStep(id: 's', name: 'S', prompts: ['p']);
      expect(step.isMultiPrompt, false);
    });

    test('multi-prompt prompt getter returns first element', () {
      const step = WorkflowStep(id: 's', name: 'S', prompts: ['first', 'second']);
      expect(step.prompt, 'first');
    });
  });

  group('WorkflowStep map fields (S06)', () {
    test('defaults: mapOver null, maxParallel null, maxItems 20', () {
      const step = WorkflowStep(id: 's', name: 'S', prompts: ['p']);
      expect(step.mapOver, isNull);
      expect(step.maxParallel, isNull);
      expect(step.maxItems, 20);
      expect(step.isMapStep, false);
    });

    test('mapOver set marks step as map step', () {
      const step = WorkflowStep(id: 's', name: 'S', prompts: ['p'], mapOver: 'stories');
      expect(step.mapOver, 'stories');
      expect(step.isMapStep, true);
    });

    test('round-trip: mapOver string', () {
      const step = WorkflowStep(id: 's', name: 'S', prompts: ['p'], mapOver: 'stories');
      final restored = WorkflowStep.fromJson(step.toJson());
      expect(restored.mapOver, 'stories');
    });

    test('round-trip: maxParallel as int', () {
      const step = WorkflowStep(id: 's', name: 'S', prompts: ['p'], maxParallel: 3);
      final restored = WorkflowStep.fromJson(step.toJson());
      expect(restored.maxParallel, 3);
    });

    test('round-trip: maxParallel as "unlimited" string', () {
      const step = WorkflowStep(id: 's', name: 'S', prompts: ['p'], maxParallel: 'unlimited');
      final restored = WorkflowStep.fromJson(step.toJson());
      expect(restored.maxParallel, 'unlimited');
    });

    test('round-trip: maxParallel as template string', () {
      const step = WorkflowStep(id: 's', name: 'S', prompts: ['p'], maxParallel: '{{MAX_PARALLEL}}');
      final restored = WorkflowStep.fromJson(step.toJson());
      expect(restored.maxParallel, '{{MAX_PARALLEL}}');
    });

    test('round-trip: maxItems custom value', () {
      const step = WorkflowStep(id: 's', name: 'S', prompts: ['p'], maxItems: 15);
      final restored = WorkflowStep.fromJson(step.toJson());
      expect(restored.maxItems, 15);
    });

    test('toJson omits mapOver when null', () {
      const step = WorkflowStep(id: 's', name: 'S', prompts: ['p']);
      final json = step.toJson();
      expect(json.containsKey('mapOver'), false);
      expect(json.containsKey('maxParallel'), false);
      expect(json.containsKey('maxItems'), false);
    });

    test('toJson omits maxItems when default (20)', () {
      const step = WorkflowStep(id: 's', name: 'S', prompts: ['p'], mapOver: 'items');
      final json = step.toJson();
      expect(json.containsKey('maxItems'), false);
    });

    test('fromJson defaults maxItems to 20 when absent', () {
      final json = <String, dynamic>{
        'id': 's',
        'name': 'S',
        'prompts': ['p'],
      };
      final step = WorkflowStep.fromJson(json);
      expect(step.maxItems, 20);
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
      const step = WorkflowStep(id: 's', name: 'S', prompts: ['p']);
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
      const step = WorkflowStep(id: 's', name: 'S', prompts: ['p']);
      expect(step.onError, isNull);
      final json = step.toJson();
      expect(json.containsKey('onError'), false);
      expect(WorkflowStep.fromJson(json).onError, isNull);
    });

    test('onError: continue round-trips', () {
      const step = WorkflowStep(id: 's', name: 'S', type: 'bash', onError: 'continue');
      final json = step.toJson();
      expect(json['onError'], 'continue');
      expect(WorkflowStep.fromJson(json).onError, 'continue');
    });

    test('onError: retry round-trips', () {
      const step = WorkflowStep(id: 's', name: 'S', type: 'bash', onError: 'retry');
      final json = step.toJson();
      expect(json['onError'], 'retry');
      expect(WorkflowStep.fromJson(json).onError, 'retry');
    });

    test('workdir defaults to null', () {
      const step = WorkflowStep(id: 's', name: 'S', prompts: ['p']);
      expect(step.workdir, isNull);
      final json = step.toJson();
      expect(json.containsKey('workdir'), false);
      expect(WorkflowStep.fromJson(json).workdir, isNull);
    });

    test('workdir round-trips', () {
      const step = WorkflowStep(id: 's', name: 'S', type: 'bash', workdir: '/tmp/workspace');
      final json = step.toJson();
      expect(json['workdir'], '/tmp/workspace');
      expect(WorkflowStep.fromJson(json).workdir, '/tmp/workspace');
    });

    test('bash type with all new hybrid fields round-trips', () {
      const step = WorkflowStep(
        id: 'build',
        name: 'Build',
        type: 'bash',
        onError: 'retry',
        workdir: '/workspace',
        maxRetries: 2,
      );
      final json = step.toJson();
      expect(json['type'], 'bash');
      expect(json['onError'], 'retry');
      expect(json['workdir'], '/workspace');
      final restored = WorkflowStep.fromJson(json);
      expect(restored.type, 'bash');
      expect(restored.onError, 'retry');
      expect(restored.workdir, '/workspace');
      expect(restored.maxRetries, 2);
      expect(restored.prompts, isNull);
    });

    test('approval type round-trips without prompt', () {
      const step = WorkflowStep(id: 'gate', name: 'Gate', type: 'approval');
      final json = step.toJson();
      expect(json['type'], 'approval');
      expect(json.containsKey('prompts'), false);
      final restored = WorkflowStep.fromJson(json);
      expect(restored.type, 'approval');
      expect(restored.prompts, isNull);
    });

    test('legacy 0.15 step deserializes unchanged (backward compat)', () {
      final json = <String, dynamic>{
        'id': 'research',
        'name': 'Research',
        'prompt': 'Do research on {{PROJECT}}',
        'type': 'research',
        'review': 'codingOnly',
        'parallel': false,
        'contextInputs': <String>[],
        'contextOutputs': ['result'],
      };
      final step = WorkflowStep.fromJson(json);
      expect(step.type, 'research');
      expect(step.continueSession, isNull);
      expect(step.onError, isNull);
      expect(step.workdir, isNull);
      expect(step.prompt, 'Do research on {{PROJECT}}');
    });
  });
}
