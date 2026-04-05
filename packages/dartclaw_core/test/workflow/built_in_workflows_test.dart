import 'package:dartclaw_core/dartclaw_core.dart'
    show
        WorkflowDefinitionParser,
        WorkflowDefinitionValidator,
        builtInWorkflowYaml;
import 'package:test/test.dart';

void main() {
  final parser = WorkflowDefinitionParser();
  final validator = WorkflowDefinitionValidator();

  group('builtInWorkflowYaml map', () {
    test('contains exactly 5 entries', () {
      expect(builtInWorkflowYaml, hasLength(5));
    });

    test('contains expected workflow names as keys', () {
      expect(
        builtInWorkflowYaml.keys,
        containsAll([
          'spec-and-implement',
          'research-and-evaluate',
          'fix-bug',
          'refactor',
          'review-and-remediate',
        ]),
      );
    });
  });

  group('each built-in workflow parses and validates', () {
    for (final entry in builtInWorkflowYaml.entries) {
      test('${entry.key}: parses without error', () {
        expect(
          () => parser.parse(entry.value, sourcePath: 'built-in:${entry.key}'),
          returnsNormally,
        );
      });

      test('${entry.key}: validates without errors', () {
        final definition = parser.parse(entry.value, sourcePath: 'built-in:${entry.key}');
        final errors = validator.validate(definition);
        expect(errors, isEmpty, reason: errors.join('; '));
      });

      test('${entry.key}: definition.name matches map key', () {
        final definition = parser.parse(entry.value, sourcePath: 'built-in:${entry.key}');
        expect(definition.name, equals(entry.key));
      });

      test('${entry.key}: description is non-empty', () {
        final definition = parser.parse(entry.value, sourcePath: 'built-in:${entry.key}');
        expect(definition.description, isNotEmpty);
      });
    }
  });

  group('spec-and-implement', () {
    late final definition = parser.parse(
      builtInWorkflowYaml['spec-and-implement']!,
      sourcePath: 'built-in:spec-and-implement',
    );

    test('has 6 steps', () {
      expect(definition.steps, hasLength(6));
    });

    test('has expected step IDs', () {
      final ids = definition.steps.map((s) => s.id).toList();
      expect(ids, equals(['research', 'spec', 'implement', 'code-review', 'gap-analysis', 'remediate']));
    });

    test('declares FEATURE (required) and PROJECT (optional) variables', () {
      expect(definition.variables['FEATURE']?.required, isTrue);
      expect(definition.variables['PROJECT']?.required, isFalse);
    });

    test('research step has provider: claude', () {
      final research = definition.steps.firstWhere((s) => s.id == 'research');
      expect(research.provider, equals('claude'));
    });

    test('spec step has provider: claude', () {
      final spec = definition.steps.firstWhere((s) => s.id == 'spec');
      expect(spec.provider, equals('claude'));
    });

    test('implement step has review: always', () {
      final implement = definition.steps.firstWhere((s) => s.id == 'implement');
      expect(implement.review.name, equals('always'));
    });

    test('remediate step has review: always', () {
      final remediate = definition.steps.firstWhere((s) => s.id == 'remediate');
      expect(remediate.review.name, equals('always'));
    });

    test('code-review step has gate on implement.status', () {
      final codeReview = definition.steps.firstWhere((s) => s.id == 'code-review');
      expect(codeReview.gate, contains('implement.status'));
    });

    test('remediate step has gate on gap-analysis.status', () {
      final remediate = definition.steps.firstWhere((s) => s.id == 'remediate');
      expect(remediate.gate, contains('gap-analysis.status'));
    });

    test('spec step outputs acceptance_criteria', () {
      final spec = definition.steps.firstWhere((s) => s.id == 'spec');
      expect(spec.contextOutputs, contains('acceptance_criteria'));
    });

    test('code-review step inputs acceptance_criteria', () {
      final codeReview = definition.steps.firstWhere((s) => s.id == 'code-review');
      expect(codeReview.contextInputs, contains('acceptance_criteria'));
    });

    test('gap-analysis step inputs acceptance_criteria', () {
      final gapAnalysis = definition.steps.firstWhere((s) => s.id == 'gap-analysis');
      expect(gapAnalysis.contextInputs, contains('acceptance_criteria'));
    });

    test('research prompt includes planning granularity guidance', () {
      final research = definition.steps.firstWhere((s) => s.id == 'research');
      expect(research.prompt, contains('architecture'));
    });

    test('code-review prompt includes evaluator anti-leniency text', () {
      final codeReview = definition.steps.firstWhere((s) => s.id == 'code-review');
      expect(codeReview.prompt, contains('independent evaluator'));
      expect(codeReview.prompt, contains('NOT the agent'));
    });

    test('gap-analysis prompt includes evaluator anti-leniency text', () {
      final gapAnalysis = definition.steps.firstWhere((s) => s.id == 'gap-analysis');
      expect(gapAnalysis.prompt, contains('independent evaluator'));
    });
  });

  group('research-and-evaluate', () {
    late final definition = parser.parse(
      builtInWorkflowYaml['research-and-evaluate']!,
      sourcePath: 'built-in:research-and-evaluate',
    );

    test('has 4 steps', () {
      expect(definition.steps, hasLength(4));
    });

    test('has expected step IDs', () {
      final ids = definition.steps.map((s) => s.id).toList();
      expect(ids, equals(['research', 'evaluate', 'synthesize', 'recommendation']));
    });

    test('declares QUESTION (required) and OPTIONS (optional with default)', () {
      expect(definition.variables['QUESTION']?.required, isTrue);
      expect(definition.variables['OPTIONS']?.required, isFalse);
      expect(definition.variables['OPTIONS']?.defaultValue, equals(''));
    });

    test('research step has provider: claude', () {
      final research = definition.steps.firstWhere((s) => s.id == 'research');
      expect(research.provider, equals('claude'));
    });
  });

  group('fix-bug', () {
    late final definition = parser.parse(
      builtInWorkflowYaml['fix-bug']!,
      sourcePath: 'built-in:fix-bug',
    );

    test('has 5 steps', () {
      expect(definition.steps, hasLength(5));
    });

    test('has expected step IDs', () {
      final ids = definition.steps.map((s) => s.id).toList();
      expect(ids, equals(['reproduce', 'diagnose', 'fix', 'test', 'verify']));
    });

    test('declares BUG_DESCRIPTION (required) and PROJECT (optional)', () {
      expect(definition.variables['BUG_DESCRIPTION']?.required, isTrue);
      expect(definition.variables['PROJECT']?.required, isFalse);
    });

    test('fix step has review: always and gate on diagnose', () {
      final fix = definition.steps.firstWhere((s) => s.id == 'fix');
      expect(fix.review.name, equals('always'));
      expect(fix.gate, contains('diagnose.status'));
    });

    test('test step has gate on fix', () {
      final test_ = definition.steps.firstWhere((s) => s.id == 'test');
      expect(test_.gate, contains('fix.status'));
    });
  });

  group('refactor', () {
    late final definition = parser.parse(
      builtInWorkflowYaml['refactor']!,
      sourcePath: 'built-in:refactor',
    );

    test('has 4 steps', () {
      expect(definition.steps, hasLength(4));
    });

    test('has expected step IDs', () {
      final ids = definition.steps.map((s) => s.id).toList();
      expect(ids, equals(['analyze', 'plan', 'execute', 'verify']));
    });

    test('declares TARGET (required) and PROJECT (optional)', () {
      expect(definition.variables['TARGET']?.required, isTrue);
      expect(definition.variables['PROJECT']?.required, isFalse);
    });

    test('execute step has review: always', () {
      final execute = definition.steps.firstWhere((s) => s.id == 'execute');
      expect(execute.review.name, equals('always'));
    });

    test('verify step has gate on execute', () {
      final verify = definition.steps.firstWhere((s) => s.id == 'verify');
      expect(verify.gate, contains('execute.status'));
    });
  });

  group('review-and-remediate', () {
    late final definition = parser.parse(
      builtInWorkflowYaml['review-and-remediate']!,
      sourcePath: 'built-in:review-and-remediate',
    );

    test('has 4 steps', () {
      expect(definition.steps, hasLength(4));
    });

    test('has expected step IDs', () {
      final ids = definition.steps.map((s) => s.id).toList();
      expect(ids, equals(['review', 'gap-analysis', 'remediate', 're-review']));
    });

    test('declares TARGET (required) and PROJECT (optional)', () {
      expect(definition.variables['TARGET']?.required, isTrue);
      expect(definition.variables['PROJECT']?.required, isFalse);
    });

    test('has 1 loop with id fix-loop', () {
      expect(definition.loops, hasLength(1));
      expect(definition.loops.first.id, equals('fix-loop'));
    });

    test('loop references steps [gap-analysis, remediate, re-review]', () {
      final loop = definition.loops.first;
      expect(loop.steps, equals(['gap-analysis', 'remediate', 're-review']));
    });

    test('loop has maxIterations: 3', () {
      expect(definition.loops.first.maxIterations, equals(3));
    });

    test('loop has exitGate referencing re-review.findings_count', () {
      expect(definition.loops.first.exitGate, contains('re-review.findings_count'));
    });

    test('remediate step has review: always', () {
      final remediate = definition.steps.firstWhere((s) => s.id == 'remediate');
      expect(remediate.review.name, equals('always'));
    });
  });

  group('prompts use only {{variable}} or {{context.key}} syntax', () {
    // Handlebars conditionals ({{#if}}, {{#each}}) must not appear.
    final handlebarsPattern = RegExp(r'\{\{#');

    for (final entry in builtInWorkflowYaml.entries) {
      test('${entry.key}: no Handlebars conditionals in prompts', () {
        final definition = parser.parse(entry.value, sourcePath: 'built-in:${entry.key}');
        for (final step in definition.steps) {
          expect(
            handlebarsPattern.hasMatch(step.prompt),
            isFalse,
            reason: 'Step "${step.id}" prompt contains Handlebars conditional syntax',
          );
        }
      });
    }
  });
}
