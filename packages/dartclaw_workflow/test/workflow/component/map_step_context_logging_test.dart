// Regression guard for Issue A (2026-04-24 e2e-plan-and-implement log):
// `MapStepContext.recordFailure` must emit a WARNING log containing the
// iteration index, task id, and failure message. Silent failures made every
// promotion problem require the 30–75-minute E2E to diagnose.
@Tags(['component'])
library;

import 'package:dartclaw_workflow/src/workflow/map_step_context.dart';
import 'package:logging/logging.dart';
import 'package:test/test.dart';

import '../invariant_observers.dart';

void main() {
  group('MapStepContext.recordFailure logging (Issue A regression guard)', () {
    late LogInvariantObserver observer;

    setUp(() {
      observer = LogInvariantObserver.capture();
      observer.start();
    });

    tearDown(() => observer.dispose());

    test('emits WARNING record including iteration index, task id, and message', () {
      final ctx = MapStepContext(collection: [1, 2, 3], maxParallel: 2, maxItems: 10);

      ctx.recordFailure(1, 'promotion failed: WorkflowGitPromotionConflict', 'task-abc123');

      observer.expectRecord(
        level: Level.WARNING,
        loggerName: 'MapStepContext',
        pattern: RegExp(r'Map iteration \[1\] failed \(task=task-abc123\): promotion failed: .*Conflict'),
      );
    });

    test('logs once per recordFailure call — every failed iteration is observable', () {
      final ctx = MapStepContext(collection: [1, 2], maxParallel: 2, maxItems: 10);

      ctx.recordFailure(0, 'first fail', 'task-0');
      ctx.recordFailure(1, 'second fail', 'task-1');

      expect(
        observer.records.where((r) => r.loggerName == 'MapStepContext'),
        hasLength(2),
        reason:
            'Each iteration failure must produce its own WARNING so operators '
            'can correlate per-iteration status.',
      );
    });

    test('includes "null" in message when task id is missing (still observable)', () {
      final ctx = MapStepContext(collection: [1], maxParallel: 1, maxItems: 10);

      ctx.recordFailure(0, 'no task id', null);

      observer.expectRecord(level: Level.WARNING, pattern: RegExp(r'Map iteration \[0\] failed \(task=null\)'));
    });

    test('recordResult does NOT emit a warning — only failures should log', () {
      final ctx = MapStepContext(collection: [1], maxParallel: 1, maxItems: 10);

      ctx.recordResult(0, {'ok': true});

      expect(observer.records.where((r) => r.loggerName == 'MapStepContext'), isEmpty);
    });
  });
}
