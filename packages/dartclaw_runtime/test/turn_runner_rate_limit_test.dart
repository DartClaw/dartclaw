import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnRunner;
import 'package:dartclaw_runtime/dartclaw_runtime.dart' hide TurnRunner;
import 'package:dartclaw_runtime/src/turn_runner.dart' show TurnRunner;
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'turn_runner_test_support.dart';

void main() {
  late Directory tempDir;
  late String sessionsDir;
  late String workspaceDir;
  late SessionService sessions;
  late MessageService messages;
  late FastFakeWorker worker;
  late Database turnStateDb;
  late TurnStateStore turnState;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('turn_runner_rate_limit_test_');
    sessionsDir = p.join(tempDir.path, 'sessions');
    workspaceDir = p.join(tempDir.path, 'workspace');
    Directory(sessionsDir).createSync(recursive: true);
    Directory(workspaceDir).createSync(recursive: true);

    sessions = SessionService(baseDir: sessionsDir);
    messages = MessageService(baseDir: sessionsDir);
    worker = FastFakeWorker();
    turnStateDb = sqlite3.openInMemory();
    turnState = TurnStateStore(turnStateDb);
  });

  tearDown(() async {
    await messages.dispose();
    await worker.dispose();
    await turnState.dispose();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  TurnRunner buildRunner({SlidingWindowRateLimiter? globalRateLimiter, RecordingSseBroadcast? sse}) {
    return TurnRunner(
      turnLimits: const TurnLimitsConfig.defaults(),
      harness: worker,
      messages: messages,
      behavior: BehaviorFileService(workspaceDir: workspaceDir),
      sessions: sessions,
      turnState: turnState,
      globalRateLimiter: globalRateLimiter,
      sseBroadcast: sse,
    );
  }

  group('TurnRunner — global rate limiting', () {
    test('turns within limit — reserve succeeds immediately', () async {
      final limiter = SlidingWindowRateLimiter(limit: 5, window: const Duration(minutes: 1));
      final runner = buildRunner(globalRateLimiter: limiter);

      final session = await sessions.getOrCreateMainSession();
      worker.responseText = 'done';
      final turnId = await runner.reserveTurn(session.id).timeout(const Duration(seconds: 2));

      expect(turnId, isNotEmpty);
      runner.executeTurn(session.id, turnId, [
        {'role': 'user', 'content': 'test'},
      ]);
      await runner.waitForOutcome(session.id, turnId);
    });

    test('no rate limiter — no limiting (backward compat)', () async {
      final runner = buildRunner(); // no globalRateLimiter

      final session = await sessions.getOrCreateMainSession();
      worker.responseText = 'done';
      final turnId = await runner.reserveTurn(session.id).timeout(const Duration(seconds: 2));

      expect(turnId, isNotEmpty);
      runner.executeTurn(session.id, turnId, [
        {'role': 'user', 'content': 'test'},
      ]);
      await runner.waitForOutcome(session.id, turnId);
    });

    test('80% warning — emitted once when crossing threshold', () async {
      final sse = RecordingSseBroadcast();
      // limit of 5, use 4 (80%) via injectable now
      final t0 = DateTime.now();
      final limiter = SlidingWindowRateLimiter(limit: 5, window: const Duration(minutes: 1));
      // Pre-fill 4 events to reach 80%
      limiter.check('global', now: t0);
      limiter.check('global', now: t0.add(const Duration(seconds: 1)));
      limiter.check('global', now: t0.add(const Duration(seconds: 2)));
      limiter.check('global', now: t0.add(const Duration(seconds: 3)));

      final runner = buildRunner(globalRateLimiter: limiter, sse: sse);
      final session = await sessions.getOrCreateMainSession();
      worker.responseText = 'done';

      // Next check() will be 5th event = 100% usage which crosses 80% threshold.
      // But the deferral loop calls check('global') which records the event.
      // After recording, usage goes to 100% and we're at limit = loop defers.
      // We need to pre-fill only 4 to let the 5th pass.
      // Actually: with 4 pre-filled, usage = 4/5 = 80% -> warning emitted.
      // The 5th call to check() passes (records to 5/5) -> turn proceeds.
      final turnId = await runner.reserveTurn(session.id).timeout(const Duration(seconds: 5));
      runner.executeTurn(session.id, turnId, [
        {'role': 'user', 'content': 'test'},
      ]);
      await runner.waitForOutcome(session.id, turnId);

      expect(sse.events, contains('rate_limit_warning'));
    });

    test('turns at limit — deferred until window slides', () async {
      // Use a very short window so the test completes quickly.
      final limiter = SlidingWindowRateLimiter(limit: 1, window: const Duration(milliseconds: 150));
      // Fill the single allowed slot — limiter is now at capacity.
      limiter.check('global');
      expect(limiter.check('global'), isFalse); // verify at limit

      final runner = buildRunner(globalRateLimiter: limiter);
      final session = await sessions.getOrCreateMainSession();
      worker.responseText = 'done';

      // reserveTurn must defer until the 150ms window expires and then proceed.
      final turnId = await runner
          .reserveTurn(session.id)
          .timeout(const Duration(seconds: 5)); // generous safety timeout
      expect(turnId, isNotEmpty);

      runner.executeTurn(session.id, turnId, [
        {'role': 'user', 'content': 'test'},
      ]);
      await runner.waitForOutcome(session.id, turnId);
    });
  });
}
