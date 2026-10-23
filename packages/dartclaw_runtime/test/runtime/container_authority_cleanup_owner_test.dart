import 'dart:async';

import 'package:dartclaw_runtime/src/runtime/container_authority_cleanup_owner.dart';
import 'package:dartclaw_core/dartclaw_core.dart' show ContainerExecutor, TurnProvenance;
import 'package:dartclaw_runtime/dartclaw_runtime.dart' show ContainerAuthorityLease;
import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';

import 'fake_container_authority.dart' show FakeContainerExecutor;

void main() {
  test('coalesces concurrent release and forgets only confirmed destruction', () {
    fakeAsync((async) {
      final blocker = Completer<void>();
      final delegate = _RecordingLease(onRelease: () => blocker.future);
      final owner = ContainerAuthorityCleanupOwner();
      final lease = owner.own(delegate);
      var completions = 0;

      unawaited(lease.release().then((_) => completions++));
      unawaited(lease.release().then((_) => completions++));
      async.flushMicrotasks();

      expect(delegate.releaseCalls, 1);
      expect(owner.retainedCount, 1);

      blocker.complete();
      async.flushMicrotasks();

      expect(completions, 2);
      expect(owner.retainedCount, 0);
    });
  });

  test('automatically retries a failed release after daemon recovery', () {
    fakeAsync((async) {
      final delegate = _RecordingLease(failuresRemaining: 1);
      final owner = ContainerAuthorityCleanupOwner(retryDelay: const Duration(seconds: 1));
      final lease = owner.own(delegate);
      Object? releaseError;

      unawaited(
        lease.release().catchError((Object error) {
          releaseError = error;
        }),
      );
      async.flushMicrotasks();

      expect(releaseError, isA<StateError>());
      expect(delegate.releaseCalls, 1);
      expect(owner.pendingCount, 1);

      async.elapse(const Duration(seconds: 1));
      async.flushMicrotasks();

      expect(delegate.releaseCalls, 2);
      expect(owner.retainedCount, 0);
      expect(owner.pendingCount, 0);
    });
  });

  test('shutdown sweeps both active and previously failed authorities', () async {
    final active = _RecordingLease();
    final failed = _RecordingLease(failuresRemaining: 1);
    final owner = ContainerAuthorityCleanupOwner(retryDelay: const Duration(days: 1));
    owner.own(active);
    final failedLease = owner.own(failed);

    await expectLater(failedLease.release(), throwsStateError);
    expect(owner.retainedCount, 2);
    expect(owner.pendingCount, 1);

    await owner.dispose();

    expect(active.releaseCalls, 1);
    expect(failed.releaseCalls, 2);
    expect(owner.retainedCount, 0);
    expect(owner.pendingCount, 0);
  });
}

final class _RecordingLease implements ContainerAuthorityLease {
  new({this.failuresRemaining = 0, this.onRelease});

  int failuresRemaining;
  final Future<void> Function()? onRelease;
  int releaseCalls = 0;

  @override
  final ContainerExecutor container = FakeContainerExecutor();

  @override
  void bindActiveTurn(TurnProvenance? Function() activeTurn) {}

  @override
  Future<void> release() async {
    releaseCalls++;
    await onRelease?.call();
    if (failuresRemaining > 0) {
      failuresRemaining--;
      throw StateError('docker rm -f failed');
    }
  }
}
