import 'package:dartclaw_workflow/dartclaw_workflow.dart';
import 'package:dartclaw_workflow/src/workflow/workflow_template_engine.dart' show WorkflowTemplateEngine;
import 'package:test/test.dart';

import 'workflow_validator_test_support.dart';

void main() {
  late WorkflowDefinitionValidator validator;

  setUp(() {
    validator = WorkflowDefinitionValidator();
  });

  group('variable references', () {
    test('undeclared variable reference in prompt produces invalidReference error', () {
      final def = buildDef(steps: [step(prompt: 'Do {{UNDECLARED}}')]);
      final errors = validator.validate(def).errors;
      expect(hasError(errors, type: ValidationErrorType.invalidReference), true);
    });

    test('declared variable reference in prompt produces no error', () {
      final def = buildDef(
        variables: {'VAR': const WorkflowVariable(description: 'v')},
        steps: [step(prompt: 'Do {{VAR}}')],
      );
      expect(validator.validate(def).errors, isEmpty);
    });

    test('context reference in prompt does not trigger variable reference error', () {
      final def = buildDef(steps: [step(prompt: 'Use {{context.key}}')]);
      final errors = validator.validate(def).errors;
      expect(hasError(errors, type: ValidationErrorType.invalidReference), false);
    });

    test('known workflow system reference validates', () {
      final def = buildDef(steps: [step(prompt: 'Use {{workflow.runtime_artifacts_dir}}')]);
      expect(validator.validate(def).errors, isEmpty);
    });

    test('unknown workflow system reference names key and known set', () {
      final def = buildDef(steps: [step(prompt: 'Use {{workflow.frobnozzle}}')]);
      final errors = validator.validate(def).errors;

      expect(errors, hasLength(1));
      expect(errors.single.type, ValidationErrorType.invalidReference);
      expect(errors.single.message, contains('workflow.frobnozzle'));
      expect(errors.single.message, contains('workflow.runtime_artifacts_dir'));
    });

    test('adding a workflow system key to the inventory makes validation succeed', () {
      final customValidator = WorkflowDefinitionValidator(
        templateEngine: WorkflowTemplateEngine(
          knownWorkflowSystemVariableKeys: {...WorkflowTemplateEngine.knownWorkflowSystemVariables, 'workflow.new_key'},
        ),
      );
      final def = buildDef(steps: [step(prompt: 'Use {{workflow.new_key}}')]);

      expect(customValidator.validate(def).errors, isEmpty);
    });

    test('unknown workflow system reference in bash workdir is rejected', () {
      final def = buildDef(
        steps: const [
          WorkflowStep(
            id: 's1',
            name: 'Shell',
            taskType: WorkflowTaskType.bash,
            prompts: ['pwd'],
            workdir: '{{workflow.frobnozzle}}',
          ),
        ],
      );
      final errors = validator.validate(def).errors;

      expect(errors, hasLength(1));
      expect(errors.single.message, contains('Step "s1" workdir'));
      expect(errors.single.message, contains('workflow.frobnozzle'));
    });

    test('unknown workflow system reference in artifact commit template is rejected', () {
      final def = buildDef(
        gitStrategy: const WorkflowGitStrategy(
          artifacts: WorkflowGitArtifactsStrategy(commitMessage: 'commit {{workflow.frobnozzle}}'),
        ),
      );
      final errors = validator.validate(def).errors;

      expect(errors, hasLength(1));
      expect(errors.single.message, contains('gitStrategy.artifacts.commitMessage'));
      expect(errors.single.message, contains('workflow.frobnozzle'));
    });

    test('unknown workflow system reference in external artifact mount is rejected', () {
      final def = buildDef(
        gitStrategy: const WorkflowGitStrategy(
          worktree: WorkflowGitWorktreeStrategy(
            externalArtifactMount: WorkflowGitExternalArtifactMount(
              fromProject: '{{PROJECT}}',
              source: '{{workflow.frobnozzle}}',
            ),
          ),
        ),
      );
      final errors = validator.validate(def).errors;

      expect(errors, hasLength(1));
      expect(errors.single.message, contains('gitStrategy.worktree.externalArtifactMount.source'));
      expect(errors.single.message, contains('workflow.frobnozzle'));
    });

    test('workflowVariables entry missing from variables block produces invalidReference error', () {
      final def = buildDef(
        steps: [
          const WorkflowStep(id: 's1', name: 'S', prompts: ['p'], workflowVariables: ['UNDECLARED']),
        ],
      );
      final errors = validator.validate(def).errors;
      expect(hasError(errors, type: ValidationErrorType.invalidReference, stepId: 's1'), true);
    });

    test('workflowVariables entry declared in variables block produces no error', () {
      final def = buildDef(
        variables: {'REQUIREMENTS': const WorkflowVariable(description: 'r')},
        steps: [
          const WorkflowStep(id: 's1', name: 'S', prompts: ['p'], workflowVariables: ['REQUIREMENTS']),
        ],
      );
      expect(validator.validate(def).errors, isEmpty);
    });
  });

  group('loop references', () {
    test('loop referencing non-existent step produces invalidReference error', () {
      final def = buildDef(
        steps: [step(id: 's1')],
        loops: [
          const WorkflowLoop(id: 'lp', steps: ['nonexistent'], maxIterations: 3, exitGate: ''),
        ],
      );
      final errors = validator.validate(def).errors;
      expect(hasError(errors, type: ValidationErrorType.invalidReference), true);
    });

    test('loop with maxIterations 0 produces missingMaxIterations error', () {
      final def = buildDef(
        steps: [step(id: 's1')],
        loops: [
          const WorkflowLoop(id: 'lp', steps: ['s1'], maxIterations: 0, exitGate: ''),
        ],
      );
      final errors = validator.validate(def).errors;
      expect(hasError(errors, type: ValidationErrorType.missingMaxIterations), true);
    });

    test('loop with negative maxIterations produces missingMaxIterations error', () {
      final def = buildDef(
        steps: [step(id: 's1')],
        loops: [
          const WorkflowLoop(id: 'lp', steps: ['s1'], maxIterations: -1, exitGate: ''),
        ],
      );
      final errors = validator.validate(def).errors;
      expect(hasError(errors, type: ValidationErrorType.missingMaxIterations), true);
    });

    test('step appearing in multiple loops produces loopOverlap error', () {
      final def = buildDef(
        steps: [
          step(id: 's1'),
          step(id: 's2', name: 'S2', prompt: 'p'),
        ],
        loops: [
          const WorkflowLoop(id: 'lp1', steps: ['s1'], maxIterations: 3, exitGate: ''),
          const WorkflowLoop(id: 'lp2', steps: ['s1', 's2'], maxIterations: 3, exitGate: ''),
        ],
      );
      final errors = validator.validate(def).errors;
      expect(hasError(errors, type: ValidationErrorType.loopOverlap), true);
    });
  });
}
