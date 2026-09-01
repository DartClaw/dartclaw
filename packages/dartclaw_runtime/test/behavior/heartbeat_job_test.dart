import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_runtime/dartclaw_runtime.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' hide TurnManager, TurnRunner;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory workspace;
  late FakeTurnManager turns;
  late _KeyedSessionService sessions;
  late EventBus eventBus;
  late List<ScheduledJobFailedEvent> failures;

  setUp(() {
    workspace = Directory.systemTemp.createTempSync('heartbeat_job_');
    turns = FakeTurnManager(
      onWaitForOutcome: (sessionId, turnId) async => TurnOutcome(
        turnId: turnId,
        sessionId: sessionId,
        status: TurnStatus.completed,
        responseText: 'checklist processed',
        completedAt: DateTime.now(),
      ),
    );
    sessions = _KeyedSessionService();
    eventBus = EventBus();
    failures = [];
    final subscription = eventBus.on<ScheduledJobFailedEvent>().listen(failures.add);
    addTearDown(subscription.cancel);
  });

  tearDown(() async {
    await eventBus.dispose();
    if (workspace.existsSync()) workspace.deleteSync(recursive: true);
  });

  ScheduleService serviceFor(ScheduledJob job) =>
      ScheduleService(turns: turns, sessions: sessions, jobs: [job], eventBus: eventBus)..start();

  ScheduledJob heartbeat() => buildHeartbeatJob(workspaceDir: workspace.path, intervalMinutes: 30);

  void writeChecklist(String content) => File(p.join(workspace.path, 'HEARTBEAT.md')).writeAsStringSync(content);

  test('the built-in job carries the heartbeat id and its configured interval', () {
    final job = buildHeartbeatJob(workspaceDir: workspace.path, intervalMinutes: 15);

    expect(job.id, heartbeatJobId);
    expect(job.scheduleType, ScheduleType.interval);
    expect(job.intervalMinutes, 15);
    expect(job.perFireSession, isTrue);
  });

  for (final shape in ['missing', 'empty', 'whitespace-only', 'undecodable']) {
    test('a $shape HEARTBEAT.md starts no turn and records no failure', () async {
      switch (shape) {
        case 'empty':
          writeChecklist('');
        case 'whitespace-only':
          writeChecklist('   \n\n');
        case 'undecodable':
          File(p.join(workspace.path, 'HEARTBEAT.md')).writeAsBytesSync([0xff, 0xfe, 0xfd]);
      }
      final job = heartbeat();
      final service = serviceFor(job);
      addTearDown(service.stop);

      await service.executeJobForTesting(job);
      await pumpEventQueue();

      expect(turns.startTurnCallCount, 0, reason: shape);
      expect(sessions.keys, isEmpty, reason: shape);
      expect(failures, isEmpty, reason: shape);
      expect(service.isJobPaused(heartbeatJobId), isFalse, reason: 'the fire must not disable the schedule');
    });
  }

  test('a non-empty checklist runs one cron turn per fire in its own session', () async {
    writeChecklist('- [ ] Check server health\n');
    final job = heartbeat();
    final service = serviceFor(job);
    addTearDown(service.stop);

    await service.executeJobForTesting(job);
    await service.executeJobForTesting(job);

    expect(turns.startTurnCallCount, 2);
    expect(sessions.keys, hasLength(2));
    expect(sessions.keys.every((key) => key.startsWith('agent:main:cron:heartbeat')), isTrue);
    final started = turns.startedTurns.first;
    expect(started.source, 'cron');
    expect(started.agentName, 'cron:$heartbeatJobId');
    expect(started.promptScope, PromptScope.task);
    expect(started.messages.single['content'], contains('- [ ] Check server health'));
    expect(failures, isEmpty);
  });

  test('a paused heartbeat job runs nothing and resumes cleanly', () async {
    writeChecklist('- [ ] Check server health\n');
    final job = heartbeat();
    final service = serviceFor(job);
    addTearDown(service.stop);

    service.pauseJob(heartbeatJobId);
    await service.executeJobForTesting(job);
    expect(turns.startTurnCallCount, 0);

    service.resumeJob(heartbeatJobId);
    await service.executeJobForTesting(job);
    expect(turns.startTurnCallCount, 1);
  });
}

class _KeyedSessionService implements SessionService {
  final Map<String, Session> _sessions = {};

  Iterable<String> get keys => _sessions.keys;

  @override
  Future<Session> getOrCreateByKey(
    String key, {
    SessionType type = SessionType.user,
    String? provider,
    String? securityProfile,
    ExecutionMode? executionMode,
  }) async => _sessions.putIfAbsent(
    key,
    () => Session(id: 'session-$key', type: type, createdAt: DateTime.now(), updatedAt: DateTime.now()),
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
