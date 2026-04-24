import 'package:dartclaw_models/dartclaw_models.dart';
import 'package:dartclaw_workflow/src/workflow/step_config_policy.dart';
import 'package:dartclaw_workflow/src/workflow/step_config_resolver.dart';
import 'package:dartclaw_workflow/src/workflow/workflow_context.dart';
import 'package:test/test.dart';

void main() {
  group('step_config_policy', () {
    const roleDefaults = WorkflowRoleDefaults();

    test('resolveWorktreeModeForScope uses auto per-map-item for parallel map scopes', () {
      final definition = WorkflowDefinition(
        name: 'wf',
        description: 'test',
        gitStrategy: const WorkflowGitStrategy(worktree: WorkflowGitWorktreeStrategy(mode: 'auto')),
        steps: const [
          WorkflowStep(id: 'map', name: 'Map', prompts: ['p'], mapOver: 'items', maxParallel: 2),
        ],
      );

      expect(
        resolveWorktreeModeForScope(
          definition,
          definition.steps.single,
          WorkflowContext(data: {'items': []}),
          roleDefaults: roleDefaults,
        ),
        equals('per-map-item'),
      );
    });

    test('effectivePromotion defaults merge for per-task and none for inline', () {
      expect(effectivePromotion(null, resolvedWorktreeMode: 'per-task'), equals('merge'));
      expect(effectivePromotion(null, resolvedWorktreeMode: 'inline'), equals('none'));
    });

    test('stepNeedsWorktree is true for per-map-item and false for inherited read-only project steps', () {
      const definition = WorkflowDefinition(name: 'wf', description: 'test', project: 'proj', steps: []);
      const resolved = ResolvedStepConfig();

      expect(
        stepNeedsWorktree(
          definition,
          const WorkflowStep(id: 's', name: 'S', prompts: ['p']),
          resolved,
          resolvedWorktreeMode: 'per-map-item',
        ),
        isTrue,
      );
      expect(
        stepNeedsWorktree(
          definition,
          const WorkflowStep(id: 'fe', name: 'Foreach', mapOver: 'items', foreachSteps: ['child']),
          resolved,
          resolvedWorktreeMode: 'inline',
        ),
        isFalse,
      );
      expect(
        stepNeedsWorktree(
          definition,
          const WorkflowStep(id: 'review', name: 'Review', contextInputs: ['project_index']),
          const ResolvedStepConfig(allowedTools: ['file_read']),
          resolvedWorktreeMode: 'inline',
        ),
        isFalse,
      );
    });

    test('stepIsReadOnly follows allowed tools and legacy semantic defaults', () {
      expect(stepIsReadOnly(const WorkflowStep(id: 's', name: 'S'), const ResolvedStepConfig()), isTrue);
      expect(
        stepIsReadOnly(const WorkflowStep(id: 's', name: 'S'), const ResolvedStepConfig(allowedTools: ['file_read'])),
        isTrue,
      );
      expect(
        stepIsReadOnly(const WorkflowStep(id: 's', name: 'S'), const ResolvedStepConfig(allowedTools: ['file_write'])),
        isFalse,
      );
    });

    test('stepEmitsArtifactPath detects path outputs', () {
      expect(
        stepEmitsArtifactPath(
          const WorkflowStep(
            id: 's',
            name: 'S',
            outputs: {'plan': OutputConfig(format: OutputFormat.path)},
          ),
        ),
        isTrue,
      );
    });

    test('shouldBindWorkflowProject binds project-index consumers and mutating custom steps', () {
      const definition = WorkflowDefinition(name: 'wf', description: 'test', project: 'proj', steps: []);

      expect(
        shouldBindWorkflowProject(
          definition,
          const WorkflowStep(id: 's', name: 'S', type: 'custom', typeAuthored: true),
          const ResolvedStepConfig(),
        ),
        isTrue,
      );
      expect(
        shouldBindWorkflowProject(
          definition,
          const WorkflowStep(id: 'review', name: 'Review', contextInputs: ['project_index']),
          const ResolvedStepConfig(allowedTools: ['file_read']),
        ),
        isTrue,
      );
    });

    test('stepTouchesProjectBranch excludes read-only project-bound steps', () {
      final definition = WorkflowDefinition(
        name: 'wf',
        description: 'test',
        project: 'proj',
        steps: const [
          WorkflowStep(id: 'readonly', name: 'Readonly', type: 'research'),
          WorkflowStep(id: 'write', name: 'Write', type: 'custom', typeAuthored: true),
        ],
      );

      expect(stepTouchesProjectBranch(definition, definition.steps.first, roleDefaults: roleDefaults), isFalse);
      expect(stepTouchesProjectBranch(definition, definition.steps.last, roleDefaults: roleDefaults), isTrue);
    });
  });
}
