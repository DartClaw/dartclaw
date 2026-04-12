import 'package:dartclaw_workflow/dartclaw_workflow.dart';
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

    test('merge overwrites existing keys', () {
      final ctx = WorkflowContext(data: {'key': 'old'});
      ctx.merge({'key': 'new'});
      expect(ctx['key'], 'new');
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

    test('variables are unmodifiable after construction', () {
      final ctx = WorkflowContext(variables: {'VAR': 'val'});
      expect(() => (ctx.variables as dynamic)['NEW'] = 'x', throwsA(anything));
    });
  });
}
