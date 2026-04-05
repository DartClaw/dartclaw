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
      const config = ExtractionConfig(
        type: ExtractionType.regex,
        pattern: r'\d+',
      );
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
      const v = WorkflowVariable(
        required: true,
        description: 'A variable',
        defaultValue: 'default',
      );
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
        exitGate: 'step-a.status == done',
      );
      final restored = WorkflowLoop.fromJson(loop.toJson());
      expect(restored.id, 'loop-1');
      expect(restored.steps, ['step-a', 'step-b']);
      expect(restored.maxIterations, 5);
      expect(restored.exitGate, 'step-a.status == done');
    });
  });

  group('WorkflowStep', () {
    test('round-trips with all fields', () {
      const step = WorkflowStep(
        id: 'step-1',
        name: 'My Step',
        prompt: 'Do {{VAR}} and {{context.key}}',
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
      const step = WorkflowStep(
        id: 'step-1',
        name: 'Step One',
        prompt: 'Just do it',
      );
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
      const step = WorkflowStep(
        id: 's',
        name: 'S',
        prompt: 'p',
        timeoutSeconds: 1800,
      );
      final json = step.toJson();
      expect(json['timeout'], 1800);
      final restored = WorkflowStep.fromJson(json);
      expect(restored.timeoutSeconds, 1800);
    });
  });

  group('WorkflowDefinition', () {
    WorkflowDefinition buildDefinition() {
      return const WorkflowDefinition(
        name: 'my-workflow',
        description: 'A test workflow',
        variables: {
          'VAR': WorkflowVariable(description: 'A variable'),
        },
        steps: [
          WorkflowStep(id: 'step-1', name: 'Step One', prompt: 'Do {{VAR}}'),
          WorkflowStep(id: 'step-2', name: 'Step Two', prompt: 'Use {{context.result}}'),
        ],
        loops: [
          WorkflowLoop(
            id: 'loop-1',
            steps: ['step-2'],
            maxIterations: 3,
            exitGate: 'step-2.done == true',
          ),
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
      expect(restored.maxTokens, 50000);
    });

    test('round-trips with no loops', () {
      const def = WorkflowDefinition(
        name: 'simple',
        description: 'Simple',
        steps: [WorkflowStep(id: 's', name: 'S', prompt: 'p')],
      );
      final restored = WorkflowDefinition.fromJson(def.toJson());
      expect(restored.loops, isEmpty);
      expect(restored.maxTokens, isNull);
    });
  });
}
