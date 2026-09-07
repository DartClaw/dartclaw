import 'dart:async';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:fake_async/fake_async.dart';
import 'package:logging/logging.dart';
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
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    group('auto-unbind on terminal state', () {
      test('removes binding when task transitions to accepted', () async {
        await store.create(makeBinding(taskId: 'task-abc'));
        final manager = ThreadBindingLifecycleManager(store: store, eventBus: eventBus);
        manager.start();

        eventBus.fire(
          TaskStatusChangedEvent(
            taskId: 'task-abc',
            oldStatus: TaskStatus.review,
            newStatus: TaskStatus.accepted,
            trigger: 'test',
            timestamp: DateTime.now(),
          ),
        );

        // EventBus is async (broadcast stream), flush microtasks.
        await Future<void>.delayed(Duration.zero);

        expect(store.lookupByTask('task-abc'), isEmpty);
        await manager.dispose();
      });

      test('removes binding when task transitions to rejected', () async {
        await store.create(makeBinding(taskId: 'task-xyz'));
        final manager = ThreadBindingLifecycleManager(store: store, eventBus: eventBus);
        manager.start();

        eventBus.fire(
          TaskStatusChangedEvent(
            taskId: 'task-xyz',
            oldStatus: TaskStatus.review,
            newStatus: TaskStatus.rejected,
            trigger: 'test',
            timestamp: DateTime.now(),
          ),
        );
        await Future<void>.delayed(Duration.zero);

        expect(store.lookupByTask('task-xyz'), isEmpty);
        await manager.dispose();
      });

      test('removes binding when task transitions to failed', () async {
        await store.create(makeBinding(taskId: 'task-fail'));
        final manager = ThreadBindingLifecycleManager(store: store, eventBus: eventBus);
        manager.start();

        eventBus.fire(
          TaskStatusChangedEvent(
            taskId: 'task-fail',
            oldStatus: TaskStatus.running,
            newStatus: TaskStatus.failed,
            trigger: 'test',
            timestamp: DateTime.now(),
          ),
        );
        await Future<void>.delayed(Duration.zero);

        expect(store.lookupByTask('task-fail'), isEmpty);
        await manager.dispose();
      });

      test('removes binding when task transitions to cancelled', () async {
        await store.create(makeBinding(taskId: 'task-cancel'));
        final manager = ThreadBindingLifecycleManager(store: store, eventBus: eventBus);
        manager.start();

        eventBus.fire(
          TaskStatusChangedEvent(
            taskId: 'task-cancel',
            oldStatus: TaskStatus.running,
            newStatus: TaskStatus.cancelled,
            trigger: 'test',
            timestamp: DateTime.now(),
          ),
        );
        await Future<void>.delayed(Duration.zero);

        expect(store.lookupByTask('task-cancel'), isEmpty);
        await manager.dispose();
      });

      test('does not remove binding for non-terminal transition', () async {
        await store.create(makeBinding(taskId: 'task-abc'));
        final manager = ThreadBindingLifecycleManager(store: store, eventBus: eventBus);
        manager.start();

        eventBus.fire(
          TaskStatusChangedEvent(
            taskId: 'task-abc',
            oldStatus: TaskStatus.queued,
            newStatus: TaskStatus.running,
            trigger: 'test',
            timestamp: DateTime.now(),
          ),
        );
        await Future<void>.delayed(Duration.zero);

        expect(store.lookupByTask('task-abc'), isNotEmpty);
        await manager.dispose();
      });

      test('is a no-op when no binding exists for the task', () async {
        // No binding in store — should not throw.
        final manager = ThreadBindingLifecycleManager(store: store, eventBus: eventBus);
        manager.start();

        eventBus.fire(
          TaskStatusChangedEvent(
            taskId: 'unknown-task',
            oldStatus: TaskStatus.review,
            newStatus: TaskStatus.accepted,
            trigger: 'test',
            timestamp: DateTime.now(),
          ),
        );
        await Future<void>.delayed(Duration.zero);

        // No assertion needed — test passes if no exception is thrown.
        await manager.dispose();
      });

      test('only removes the matching task binding, not others', () async {
        await store.create(makeBinding(taskId: 'task-abc', threadId: 'spaces/A/threads/1'));
        await store.create(makeBinding(taskId: 'task-xyz', threadId: 'spaces/B/threads/2'));
        final manager = ThreadBindingLifecycleManager(store: store, eventBus: eventBus);
        manager.start();

        eventBus.fire(
          TaskStatusChangedEvent(
            taskId: 'task-abc',
            oldStatus: TaskStatus.review,
            newStatus: TaskStatus.accepted,
            trigger: 'test',
            timestamp: DateTime.now(),
          ),
        );
        await Future<void>.delayed(Duration.zero);

        expect(store.lookupByTask('task-abc'), isEmpty);
        expect(store.lookupByTask('task-xyz'), isNotEmpty);
        await manager.dispose();
      });

      test('removes all bindings for the matching task across channels', () async {
        await store.create(makeBinding(channelType: 'googlechat', threadId: 'spaces/A/threads/1', taskId: 'task-abc'));
        await store.create(makeBinding(channelType: 'whatsapp', threadId: 'group-a@g.us', taskId: 'task-abc'));
        await store.create(makeBinding(channelType: 'signal', threadId: 'signal-group-1', taskId: 'task-abc'));
        final manager = ThreadBindingLifecycleManager(store: store, eventBus: eventBus);
        manager.start();

        eventBus.fire(
          TaskStatusChangedEvent(
            taskId: 'task-abc',
            oldStatus: TaskStatus.review,
            newStatus: TaskStatus.accepted,
            trigger: 'test',
            timestamp: DateTime.now(),
          ),
        );
        await Future<void>.delayed(Duration.zero);

        expect(store.lookupByTask('task-abc'), isEmpty);
        expect(store.lookupByThread('googlechat', 'spaces/A/threads/1'), isNull);
        expect(store.lookupByThread('whatsapp', 'group-a@g.us'), isNull);
        expect(store.lookupByThread('signal', 'signal-group-1'), isNull);
        await manager.dispose();
      });
    });

    group('idle timeout cleanup', () {
      test('sweeps repeatedly at the configured interval with the idle cutoff', () async {
        final async = FakeAsync();
        var disposed = false;
        async.run((_) {
          final timerEvents = EventBus();
          final cutoffs = <DateTime>[];
          final expiryStore = _ExpiryStore(tempFile, (cutoff) async {
            cutoffs.add(cutoff);
            return [];
          });
          final manager = ThreadBindingLifecycleManager(
            store: expiryStore,
            eventBus: timerEvents,
            idleTimeout: const Duration(hours: 1),
            cleanupInterval: const Duration(minutes: 5),
          );
          manager.start();
          async.elapse(const Duration(minutes: 4));
          expect(cutoffs, isEmpty);
          final earliest = DateTime.now().subtract(const Duration(hours: 1));
          async.elapse(const Duration(minutes: 6));
          expect(cutoffs, hasLength(2));
          final latest = DateTime.now().subtract(const Duration(hours: 1));
          for (final cutoff in cutoffs) {
            expect(cutoff.isBefore(earliest), isFalse);
            expect(cutoff.isAfter(latest), isFalse);
          }
          manager.dispose().then((_) {
            disposed = true;
          });
          async.flushMicrotasks();
          manager.dispose().then((_) => timerEvents.dispose());
          async.flushMicrotasks();
        });
        // The SDK's cached subscription-cancellation future can complete outside the fake zone.
        await pumpEventQueue();
        async.flushMicrotasks();
        expect(disposed, isTrue);
      });

      test('expiry persists removal while retaining fresh and cutoff-equal bindings', () async {
        final cutoff = DateTime.now().subtract(const Duration(hours: 1));
        await store.create(
          makeBinding(taskId: 'stale', threadId: 'stale', lastActivity: cutoff.subtract(const Duration(seconds: 1))),
        );
        await store.create(
          makeBinding(taskId: 'fresh', threadId: 'fresh', lastActivity: cutoff.add(const Duration(seconds: 1))),
        );
        await store.create(makeBinding(taskId: 'boundary', threadId: 'boundary', lastActivity: cutoff));
        final removed = await store.removeExpiredBindings(cutoff);
        expect(removed.map((binding) => binding.taskId), ['stale']);
        final reloaded = ThreadBindingStore(tempFile);
        await reloaded.load();
        expect(reloaded.lookupByTask('stale'), isEmpty);
        expect(reloaded.lookupByTask('fresh'), isNotEmpty);
        expect(reloaded.lookupByTask('boundary'), isNotEmpty);
      });
    });

    group('dispose', () {
      test('disposal waits for terminal unbinding to persist before shutdown', () async {
        final delayedStore = _DelayedDeleteStore(tempFile);
        await delayedStore.create(makeBinding());
        final manager = ThreadBindingLifecycleManager(store: delayedStore, eventBus: eventBus);
        manager.start();
        eventBus.fire(
          TaskStatusChangedEvent(
            taskId: 'task-abc',
            oldStatus: TaskStatus.running,
            newStatus: TaskStatus.accepted,
            trigger: 'test',
            timestamp: DateTime.now(),
          ),
        );
        await delayedStore.started.future;
        var disposed = false;
        final disposal = manager.dispose().then((_) {
          disposed = true;
        });
        try {
          await pumpEventQueue();
          expect(disposed, isFalse, reason: 'Shutdown must wait for the pending binding write.');
          delayedStore.release.complete();
          await disposal;
          final reloaded = ThreadBindingStore(tempFile);
          await reloaded.load();
          expect(reloaded.lookupByTask('task-abc'), isEmpty);
        } finally {
          if (!delayedStore.release.isCompleted) delayedStore.release.complete();
          await delayedStore.deletion;
          await disposal;
        }
      });

      test('cancels event subscription — no removal after dispose', () async {
        await store.create(makeBinding(taskId: 'task-abc'));
        final manager = ThreadBindingLifecycleManager(store: store, eventBus: eventBus);
        manager.start();
        await manager.dispose();

        eventBus.fire(
          TaskStatusChangedEvent(
            taskId: 'task-abc',
            oldStatus: TaskStatus.review,
            newStatus: TaskStatus.accepted,
            trigger: 'test',
            timestamp: DateTime.now(),
          ),
        );
        await Future<void>.delayed(Duration.zero);

        // Binding still present — subscription was cancelled.
        expect(store.lookupByTask('task-abc'), isNotEmpty);
      });

      test('cancels new timer work and drains an in-flight expiry write', () async {
        final async = FakeAsync();
        var disposed = false;
        async.run((_) {
          final timerEvents = EventBus();
          final pending = Completer<List<ThreadBinding>>();
          var sweeps = 0;
          final expiryStore = _ExpiryStore(tempFile, (_) {
            sweeps++;
            return pending.future;
          });
          final manager = ThreadBindingLifecycleManager(
            store: expiryStore,
            eventBus: timerEvents,
            cleanupInterval: const Duration(minutes: 5),
          );
          manager.start();
          async.elapse(const Duration(minutes: 5));
          expect(sweeps, 1);
          manager.dispose().then((_) {
            disposed = true;
          });
          async.elapse(const Duration(minutes: 10));
          expect(sweeps, 1);
          expect(disposed, isFalse);
          pending.complete([]);
          async.flushMicrotasks();
          manager.dispose().then((_) => timerEvents.dispose());
          async.flushMicrotasks();
        });
        await pumpEventQueue();
        async.flushMicrotasks();
        expect(disposed, isTrue);
      });

      test('logs persistence failures and continues queued cleanup', () async {
        final async = FakeAsync();
        var disposed = false;
        async.run((_) {
          final timerEvents = EventBus();
          final failure = FileSystemException('write refused');
          final errors = <Object?>[];
          final subscription = Logger('ThreadBindingLifecycleManager').onRecord.listen((record) {
            if (record.level >= Level.WARNING) errors.add(record.error);
          });
          var sweeps = 0;
          final expiryStore = _ExpiryStore(tempFile, (_) async {
            if (++sweeps == 1) throw failure;
            return [];
          });
          final manager = ThreadBindingLifecycleManager(
            store: expiryStore,
            eventBus: timerEvents,
            cleanupInterval: const Duration(minutes: 5),
          );
          manager.start();
          async.elapse(const Duration(minutes: 10));
          manager.dispose().then((_) {
            disposed = true;
          });
          async.flushMicrotasks();
          expect(errors, [failure]);
          expect(sweeps, 2);
          unawaited(subscription.cancel());
          async.flushMicrotasks();
          manager.dispose().then((_) => timerEvents.dispose());
          async.flushMicrotasks();
        });
        await pumpEventQueue();
        async.flushMicrotasks();
        expect(disposed, isTrue);
      });

      test('is safe to call multiple times', () async {
        final manager = ThreadBindingLifecycleManager(store: store, eventBus: eventBus);
        manager.start();
        await manager.dispose();
        await manager.dispose(); // should not throw
      });
    });
  });
}

class _DelayedDeleteStore extends ThreadBindingStore {
  new(super.file);

  final started = Completer<void>();
  final release = Completer<void>();
  late Future<List<ThreadBinding>> deletion;

  @override
  Future<List<ThreadBinding>> deleteByTaskId(String taskId) => deletion = _delete(taskId);

  Future<List<ThreadBinding>> _delete(String taskId) async {
    started.complete();
    await release.future;
    return super.deleteByTaskId(taskId);
  }
}

class _ExpiryStore extends ThreadBindingStore {
  new(super.file, this.expire);

  final Future<List<ThreadBinding>> Function(DateTime) expire;

  @override
  Future<List<ThreadBinding>> removeExpiredBindings(DateTime cutoff) => expire(cutoff);
}
