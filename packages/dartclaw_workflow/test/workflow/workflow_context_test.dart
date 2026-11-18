import 'package:dartclaw_workflow/dartclaw_workflow.dart';
import 'package:dartclaw_workflow/src/workflow/workflow_context_resolver.dart';
import 'package:dartclaw_workflow/src/workflow/workflow_output_contract.dart' show workflowApprovedCandidateKey;
import 'package:test/test.dart';

void main() {
  group('WorkflowContext', () {
    test('set and get context values', () {
      final ctx = WorkflowContext();
      ctx['key'] = 'value';
      expect(ctx['key'], 'value');
    });

    test('missing key returns null', () {
      final ctx = WorkflowContext();
      expect(ctx['nonexistent'], isNull);
    });

    test('resolveContextKey prefers exact keys before dotted map paths', () {
      final ctx = WorkflowContext(
        data: {
          'review.findings_count': 3,
          'project_index': {'active_plan': 'docs/specs/0.16.5/plan.md'},
        },
      );
      expect(resolveContextKey(ctx, 'review.findings_count'), 3);
      expect(resolveContextKey(ctx, 'project_index.active_plan'), 'docs/specs/0.16.5/plan.md');
      expect(resolveContextKey(ctx, 'project_index.missing'), isNull);
    });

    test('variable access', () {
      final ctx = WorkflowContext(variables: {'VAR': 'hello'});
      expect(ctx.variable('VAR'), 'hello');
      expect(ctx.variable('MISSING'), isNull);
    });

    test('variables getter returns all bindings', () {
      final ctx = WorkflowContext(variables: {'A': '1', 'B': '2'});
      expect(ctx.variables, {'A': '1', 'B': '2'});
    });

    test('data getter returns unmodifiable view', () {
      final ctx = WorkflowContext(data: {'k': 'v'});
      final data = ctx.data;
      expect(data['k'], 'v');
      expect(() => (data as dynamic)['new'] = 'x', throwsA(anything));
    });

    test('merge adds outputs to context', () {
      final ctx = WorkflowContext(data: {'a': '1'});
      ctx.merge({'b': '2', 'c': '3'});
      expect(ctx['a'], '1');
      expect(ctx['b'], '2');
      expect(ctx['c'], '3');
    });

    for (final key in [workflowExecutionSurfaceHoldKey, workflowApprovedCandidateKey]) {
      test('step merge refuses host marker $key atomically', () {
        final ctx = WorkflowContext(data: {'ordinary': 'before'});
        expect(
          () => ctx.merge({
            'ordinary': 'after',
            key: ['forged'],
          }),
          throwsA(anything),
        );
        expect(ctx.data, {'ordinary': 'before'});
      });
      test('variable $key cannot shadow host data', () {
        final ctx = WorkflowContext(variables: {key: 'forged'});
        expect(ctx[key], isNull);
      });
    }
    test('ordinary private outputs remain supported', () {
      final ctx = WorkflowContext();
      ctx.merge({'_ordinary': 'value'});
      expect(ctx['_ordinary'], 'value');
    });

    test('merge overwrites existing keys', () {
      final ctx = WorkflowContext(data: {'key': 'old'});
      ctx.merge({'key': 'new'});
      expect(ctx['key'], 'new');
    });

    test('approval reads only the host candidate from the run snapshot', () {
      expect(
        workflowApprovedCandidate({
          'variables': {workflowApprovedCandidateKey: 'reviewed-candidate'},
          'data': {
            '_workflow.git.approved_branches': ['story'],
            workflowApprovedCandidateKey: 'reviewed-candidate',
          },
        }),
        isNull,
      );
      final context = WorkflowContext(data: {workflowApprovedCandidateKey: 'ordinary-output'});
      expect(
        workflowApprovedCandidate({...context.toJson(), workflowApprovedCandidateKey: 'reviewed-candidate'}),
        'reviewed-candidate',
      );
      expect(workflowApprovedCandidate({workflowApprovedCandidateKey: ''}), isNull);
      expect(
        workflowApprovedCandidate({
          workflowApprovedCandidateKey: ['reviewed-candidate'],
        }),
        isNull,
      );
    });

    test('legacy workflow data cannot create a pending host hold', () {
      expect(
        WorkflowExecutionSurfaceHold.read({
          'data': {
            workflowExecutionSurfaceHoldKey: {
              'branch': 'story',
              'paths': ['.mcp.json'],
              'publish': false,
              'candidate': 'reviewed-candidate',
            },
          },
        }),
        isNull,
      );
    });

    test('a promotion hold preserves both worktree locations for review', () {
      final hold = WorkflowExecutionSurfaceHold.fromPromotion(
        'story',
        const WorkflowGitPromotionHeld(
          ['.mcp.json'],
          candidate: 'candidate',
          destination: 'integration',
          worktreePath: '/repo/story',
          destinationWorktreePath: '/repo/integration',
        ),
      );
      final restored = WorkflowExecutionSurfaceHold.read({workflowExecutionSurfaceHoldKey: hold.toJson()})!;

      expect(restored.worktreePath, '/repo/story');
      expect(restored.destinationWorktreePath, '/repo/integration');
      expect(restored.message, contains('Source worktree /repo/story.'));
      expect(restored.message, contains('Destination worktree /repo/integration.'));
      expect(restored.message, contains('.mcp.json'));
    });

    test('loop iteration tracking', () {
      final ctx = WorkflowContext();
      expect(ctx.loopIteration('loop-1'), isNull);
      ctx.setLoopIteration('loop-1', 3);
      expect(ctx.loopIteration('loop-1'), 3);
    });

    test('multiple loops tracked independently', () {
      final ctx = WorkflowContext();
      ctx.setLoopIteration('loop-1', 1);
      ctx.setLoopIteration('loop-2', 5);
      expect(ctx.loopIteration('loop-1'), 1);
      expect(ctx.loopIteration('loop-2'), 5);
    });

    test('toJson/fromJson round-trip', () {
      final ctx = WorkflowContext(data: {'key': 'value', 'num': 42}, variables: {'VAR': 'foo'});
      ctx.setLoopIteration('loop-1', 2);

      final json = ctx.toJson();
      final restored = WorkflowContext.fromJson(json);

      expect(restored['key'], 'value');
      expect(restored['num'], 42);
      expect(restored.variable('VAR'), 'foo');
      expect(restored.loopIteration('loop-1'), 2);
    });

    test('system variables survive the round-trip', () {
      final ctx = WorkflowContext(systemVariables: {'unproduced.review': 'review.findings_count'});

      expect(WorkflowContext.fromJson(ctx.toJson()).systemVariable('unproduced.review'), 'review.findings_count');
    });

    test('a context persisted before systemVariables existed still loads', () {
      final restored = WorkflowContext.fromJson({
        'data': {'key': 'value'},
        'variables': {'VAR': 'foo'},
      });

      expect(restored['key'], 'value');
      expect(restored.systemVariables, isEmpty);
    });

    test('variables are unmodifiable after construction', () {
      final ctx = WorkflowContext(variables: {'VAR': 'val'});
      expect(() => (ctx.variables as dynamic)['NEW'] = 'x', throwsA(anything));
    });
  });
}
