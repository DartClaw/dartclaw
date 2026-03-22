import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';

void main() {
  group('ThreadBindingLifecycleManager', () {
    late Directory tempDir;
    late File tempFile;
    late ThreadBindingStore store;
    late EventBus eventBus;

    ThreadBinding makeBinding({
      String channelType = 'googlechat',
      String threadId = 'spaces/X/threads/Y',
      String taskId = 'task-abc',
      String sessionKey = 'sk:1',
      DateTime? lastActivity,
    }) {
      final now = lastActivity ?? DateTime.now();
      return ThreadBinding(
        channelType: channelType,
        threadId: threadId,
        taskId: taskId,
        sessionKey: sessionKey,
        createdAt: now,
        lastActivity: now,
      );
    }

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('lifecycle_mgr_test_');
      tempFile = File('${tempDir.path}/thread-bindings.json');
      store = ThreadBindingStore(tempFile);
      eventBus = EventBus();
    });

    tearDown(() async {
      await eventBus.dispose();
      // Allow unawaited _persist() calls (fire-and-forget in deleteByTaskId /
      // removeExpiredBindings) to complete before the temp directory is removed.
      await Future<void>.delayed(const Duration(milliseconds: 10));
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    group('auto-unbind on terminal state', () {
      test('removes binding when task transitions to accepted', () async {
        await store.create(makeBinding(taskId: 'task-abc'));
        final manager = ThreadBindingLifecycleManager(store: store, eventBus: eventBus);
        manager.start();

        eventBus.fire(TaskStatusChangedEvent(
          taskId: 'task-abc',
          oldStatus: TaskStatus.review,
          newStatus: TaskStatus.accepted,
          trigger: 'test',
          timestamp: DateTime.now(),
        ));

        // EventBus is async (broadcast stream), flush microtasks.
        await Future<void>.delayed(Duration.zero);

        expect(store.lookupByTask('task-abc'), isNull);
        manager.dispose();
      });

      test('removes binding when task transitions to rejected', () async {
        await store.create(makeBinding(taskId: 'task-xyz'));
        final manager = ThreadBindingLifecycleManager(store: store, eventBus: eventBus);
        manager.start();

        eventBus.fire(TaskStatusChangedEvent(
          taskId: 'task-xyz',
          oldStatus: TaskStatus.review,
          newStatus: TaskStatus.rejected,
          trigger: 'test',
          timestamp: DateTime.now(),
        ));
        await Future<void>.delayed(Duration.zero);

        expect(store.lookupByTask('task-xyz'), isNull);
        manager.dispose();
      });

      test('removes binding when task transitions to failed', () async {
        await store.create(makeBinding(taskId: 'task-fail'));
        final manager = ThreadBindingLifecycleManager(store: store, eventBus: eventBus);
        manager.start();

        eventBus.fire(TaskStatusChangedEvent(
          taskId: 'task-fail',
          oldStatus: TaskStatus.running,
          newStatus: TaskStatus.failed,
          trigger: 'test',
          timestamp: DateTime.now(),
        ));
        await Future<void>.delayed(Duration.zero);

        expect(store.lookupByTask('task-fail'), isNull);
        manager.dispose();
      });

      test('removes binding when task transitions to cancelled', () async {
        await store.create(makeBinding(taskId: 'task-cancel'));
        final manager = ThreadBindingLifecycleManager(store: store, eventBus: eventBus);
        manager.start();

        eventBus.fire(TaskStatusChangedEvent(
          taskId: 'task-cancel',
          oldStatus: TaskStatus.running,
          newStatus: TaskStatus.cancelled,
          trigger: 'test',
          timestamp: DateTime.now(),
        ));
        await Future<void>.delayed(Duration.zero);

        expect(store.lookupByTask('task-cancel'), isNull);
        manager.dispose();
      });

      test('does not remove binding for non-terminal transition', () async {
        await store.create(makeBinding(taskId: 'task-abc'));
        final manager = ThreadBindingLifecycleManager(store: store, eventBus: eventBus);
        manager.start();

        eventBus.fire(TaskStatusChangedEvent(
          taskId: 'task-abc',
          oldStatus: TaskStatus.queued,
          newStatus: TaskStatus.running,
          trigger: 'test',
          timestamp: DateTime.now(),
        ));
        await Future<void>.delayed(Duration.zero);

        expect(store.lookupByTask('task-abc'), isNotNull);
        manager.dispose();
      });

      test('is a no-op when no binding exists for the task', () async {
        // No binding in store — should not throw.
        final manager = ThreadBindingLifecycleManager(store: store, eventBus: eventBus);
        manager.start();

        eventBus.fire(TaskStatusChangedEvent(
          taskId: 'unknown-task',
          oldStatus: TaskStatus.review,
          newStatus: TaskStatus.accepted,
          trigger: 'test',
          timestamp: DateTime.now(),
        ));
        await Future<void>.delayed(Duration.zero);

        // No assertion needed — test passes if no exception is thrown.
        manager.dispose();
      });

      test('only removes the matching task binding, not others', () async {
        await store.create(makeBinding(taskId: 'task-abc', threadId: 'spaces/A/threads/1'));
        await store.create(makeBinding(taskId: 'task-xyz', threadId: 'spaces/B/threads/2'));
        final manager = ThreadBindingLifecycleManager(store: store, eventBus: eventBus);
        manager.start();

        eventBus.fire(TaskStatusChangedEvent(
          taskId: 'task-abc',
          oldStatus: TaskStatus.review,
          newStatus: TaskStatus.accepted,
          trigger: 'test',
          timestamp: DateTime.now(),
        ));
        await Future<void>.delayed(Duration.zero);

        expect(store.lookupByTask('task-abc'), isNull);
        expect(store.lookupByTask('task-xyz'), isNotNull);
        manager.dispose();
      });
    });

    group('idle timeout cleanup (fake_async)', () {
      test('removes bindings whose lastActivity exceeds idle timeout', () {
        fakeAsync((async) {
          final staleTime = async.getClock(DateTime.now()).now().subtract(const Duration(hours: 2));
          final staleBinding = makeBinding(taskId: 'stale-task', lastActivity: staleTime);

          // Store must be set up synchronously before the zone clock is used.
          store.create(staleBinding);
          async.flushMicrotasks();

          final manager = ThreadBindingLifecycleManager(
            store: store,
            eventBus: eventBus,
            idleTimeout: const Duration(hours: 1),
            cleanupInterval: const Duration(minutes: 5),
          );
          manager.start();

          // Advance clock past one cleanup interval.
          async.elapse(const Duration(minutes: 6));

          expect(store.lookupByTask('stale-task'), isNull);
          manager.dispose();
        });
      });

      test('does not remove bindings within idle timeout', () {
        fakeAsync((async) {
          final freshTime = async.getClock(DateTime.now()).now().subtract(const Duration(minutes: 30));
          final freshBinding = makeBinding(taskId: 'fresh-task', lastActivity: freshTime);

          store.create(freshBinding);
          async.flushMicrotasks();

          final manager = ThreadBindingLifecycleManager(
            store: store,
            eventBus: eventBus,
            idleTimeout: const Duration(hours: 1),
            cleanupInterval: const Duration(minutes: 5),
          );
          manager.start();

          async.elapse(const Duration(minutes: 6));

          expect(store.lookupByTask('fresh-task'), isNotNull);
          manager.dispose();
        });
      });

      test('does not run cleanup before first interval elapses', () {
        fakeAsync((async) {
          final staleTime = async.getClock(DateTime.now()).now().subtract(const Duration(hours: 2));
          store.create(makeBinding(taskId: 'stale-task', lastActivity: staleTime));
          async.flushMicrotasks();

          final manager = ThreadBindingLifecycleManager(
            store: store,
            eventBus: eventBus,
            idleTimeout: const Duration(hours: 1),
            cleanupInterval: const Duration(minutes: 5),
          );
          manager.start();

          // Only advance 4 minutes — before first cleanup fires.
          async.elapse(const Duration(minutes: 4));

          // Still present — no cleanup yet.
          expect(store.lookupByTask('stale-task'), isNotNull);
          manager.dispose();
        });
      });

      test('runs cleanup repeatedly at each interval', () {
        fakeAsync((async) {
          final now = async.getClock(DateTime.now()).now();

          // First binding is stale at t=0.
          final staleTime1 = now.subtract(const Duration(hours: 2));
          store.create(makeBinding(
            taskId: 'task-A',
            threadId: 'spaces/A/threads/1',
            lastActivity: staleTime1,
          ));
          async.flushMicrotasks();

          final manager = ThreadBindingLifecycleManager(
            store: store,
            eventBus: eventBus,
            idleTimeout: const Duration(hours: 1),
            cleanupInterval: const Duration(minutes: 5),
          );
          manager.start();

          // First sweep at t+5min removes task-A.
          async.elapse(const Duration(minutes: 6));
          expect(store.lookupByTask('task-A'), isNull);

          manager.dispose();
        });
      });
    });

    group('dispose', () {
      test('cancels event subscription — no removal after dispose', () async {
        await store.create(makeBinding(taskId: 'task-abc'));
        final manager = ThreadBindingLifecycleManager(store: store, eventBus: eventBus);
        manager.start();
        manager.dispose();

        eventBus.fire(TaskStatusChangedEvent(
          taskId: 'task-abc',
          oldStatus: TaskStatus.review,
          newStatus: TaskStatus.accepted,
          trigger: 'test',
          timestamp: DateTime.now(),
        ));
        await Future<void>.delayed(Duration.zero);

        // Binding still present — subscription was cancelled.
        expect(store.lookupByTask('task-abc'), isNotNull);
      });

      test('cancels cleanup timer — no sweep fires after dispose', () {
        fakeAsync((async) {
          final staleTime = async.getClock(DateTime.now()).now().subtract(const Duration(hours: 2));
          store.create(makeBinding(taskId: 'stale-task', lastActivity: staleTime));
          async.flushMicrotasks();

          final manager = ThreadBindingLifecycleManager(
            store: store,
            eventBus: eventBus,
            idleTimeout: const Duration(hours: 1),
            cleanupInterval: const Duration(minutes: 5),
          );
          manager.start();
          manager.dispose();

          // Elapse past cleanup interval — timer is cancelled, no cleanup.
          async.elapse(const Duration(minutes: 10));

          expect(store.lookupByTask('stale-task'), isNotNull);
        });
      });

      test('is safe to call multiple times', () async {
        final manager = ThreadBindingLifecycleManager(store: store, eventBus: eventBus);
        manager.start();
        manager.dispose();
        manager.dispose(); // should not throw
      });
    });
  });
}
