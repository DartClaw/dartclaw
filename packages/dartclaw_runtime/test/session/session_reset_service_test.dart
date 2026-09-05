import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/src/session/session_reset_service.dart';
import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';

ConfigDelta _sessionsDelta(int resetHour, {int idleTimeoutMinutes = 0}) => ConfigDelta(
  previous: const DartclawConfig.defaults(),
  current: DartclawConfig(
    sessions: SessionConfig(resetHour: resetHour, idleTimeoutMinutes: idleTimeoutMinutes),
  ),
  changedKeys: const {'sessions.*'},
);

SessionResetService _service({required int resetHour, int idleTimeoutMinutes = 0}) => SessionResetService(
  sessions: _ThrowingSessionService(),
  messages: _ThrowingMessageService(),
  resetHour: resetHour,
  idleTimeoutMinutes: idleTimeoutMinutes,
);

void main() {
  group('SessionResetService daily reset', () {
    test('an hour in range arms one daily timer that fires within a day', () {
      fakeAsync((async) {
        final service = _service(resetHour: 4)..start();
        addTearDown(service.dispose);

        expect(async.pendingTimers.single.duration, lessThanOrEqualTo(const Duration(days: 1)));
      });
    });

    test('a negative hour arms nothing, so keyed sessions are never archived on a schedule', () {
      fakeAsync((async) {
        final service = _service(resetHour: -1)..start();
        addTearDown(service.dispose);

        expect(async.pendingTimers, isEmpty);
        // The service doubles throw on every call, so a fired reset would surface here.
        async.elapse(const Duration(days: 2));
        expect(async.pendingTimers, isEmpty);
      });
    });

    test('reconfigure to a negative hour cancels the armed timer', () {
      fakeAsync((async) {
        final service = _service(resetHour: 4)..start();
        addTearDown(service.dispose);
        expect(async.pendingTimers, hasLength(1));

        service.reconfigure(_sessionsDelta(-1));

        expect(async.pendingTimers, isEmpty);
        async.elapse(const Duration(days: 2));
        expect(async.pendingTimers, isEmpty);
      });
    });

    test('reconfigure away from a negative hour arms the timer that was never started', () {
      fakeAsync((async) {
        final service = _service(resetHour: -1)..start();
        addTearDown(service.dispose);
        expect(async.pendingTimers, isEmpty);

        service.reconfigure(_sessionsDelta(4));

        expect(async.pendingTimers.single.duration, lessThanOrEqualTo(const Duration(days: 1)));
      });
    });

    test('reconfigure before start arms nothing', () {
      fakeAsync((async) {
        final service = _service(resetHour: -1);
        addTearDown(service.dispose);

        service.reconfigure(_sessionsDelta(4));

        expect(async.pendingTimers, isEmpty);
      });
    });
  });

  group('SessionResetService idle timeout', () {
    test('a disabled daily reset leaves the idle timer arming as configured', () {
      fakeAsync((async) {
        final service = _service(resetHour: -1, idleTimeoutMinutes: 30)..start();
        addTearDown(service.dispose);

        service.touchActivity('session-a');

        expect(async.pendingTimers.single.duration, const Duration(minutes: 30));
      });
    });

    test('a disabled idle timeout still arms nothing under a disabled daily reset', () {
      fakeAsync((async) {
        final service = _service(resetHour: -1)..start();
        addTearDown(service.dispose);

        service.touchActivity('session-a');

        expect(async.pendingTimers, isEmpty);
      });
    });
  });
}

class _ThrowingSessionService implements SessionService {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(invocation.memberName.toString());
}

class _ThrowingMessageService implements MessageService {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(invocation.memberName.toString());
}
