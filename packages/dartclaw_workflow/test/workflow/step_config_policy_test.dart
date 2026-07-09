import 'package:dartclaw_workflow/dartclaw_workflow.dart' show WorkflowGitWorktreeMode, WorkflowTaskType;
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show
        OutputConfig,
        OutputFormat,
        WorkflowDefinition,
        WorkflowGitStrategy,
        WorkflowGitWorktreeStrategy,
        WorkflowRoleDefaults,
        WorkflowStep;
import 'package:dartclaw_workflow/src/workflow/step_config_policy.dart';
import 'package:dartclaw_workflow/src/workflow/step_config_resolver.dart';
import 'package:dartclaw_workflow/src/workflow/workflow_context.dart';
import 'package:dartclaw_workflow/src/workflow/workflow_template_engine.dart';
import 'package:test/test.dart';

void main() {
  group('step_config_policy', () {
    const roleDefaults = WorkflowRoleDefaults();

    test('resolveWorktreeModeForScope uses auto per-map-item for parallel map scopes', () {
      final definition = WorkflowDefinition(
        name: 'wf',
        description: 'test',
        gitStrategy: const WorkflowGitStrategy(
          worktree: WorkflowGitWorktreeStrategy(mode: WorkflowGitWorktreeMode.auto),
        ),
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

    test('resolveWorktreeMode treats a null strategy as auto (parallel map → per-map-item, not shared inline)', () {
      // Regression: a definition with no gitStrategy block must still isolate
      // parallel map/foreach iterations. Collapsing null to a literal `inline`
      // left concurrent iterations sharing — and clobbering — the live checkout.
      expect(resolveWorktreeMode(null, maxParallel: 2, isMap: true), equals('per-map-item'));
      expect(resolveWorktreeMode(null, maxParallel: null, isMap: true), equals('per-map-item'));
      // Serial and non-map null-strategy scopes stay inline (unchanged).
      expect(resolveWorktreeMode(null, maxParallel: 1, isMap: true), equals('inline'));
      expect(resolveWorktreeMode(null, maxParallel: null, isMap: false), equals('inline'));
      // Identical to an explicit `{ worktree: auto }` strategy.
      const auto = WorkflowGitStrategy(worktree: WorkflowGitWorktreeStrategy(mode: WorkflowGitWorktreeMode.auto));
      expect(
        resolveWorktreeMode(auto, maxParallel: 2, isMap: true),
        equals(resolveWorktreeMode(null, maxParallel: 2, isMap: true)),
      );
    });

    test('requiresPerMapItemGitIsolation is true for a strategy-less parallel map', () {
      // The bootstrap must provision per-item worktrees for the strategy-less
      // parallel map that now resolves to per-map-item, or the isolated
      // worktrees the dispatcher creates would be ungit-initialized.
      final definition = WorkflowDefinition(
        name: 'wf',
        description: 'test',
        steps: const [
          WorkflowStep(id: 'map', name: 'Map', prompts: ['p'], mapOver: 'items', maxParallel: 2),
        ],
      );
      expect(
        requiresPerMapItemGitIsolation(
          definition,
          WorkflowContext(data: {'items': []}),
          templateEngine: WorkflowTemplateEngine(),
        ),
        isTrue,
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
          const WorkflowStep(id: 'review', name: 'Review', inputs: ['project_index']),
          const ResolvedStepConfig(allowedTools: ['file_read']),
          resolvedWorktreeMode: 'inline',
        ),
        isFalse,
      );
    });

    test('stepIsReadOnly follows allowed tools only', () {
      expect(stepIsReadOnly(const WorkflowStep(id: 's', name: 'S'), const ResolvedStepConfig()), isFalse);
      expect(
        stepIsReadOnly(const WorkflowStep(id: 's', name: 'S'), const ResolvedStepConfig(allowedTools: ['file_read'])),
        isTrue,
      );
      expect(
        stepIsReadOnly(const WorkflowStep(id: 's', name: 'S'), const ResolvedStepConfig(allowedTools: ['file_write'])),
        isFalse,
      );
      expect(
        stepIsReadOnly(const WorkflowStep(id: 's', name: 'S'), const ResolvedStepConfig(allowedTools: ['file_edit'])),
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

    test('stepNeedsWorktree binds read-only path outputs for inline metadata', () {
      const definition = WorkflowDefinition(name: 'wf', description: 'test', project: 'proj', steps: []);

      expect(
        stepNeedsWorktree(
          definition,
          const WorkflowStep(
            id: 'detect-spec-input',
            name: 'Detect Spec Input',
            skill: 'dartclaw-discover-andthen-spec',
            allowedTools: ['shell', 'file_read'],
            outputs: {'spec_path': OutputConfig(format: OutputFormat.path)},
          ),
          const ResolvedStepConfig(allowedTools: ['shell', 'file_read']),
          resolvedWorktreeMode: 'inline',
        ),
        isTrue,
      );
      expect(
        stepNeedsWorktree(
          definition,
          const WorkflowStep(
            id: 'custom-discover',
            name: 'Custom Discover',
            allowedTools: ['shell', 'file_read'],
            outputs: {'prd': OutputConfig(format: OutputFormat.path)},
          ),
          const ResolvedStepConfig(allowedTools: ['shell', 'file_read']),
          resolvedWorktreeMode: 'inline',
        ),
        isTrue,
      );
      expect(
        stepNeedsWorktree(
          definition,
          const WorkflowStep(
            id: 'mixed-discover',
            name: 'Mixed Discover',
            allowedTools: ['shell', 'file_read'],
            outputs: {
              'project_index': OutputConfig(format: OutputFormat.json),
              'prd': OutputConfig(format: OutputFormat.path),
            },
          ),
          const ResolvedStepConfig(allowedTools: ['shell', 'file_read']),
          resolvedWorktreeMode: 'inline',
        ),
        isTrue,
      );
      expect(
        stepNeedsWorktree(
          definition,
          const WorkflowStep(
            id: 'default-output-discover',
            name: 'Default Output Discover',
            allowedTools: ['shell', 'file_read'],
          ),
          const ResolvedStepConfig(allowedTools: ['shell', 'file_read']),
          resolvedWorktreeMode: 'inline',
          effectiveOutputs: {'prd': const OutputConfig(format: OutputFormat.path)},
        ),
        isTrue,
      );
    });

    test('shouldBindWorkflowProject ignores retired project_index consumers and binds mutating agent steps', () {
      const definition = WorkflowDefinition(name: 'wf', description: 'test', project: 'proj', steps: []);

      expect(
        shouldBindWorkflowProject(definition, const WorkflowStep(id: 's', name: 'S'), const ResolvedStepConfig()),
        isTrue,
      );
      expect(
        shouldBindWorkflowProject(
          definition,
          const WorkflowStep(id: 'review', name: 'Review', inputs: ['project_index']),
          const ResolvedStepConfig(allowedTools: ['file_read']),
        ),
        isFalse,
      );
      expect(
        shouldBindWorkflowProject(
          definition,
          const WorkflowStep(id: 'edit', name: 'Edit'),
          const ResolvedStepConfig(allowedTools: ['file_read', 'file_edit']),
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
          WorkflowStep(id: 'readonly', name: 'Readonly', taskType: WorkflowTaskType.agent, allowedTools: ['file_read']),
          WorkflowStep(id: 'write', name: 'Write'),
        ],
      );

      expect(stepTouchesProjectBranch(definition, definition.steps.first, roleDefaults: roleDefaults), isFalse);
      expect(stepTouchesProjectBranch(definition, definition.steps.last, roleDefaults: roleDefaults), isTrue);
    });

    test('read-only tool policy does not drive project binding', () {
      const definition = WorkflowDefinition(name: 'wf', description: 'test', project: 'proj', steps: []);

      expect(
        shouldBindWorkflowProject(
          definition,
          const WorkflowStep(id: 'analysis', name: 'Analysis', taskType: WorkflowTaskType.agent),
          const ResolvedStepConfig(allowedTools: ['file_read']),
        ),
        isFalse,
        reason: 'agent step with only file_read should not bind the project',
      );

      expect(
        shouldBindWorkflowProject(
          definition,
          const WorkflowStep(id: 'research', name: 'Research', taskType: WorkflowTaskType.agent),
          const ResolvedStepConfig(allowedTools: ['file_read']),
        ),
        isFalse,
        reason: 'agent step with only file_read should not bind the project',
      );
    });

    test('stepIsReadOnly opts out when allowedTools includes file_write', () {
      expect(
        stepIsReadOnly(
          const WorkflowStep(id: 'w', name: 'Writing', taskType: WorkflowTaskType.agent),
          const ResolvedStepConfig(allowedTools: ['file_write']),
        ),
        isFalse,
        reason: 'type: writing + allowedTools: [file_write] should NOT be read-only',
      );

      expect(
        stepIsReadOnly(
          const WorkflowStep(id: 'a', name: 'Analysis', taskType: WorkflowTaskType.agent),
          const ResolvedStepConfig(allowedTools: ['file_write', 'file_read']),
        ),
        isFalse,
        reason: 'type: analysis + allowedTools: [file_write, file_read] should NOT be read-only',
      );

      expect(
        stepIsReadOnly(
          const WorkflowStep(id: 'a2', name: 'Analysis2', taskType: WorkflowTaskType.agent),
          const ResolvedStepConfig(),
        ),
        isFalse,
        reason: 'removed semantic types no longer imply read-only mode',
      );
    });
  });
}
