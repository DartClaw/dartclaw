import 'dart:async';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

class _FakeSessionService implements SessionService {
  @override
  Future<Session> getOrCreateByKey(String key, {SessionType type = SessionType.user, String? provider}) async {
    return Session(id: 'fake-$key', createdAt: DateTime.now(), updatedAt: DateTime.now());
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Creates a [ScheduledJob] that always throws from [onExecute].
ScheduledJob makeFailJob({
  required String jobId,
  required Object Function() throwFn,
  int retryAttempts = 0,
}) {
  return ScheduledJob(
    id: jobId,
    prompt: '',
    scheduleType: ScheduleType.interval,
    intervalMinutes: 60,
    deliveryMode: DeliveryMode.none,
    retryAttempts: retryAttempts,
    retryDelaySeconds: 0,
    onExecute: () async => throw throwFn(),
  );
}

ScheduleService makeService({
  required ScheduledJob job,
  required EventBus? eventBus,
}) {
  return ScheduleService(
    turns: FakeTurnManager(),
    sessions: _FakeSessionService(),
    jobs: [job],
    eventBus: eventBus,
  );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('ScheduleService alert emission', () {
    late EventBus eventBus;
    late List<ScheduledJobFailedEvent> emitted;
    late StreamSubscription<ScheduledJobFailedEvent> sub;

    setUp(() {
      eventBus = EventBus();
      emitted = [];
      sub = eventBus.on<ScheduledJobFailedEvent>().listen(emitted.add);
    });

    tearDown(() async {
      await sub.cancel();
      await eventBus.dispose();
    });

    test('fires ScheduledJobFailedEvent after all retries exhausted', () async {
      final job = makeFailJob(
        jobId: 'immediate-fail',
        throwFn: () => Exception('deliberate failure'),
      );
      final svc = makeService(job: job, eventBus: eventBus);
      svc.start();
      await svc.executeJobForTesting(job);
      await Future<void>.delayed(Duration.zero);

      expect(emitted, hasLength(1));
      expect(emitted.first.jobId, 'immediate-fail');
      expect(emitted.first.jobName, 'immediate-fail');
      expect(emitted.first.error, contains('deliberate failure'));
    });

    test('ScheduledJobFailedEvent contains correct jobId and error string', () async {
      const expectedJobId = 'my-failing-job';
      const expectedError = 'planned failure message';

      final job = makeFailJob(
        jobId: expectedJobId,
        throwFn: () => Exception(expectedError),
      );
      final svc = makeService(job: job, eventBus: eventBus);
      svc.start();
      await svc.executeJobForTesting(job);
      await Future<void>.delayed(Duration.zero);

      expect(emitted, hasLength(1));
      expect(emitted.first.jobId, expectedJobId);
      expect(emitted.first.error, contains(expectedError));
    });

    test('no ScheduledJobFailedEvent when EventBus is null', () async {
      final other = EventBus();
      final otherEmitted = <ScheduledJobFailedEvent>[];
      final otherSub = other.on<ScheduledJobFailedEvent>().listen(otherEmitted.add);

      final job = makeFailJob(
        jobId: 'no-bus-job',
        throwFn: () => Exception('no bus failure'),
      );
      final svc = makeService(job: job, eventBus: null);
      svc.start();
      await svc.executeJobForTesting(job);

      // Neither bus should have received anything.
      expect(emitted, isEmpty);
      expect(otherEmitted, isEmpty);

      await otherSub.cancel();
      await other.dispose();
    });
  });
}
