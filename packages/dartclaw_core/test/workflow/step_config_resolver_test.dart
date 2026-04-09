import 'package:dartclaw_core/dartclaw_core.dart'
    show
        StepConfigDefault,
        WorkflowStep,
        globMatchStepId,
        resolveStepConfig;
import 'package:test/test.dart';

void main() {
  group('globMatchStepId', () {
    test('review* matches review-code', () {
      expect(globMatchStepId('review*', 'review-code'), isTrue);
    });

    test('review* matches review-security', () {
      expect(globMatchStepId('review*', 'review-security'), isTrue);
    });

    test('review* matches bare review', () {
      expect(globMatchStepId('review*', 'review'), isTrue);
    });

    test('review* does not match implement', () {
      expect(globMatchStepId('review*', 'implement'), isFalse);
    });

    test('* matches everything', () {
      expect(globMatchStepId('*', 'review-code'), isTrue);
      expect(globMatchStepId('*', 'implement-feature'), isTrue);
      expect(globMatchStepId('*', 'x'), isTrue);
    });

    test('exact pattern matches only identical step id', () {
      expect(globMatchStepId('implement', 'implement'), isTrue);
      expect(globMatchStepId('implement', 'implement-feature'), isFalse);
    });

    test('*-analysis matches gap-analysis but not analysis-gap', () {
      expect(globMatchStepId('*-analysis', 'gap-analysis'), isTrue);
      expect(globMatchStepId('*-analysis', 'analysis-gap'), isFalse);
    });

    test('pattern without wildcard is exact match', () {
      expect(globMatchStepId('step-a', 'step-a'), isTrue);
      expect(globMatchStepId('step-a', 'step-b'), isFalse);
    });

    test('wildcard in middle: review-*-step matches review-code-step', () {
      expect(globMatchStepId('review-*-step', 'review-code-step'), isTrue);
      expect(globMatchStepId('review-*-step', 'review-code'), isFalse);
    });
  });

  group('resolveStepConfig', () {
    WorkflowStep makeStep({
      String id = 'review-code',
      String? provider,
      String? model,
      int? maxTokens,
      double? maxCostUsd,
      int? maxRetries,
      List<String>? allowedTools,
    }) {
      return WorkflowStep(
        id: id,
        name: id,
        prompts: ['p'],
        provider: provider,
        model: model,
        maxTokens: maxTokens,
        maxCostUsd: maxCostUsd,
        maxRetries: maxRetries,
        allowedTools: allowedTools,
      );
    }

    test('null defaults returns all-null resolved config', () {
      final step = makeStep();
      final resolved = resolveStepConfig(step, null);
      expect(resolved.provider, isNull);
      expect(resolved.model, isNull);
      expect(resolved.maxTokens, isNull);
      expect(resolved.maxCostUsd, isNull);
      expect(resolved.maxRetries, isNull);
      expect(resolved.allowedTools, isNull);
    });

    test('empty defaults list returns all-null resolved config', () {
      final step = makeStep();
      final resolved = resolveStepConfig(step, []);
      expect(resolved.provider, isNull);
      expect(resolved.model, isNull);
    });

    test('first match wins: review-code matches review* not *', () {
      final step = makeStep(id: 'review-code');
      final defaults = [
        const StepConfigDefault(match: 'review*', model: 'opus'),
        const StepConfigDefault(match: '*', model: 'sonnet'),
      ];
      final resolved = resolveStepConfig(step, defaults);
      expect(resolved.model, 'opus');
    });

    test('step with no matching pattern gets no defaults', () {
      final step = makeStep(id: 'custom-step');
      final defaults = [
        const StepConfigDefault(match: 'review*', model: 'opus'),
      ];
      final resolved = resolveStepConfig(step, defaults);
      expect(resolved.model, isNull);
    });

    test('per-step explicit model overrides matching default model', () {
      final step = makeStep(model: 'step-model');
      final defaults = [
        const StepConfigDefault(match: 'review*', model: 'default-model'),
      ];
      final resolved = resolveStepConfig(step, defaults);
      expect(resolved.model, 'step-model');
    });

    test('step null model inherits from matching default', () {
      final step = makeStep(model: null);
      final defaults = [
        const StepConfigDefault(match: 'review*', model: 'default-model'),
      ];
      final resolved = resolveStepConfig(step, defaults);
      expect(resolved.model, 'default-model');
    });

    test('per-step explicit provider overrides matching default provider', () {
      final step = makeStep(provider: 'step-provider');
      final defaults = [
        const StepConfigDefault(match: 'review*', provider: 'default-provider'),
      ];
      final resolved = resolveStepConfig(step, defaults);
      expect(resolved.provider, 'step-provider');
    });

    test('field-level precedence: step.model wins, step.provider null → default.provider used', () {
      final step = makeStep(model: 'my-model', provider: null);
      final defaults = [
        const StepConfigDefault(
          match: 'review*',
          model: 'default-model',
          provider: 'default-provider',
        ),
      ];
      final resolved = resolveStepConfig(step, defaults);
      expect(resolved.model, 'my-model');
      expect(resolved.provider, 'default-provider');
    });

    test('all fields inherited from matching default when step has none', () {
      final step = makeStep();
      final defaults = [
        const StepConfigDefault(
          match: 'review*',
          provider: 'claude',
          model: 'claude-opus-4',
          maxTokens: 8000,
          maxCostUsd: 2.0,
          maxRetries: 3,
          allowedTools: ['Read', 'Grep'],
        ),
      ];
      final resolved = resolveStepConfig(step, defaults);
      expect(resolved.provider, 'claude');
      expect(resolved.model, 'claude-opus-4');
      expect(resolved.maxTokens, 8000);
      expect(resolved.maxCostUsd, 2.0);
      expect(resolved.maxRetries, 3);
      expect(resolved.allowedTools, ['Read', 'Grep']);
    });

    test('* catch-all matches any step', () {
      final step = makeStep(id: 'any-step-name');
      final defaults = [
        const StepConfigDefault(match: '*', provider: 'catch-all-provider'),
      ];
      final resolved = resolveStepConfig(step, defaults);
      expect(resolved.provider, 'catch-all-provider');
    });
  });
}
