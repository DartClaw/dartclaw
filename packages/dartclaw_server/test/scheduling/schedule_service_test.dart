import 'dart:async';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:test/test.dart';

void main() {
  group('ScheduledJob.fromConfig', () {
    test('parses cron job', () {
      final job = ScheduledJob.fromConfig({
        'id': 'test-cron',
        'prompt': 'Do something',
        'schedule': {'type': 'cron', 'expression': '0 18 * * *'},
        'delivery': 'none',
      });
      expect(job.id, 'test-cron');
      expect(job.prompt, 'Do something');
      expect(job.scheduleType, ScheduleType.cron);
      expect(job.cronExpression, isNotNull);
      expect(job.deliveryMode, DeliveryMode.none);
    });

    test('parses UI-authored cron job shape', () {
      final job = ScheduledJob.fromConfig({
        'name': 'daily-summary',
        'prompt': 'Do something',
        'schedule': '0 18 * * *',
        'delivery': 'announce',
      });
      expect(job.id, 'daily-summary');
      expect(job.prompt, 'Do something');
      expect(job.scheduleType, ScheduleType.cron);
      expect(job.cronExpression, isNotNull);
      expect(job.deliveryMode, DeliveryMode.announce);
    });

    test('parses interval job', () {
      final job = ScheduledJob.fromConfig({
        'id': 'test-interval',
        'prompt': 'Check emails',
        'schedule': {'type': 'interval', 'minutes': 60},
        'delivery': 'webhook',
        'webhook_url': 'http://localhost:8080/hook',
      });
      expect(job.scheduleType, ScheduleType.interval);
      expect(job.intervalMinutes, 60);
      expect(job.deliveryMode, DeliveryMode.webhook);
      expect(job.webhookUrl, 'http://localhost:8080/hook');
    });

    test('parses one-time job', () {
      final job = ScheduledJob.fromConfig({
        'id': 'test-once',
        'prompt': 'Initialize',
        'schedule': {'type': 'once', 'at': '2026-03-01T09:00:00'},
        'delivery': 'none',
      });
      expect(job.scheduleType, ScheduleType.once);
      expect(job.onceAt, DateTime(2026, 3, 1, 9, 0));
    });

    test('parses retry config', () {
      final job = ScheduledJob.fromConfig({
        'id': 'test-retry',
        'prompt': 'Retry test',
        'schedule': {'type': 'interval', 'minutes': 30},
        'retry': {'attempts': 3, 'delay_seconds': 120},
      });
      expect(job.retryAttempts, 3);
      expect(job.retryDelaySeconds, 120);
    });

    test('defaults retry to 0 attempts', () {
      final job = ScheduledJob.fromConfig({
        'id': 'test-no-retry',
        'prompt': 'No retry',
        'schedule': {'type': 'interval', 'minutes': 10},
      });
      expect(job.retryAttempts, 0);
      expect(job.retryDelaySeconds, 60);
    });

    test('throws on missing id', () {
      expect(
        () => ScheduledJob.fromConfig({
          'prompt': 'test',
          'schedule': {'type': 'cron', 'expression': '* * * * *'},
        }),
        throwsFormatException,
      );
    });

    test('throws on missing prompt', () {
      expect(
        () => ScheduledJob.fromConfig({
          'id': 'test',
          'schedule': {'type': 'cron', 'expression': '* * * * *'},
        }),
        throwsFormatException,
      );
    });

    test('throws on invalid cron expression', () {
      expect(
        () => ScheduledJob.fromConfig({
          'id': 'test',
          'prompt': 'test',
          'schedule': {'type': 'cron', 'expression': 'bad'},
        }),
        throwsFormatException,
      );
    });

    test('throws on missing cron expression', () {
      expect(
        () => ScheduledJob.fromConfig({
          'id': 'test',
          'prompt': 'test',
          'schedule': {'type': 'cron'},
        }),
        throwsFormatException,
      );
    });

    test('throws on invalid interval', () {
      expect(
        () => ScheduledJob.fromConfig({
          'id': 'test',
          'prompt': 'test',
          'schedule': {'type': 'interval', 'minutes': 0},
        }),
        throwsFormatException,
      );
    });

    test('throws on invalid once datetime', () {
      expect(
        () => ScheduledJob.fromConfig({
          'id': 'test',
          'prompt': 'test',
          'schedule': {'type': 'once', 'at': 'not-a-date'},
        }),
        throwsFormatException,
      );
    });

    test('throws on unknown schedule type', () {
      expect(
        () => ScheduledJob.fromConfig({
          'id': 'test',
          'prompt': 'test',
          'schedule': {'type': 'weekly'},
        }),
        throwsFormatException,
      );
    });

    test('unknown delivery mode defaults to none', () {
      final job = ScheduledJob.fromConfig({
        'id': 'test',
        'prompt': 'test',
        'schedule': {'type': 'interval', 'minutes': 10},
        'delivery': 'unknown_mode',
      });
      expect(job.deliveryMode, DeliveryMode.none);
    });
  });

  group('ScheduleService execution', () {
    late _ConfigurableTurnManager turns;
    late _FakeSessionService sessions;
    late ScheduledJob intervalJob;
    late ScheduledJob onceJob;
    late Directory tempDir;
    late List<(String, String)> consolidations;
    late MemoryConsolidator consolidator;

    setUp(() {
      turns = _ConfigurableTurnManager();
      sessions = _FakeSessionService();
      intervalJob = ScheduledJob.fromConfig({
        'id': 'exec-job',
        'prompt': 'Run task',
        'schedule': {'type': 'interval', 'minutes': 60},
        'delivery': 'none',
      });
      onceJob = ScheduledJob(
        id: 'once-job',
        prompt: 'One-time task',
        scheduleType: ScheduleType.once,
        onceAt: DateTime.now().add(const Duration(milliseconds: 50)),
      );
      tempDir = Directory.systemTemp.createTempSync('schedule_service_test_');
      File('${tempDir.path}/MEMORY.md').writeAsStringSync('x' * 64);
      consolidations = <(String, String)>[];
      consolidator = MemoryConsolidator(
        workspaceDir: tempDir.path,
        threshold: 16,
        dispatch: (sessionKey, message) async => consolidations.add((sessionKey, message)),
      );
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('executeJobForTesting runs the job and records execution', () async {
      final service = ScheduleService(turns: turns, sessions: sessions, jobs: []);
      service.start();
      await service.executeJobForTesting(intervalJob);
      expect(turns.startTurnCallCount, 1);
      service.stop();
    });

    test('successful agent-backed job delivers assistant response text', () async {
      final delivery = _RecordingDeliveryService(sessions: sessions);
      turns.responseText = 'assistant summary';
      final announceJob = ScheduledJob.fromConfig({
        'id': 'announce-job',
        'prompt': 'Summarize the latest updates',
        'schedule': {'type': 'interval', 'minutes': 60},
        'delivery': 'announce',
      });

      final service = ScheduleService(turns: turns, sessions: sessions, jobs: [], delivery: delivery);
      service.start();

      await service.executeJobForTesting(announceJob);

      expect(delivery.calls, hasLength(1));
      expect(delivery.calls.single.mode, DeliveryMode.announce);
      expect(delivery.calls.single.jobId, 'announce-job');
      expect(delivery.calls.single.result, 'assistant summary');
      service.stop();
    });

    test('one-time job does not reschedule after execution', () async {
      final service = ScheduleService(turns: turns, sessions: sessions, jobs: [onceJob]);
      service.start();
      // Wait for the one-time timer to fire (50ms delay)
      await Future<void>.delayed(const Duration(milliseconds: 200));
      // Turn ran exactly once
      expect(turns.startTurnCallCount, 1);
      service.stop();
    });

    test('concurrent skip: second call skips if job is already running', () async {
      final firstCallStarted = Completer<void>();
      final firstCallGate = Completer<void>();

      turns.onStartTurn = (sessionId) async {
        if (!firstCallStarted.isCompleted) {
          firstCallStarted.complete();
          // Block the first execution until gate is opened
          await firstCallGate.future;
        }
      };

      final service = ScheduleService(turns: turns, sessions: sessions, jobs: []);
      service.start();

      // Launch first execution — it will block on the gate
      final first = service.executeJobForTesting(intervalJob);
      // Wait until first execution has started
      await firstCallStarted.future;

      // Second execution should skip (job still running)
      await service.executeJobForTesting(intervalJob);

      // Only one startTurn call so far (second was skipped)
      expect(turns.startTurnCallCount, 1);

      // Unblock the first execution
      firstCallGate.complete();
      await first;

      // Still only one total call
      expect(turns.startTurnCallCount, 1);
      service.stop();
    });

    test('job failure does not prevent subsequent execution', () async {
      turns.shouldFail = true;
      final service = ScheduleService(turns: turns, sessions: sessions, jobs: []);
      service.start();

      // First execution should fail (but not throw — errors are caught internally)
      await service.executeJobForTesting(intervalJob);
      expect(turns.startTurnCallCount, 1);

      // Second execution should run normally
      turns.shouldFail = false;
      await service.executeJobForTesting(intervalJob);
      expect(turns.startTurnCallCount, 2);

      service.stop();
    });

    test('failed turn outcome throws, triggering retry logic', () async {
      // Return a failed TurnOutcome — _executeWithRetry should throw
      turns.returnFailedOutcome = true;
      final delivery = _RecordingDeliveryService(sessions: sessions);
      final service = ScheduleService(turns: turns, sessions: sessions, jobs: [], delivery: delivery);
      service.start();

      // With retryAttempts = 0, one attempt is made and failure is logged (no throw to caller)
      await service.executeJobForTesting(intervalJob);
      expect(turns.startTurnCallCount, 1);
      expect(delivery.calls, isEmpty);

      service.stop();
    });

    test('successful job triggers consolidation', () async {
      final service = ScheduleService(turns: turns, sessions: sessions, jobs: [], consolidator: consolidator);
      service.start();

      await service.executeJobForTesting(intervalJob);

      expect(consolidations, hasLength(1));
      expect(consolidations.single.$1, startsWith('agent:main:consolidation:'));
      service.stop();
    });

    test('failed job does not trigger consolidation', () async {
      turns.returnFailedOutcome = true;
      final service = ScheduleService(turns: turns, sessions: sessions, jobs: [], consolidator: consolidator);
      service.start();

      await service.executeJobForTesting(intervalJob);

      expect(consolidations, isEmpty);
      service.stop();
    });

    test('model and effort from job are passed through to startTurn', () async {
      final jobWithOverrides = ScheduledJob.fromConfig({
        'id': 'override-job',
        'prompt': 'Do something with overrides',
        'schedule': {'type': 'interval', 'minutes': 60},
        'delivery': 'none',
        'model': 'claude-haiku-4-5',
        'effort': 'low',
      });

      final service = ScheduleService(turns: turns, sessions: sessions, jobs: []);
      service.start();
      await service.executeJobForTesting(jobWithOverrides);

      expect(turns.startTurnCallCount, 1);
      expect(turns.lastModel, 'claude-haiku-4-5');
      expect(turns.lastEffort, 'low');
      service.stop();
    });
  });

  group('ScheduleService', () {
    test('stop cancels all timers without error', () {
      // We can't easily unit-test timer firing without a TurnManager,
      // but we can verify start/stop lifecycle doesn't throw
      final service = ScheduleService(
        turns: _FakeTurnManager(),
        sessions: _FakeSessionService(),
        jobs: [
          ScheduledJob.fromConfig({
            'id': 'test-job',
            'prompt': 'Do something',
            'schedule': {'type': 'interval', 'minutes': 60},
          }),
        ],
      );
      service.start();
      service.stop();
    });

    test('start with empty jobs is no-op', () {
      final service = ScheduleService(turns: _FakeTurnManager(), sessions: _FakeSessionService(), jobs: []);
      service.start();
      service.stop();
    });

    test('double start is idempotent', () {
      final service = ScheduleService(
        turns: _FakeTurnManager(),
        sessions: _FakeSessionService(),
        jobs: [
          ScheduledJob.fromConfig({
            'id': 'test-job',
            'prompt': 'Do something',
            'schedule': {'type': 'interval', 'minutes': 60},
          }),
        ],
      );
      service.start();
      service.start(); // should not throw or double-schedule
      service.stop();
    });

    test('pauseJob marks job as paused', () {
      final service = ScheduleService(
        turns: _FakeTurnManager(),
        sessions: _FakeSessionService(),
        jobs: [
          ScheduledJob.fromConfig({
            'id': 'my-job',
            'prompt': 'Do something',
            'schedule': {'type': 'interval', 'minutes': 60},
          }),
        ],
      );
      service.start();
      expect(service.isJobPaused('my-job'), isFalse);
      service.pauseJob('my-job');
      expect(service.isJobPaused('my-job'), isTrue);
      service.stop();
    });

    test('resumeJob clears paused state', () {
      final service = ScheduleService(
        turns: _FakeTurnManager(),
        sessions: _FakeSessionService(),
        jobs: [
          ScheduledJob.fromConfig({
            'id': 'my-job',
            'prompt': 'Do something',
            'schedule': {'type': 'interval', 'minutes': 60},
          }),
        ],
      );
      service.start();
      service.pauseJob('my-job');
      expect(service.isJobPaused('my-job'), isTrue);
      service.resumeJob('my-job');
      expect(service.isJobPaused('my-job'), isFalse);
      service.stop();
    });

    test('pauseJob/resumeJob are idempotent', () {
      final service = ScheduleService(turns: _FakeTurnManager(), sessions: _FakeSessionService(), jobs: []);
      // Operations on unknown job IDs should not throw
      expect(() => service.pauseJob('nonexistent'), returnsNormally);
      expect(() => service.resumeJob('nonexistent'), returnsNormally);
      expect(service.isJobPaused('nonexistent'), isFalse);
    });

    test('callback job runs onExecute without agent turn', () async {
      final turns = _ConfigurableTurnManager();
      var callbackInvoked = false;
      final callbackJob = ScheduledJob(
        id: 'callback-job',
        scheduleType: ScheduleType.interval,
        intervalMinutes: 60,
        onExecute: () async {
          callbackInvoked = true;
          return 'callback result';
        },
      );
      final service = ScheduleService(turns: turns, sessions: _FakeSessionService(), jobs: [callbackJob]);
      service.start();
      await service.executeJobForTesting(callbackJob);
      expect(callbackInvoked, isTrue);
      // No agent turn should have been created
      expect(turns.startTurnCallCount, 0);
      service.stop();
    });

    test('callback job supports pause/resume lifecycle', () async {
      final turns = _ConfigurableTurnManager();
      var invocations = 0;
      final callbackJob = ScheduledJob(
        id: 'pausable-callback',
        scheduleType: ScheduleType.interval,
        intervalMinutes: 60,
        onExecute: () async {
          invocations++;
          return 'ok';
        },
      );
      final service = ScheduleService(turns: turns, sessions: _FakeSessionService(), jobs: [callbackJob]);
      service.start();

      // Pause and attempt execution — should skip
      service.pauseJob('pausable-callback');
      await service.executeJobForTesting(callbackJob);
      expect(invocations, 0);

      // Resume and execute — should run
      service.resumeJob('pausable-callback');
      await service.executeJobForTesting(callbackJob);
      expect(invocations, 1);

      service.stop();
    });

    test('paused job is skipped during execution', () async {
      final turns = _ConfigurableTurnManager();
      final service = ScheduleService(turns: turns, sessions: _FakeSessionService(), jobs: []);
      service.start();
      final job = ScheduledJob.fromConfig({
        'id': 'skip-job',
        'prompt': 'Do skipped thing',
        'schedule': {'type': 'interval', 'minutes': 60},
      });
      service.pauseJob('skip-job');
      await service.executeJobForTesting(job);
      expect(turns.startTurnCallCount, 0);
      service.stop();
    });
  });
}

// Minimal fakes to construct ScheduleService without real dependencies
class _FakeTurnManager implements TurnManager {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// Configurable fake for execution tests.
class _ConfigurableTurnManager implements TurnManager {
  int startTurnCallCount = 0;
  bool shouldFail = false;
  bool returnFailedOutcome = false;
  String responseText = 'simulated assistant output';

  /// Captured model/effort from the most recent startTurn call.
  String? lastModel;
  String? lastEffort;

  /// Optional hook called inside startTurn — use to block execution for concurrency tests.
  Future<void> Function(String sessionId)? onStartTurn;

  final Map<String, Completer<TurnOutcome>> _pending = {};

  @override
  Future<String> startTurn(
    String sessionId,
    List<Map<String, dynamic>> messages, {
    String? source,
    String agentName = 'main',
    String? model,
    String? effort,
    bool isHumanInput = false,
  }) async {
    startTurnCallCount++;
    lastModel = model;
    lastEffort = effort;
    final turnId = 'fake-turn-$startTurnCallCount';

    if (shouldFail) {
      throw Exception('Simulated startTurn failure');
    }

    if (onStartTurn != null) {
      await onStartTurn!(sessionId);
    }

    final completer = Completer<TurnOutcome>();
    _pending[turnId] = completer;

    final status = returnFailedOutcome ? TurnStatus.failed : TurnStatus.completed;
    final outcome = TurnOutcome(
      turnId: turnId,
      sessionId: sessionId,
      status: status,
      errorMessage: returnFailedOutcome ? 'simulated failure' : null,
      responseText: returnFailedOutcome ? null : responseText,
      completedAt: DateTime.now(),
    );
    completer.complete(outcome);

    return turnId;
  }

  @override
  Future<TurnOutcome> waitForOutcome(String sessionId, String turnId) async {
    final c = _pending[turnId];
    if (c == null) throw ArgumentError('Unknown turnId: $turnId');
    return c.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

Future<String> _noopTestChannelDispatch(String sessionKey, String message, {String? senderJid, String? senderDisplayName}) async => '';

class _RecordingDeliveryService extends DeliveryService {
  final List<({DeliveryMode mode, String jobId, String result, String? webhookUrl})> calls =
      <({DeliveryMode mode, String jobId, String result, String? webhookUrl})>[];

  _RecordingDeliveryService({required super.sessions})
    : super(
        channelManager: ChannelManager(
          queue: MessageQueue(dispatcher: _noopTestChannelDispatch),
          config: const ChannelConfig.defaults(),
        ),
        sseBroadcast: SseBroadcast(),
      );

  @override
  Future<void> deliver({
    required DeliveryMode mode,
    required String jobId,
    required String result,
    String? webhookUrl,
  }) async {
    calls.add((mode: mode, jobId: jobId, result: result, webhookUrl: webhookUrl));
  }
}

class _FakeSessionService implements SessionService {
  final Map<String, Session> _keyedSessions = {};

  @override
  Future<Session> getOrCreateByKey(String key, {SessionType type = SessionType.user}) async {
    return _keyedSessions.putIfAbsent(
      key,
      () => Session(id: 'fake-uuid-for-$key', createdAt: DateTime.now(), updatedAt: DateTime.now()),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
