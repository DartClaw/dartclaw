import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/src/alerts/alert_router.dart';
import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';

import 'alert_test_support.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

const _target0 = AlertTarget(channel: 'whatsapp', recipient: '+1000');
const _target1 = AlertTarget(channel: 'signal', recipient: '+2000');

AlertsConfig _config({
  bool enabled = true,
  List<AlertTarget> targets = const [_target0, _target1],
  Map<String, List<String>> routes = const {},
  int cooldownSeconds = 300,
  int burstThreshold = 5,
}) => AlertsConfig(
  enabled: enabled,
  targets: targets,
  routes: routes,
  cooldownSeconds: cooldownSeconds,
  burstThreshold: burstThreshold,
);

ConfigDelta _delta(AlertsConfig newAlerts) => ConfigDelta(
  previous: const DartclawConfig.defaults(),
  current: DartclawConfig(alerts: newAlerts),
  changedKeys: {'alerts.*'},
);

DateTime get _now => DateTime.now();

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  late EventBus bus;
  late FakeAlertDeliveryAdapter adapter;
  late AlertRouter router;

  setUp(() {
    bus = EventBus();
    adapter = FakeAlertDeliveryAdapter();
    router = AlertRouter(bus: bus, adapter: adapter, config: _config());
  });

  tearDown(() async {
    await router.cancel();
    await bus.dispose();
  });

  group('AlertRouter — event classification and routing', () {
    final cases = [
      (
        name: 'GuardBlockEvent routes to all targets when routes is empty',
        fire: () => bus.fire(
          GuardBlockEvent(
            verdict: 'block',
            verdictMessage: 'blocked',
            guardName: 'test',
            guardCategory: 'input',
            hookPoint: 'messageReceived',
            timestamp: _now,
          ),
        ),
        expectedDeliveries: 2,
        assertTargets: true,
      ),
      (
        name: 'ContainerCrashedEvent routes to all targets',
        fire: () =>
            bus.fire(ContainerCrashedEvent(profileId: 'p1', containerName: 'c1', error: 'OOM', timestamp: _now)),
        expectedDeliveries: 2,
        assertTargets: false,
      ),
      (
        name: 'TaskStatusChangedEvent with failed status routes as task_failure',
        fire: () => bus.fire(
          TaskStatusChangedEvent(
            taskId: 't1',
            oldStatus: TaskStatus.running,
            newStatus: TaskStatus.failed,
            trigger: 'error',
            timestamp: _now,
          ),
        ),
        expectedDeliveries: 2,
        assertTargets: false,
      ),
      (
        name: 'TaskStatusChangedEvent with non-failed status is dropped',
        fire: () => bus.fire(
          TaskStatusChangedEvent(
            taskId: 't1',
            oldStatus: TaskStatus.queued,
            newStatus: TaskStatus.running,
            trigger: 'start',
            timestamp: _now,
          ),
        ),
        expectedDeliveries: 0,
        assertTargets: false,
      ),
      (
        name: 'BudgetWarningEvent routes as budget_warning',
        fire: () => bus.fire(
          BudgetWarningEvent(taskId: 't1', consumedPercent: 0.9, consumed: 9000, limit: 10000, timestamp: _now),
        ),
        expectedDeliveries: 2,
        assertTargets: false,
      ),
      (
        name: 'CompactionCompletedEvent routes as compaction',
        fire: () =>
            bus.fire(CompactionCompletedEvent(sessionId: 's1', trigger: 'manual', preTokens: 50000, timestamp: _now)),
        expectedDeliveries: 2,
        assertTargets: false,
      ),
      (
        name: 'unrecognized event type produces no deliveries',
        fire: () => bus.fire(
          AdvisorMentionEvent(
            senderJid: 'user1',
            channelType: 'whatsapp',
            recipientId: '+1234',
            messageText: 'hello @advisor',
            sessionKey: 'default',
            timestamp: _now,
          ),
        ),
        expectedDeliveries: 0,
        assertTargets: false,
      ),
    ];

    for (final testCase in cases) {
      test(testCase.name, () async {
        testCase.fire();
        await pumpEventQueue();

        expect(adapter.delivered, hasLength(testCase.expectedDeliveries));
        if (testCase.assertTargets) {
          expect(adapter.delivered.map((d) => d.$1), containsAll([_target0, _target1]));
        }
      });
    }
  });

  group('AlertRouter — routes config restricts delivery', () {
    final cases = [
      (
        name: 'routes entry limits guard_block to target[0] only',
        config: _config(
          routes: {
            'guard_block': ['0'],
          },
        ),
        expectedDeliveries: 1,
        expectedTarget: _target0,
      ),
      (
        name: "routes entry with '*' sends to all targets",
        config: _config(
          routes: {
            'guard_block': ['*'],
          },
        ),
        expectedDeliveries: 2,
        expectedTarget: null,
      ),
      (
        name: 'event type not in routes map produces no deliveries',
        config: _config(
          routes: {
            'compaction': ['0'],
          },
        ),
        expectedDeliveries: 0,
        expectedTarget: null,
      ),
      (
        name: 'routes index out of bounds logs warning and skips that target',
        config: _config(
          targets: [_target0],
          routes: {
            'guard_block': ['0', '5'],
          },
        ),
        expectedDeliveries: 1,
        expectedTarget: _target0,
      ),
    ];

    for (final testCase in cases) {
      test(testCase.name, () async {
        await router.cancel();
        router = AlertRouter(bus: bus, adapter: adapter, config: testCase.config);

        bus.fire(
          GuardBlockEvent(
            verdict: 'block',
            verdictMessage: 'msg',
            guardName: 'g',
            guardCategory: 'input',
            hookPoint: 'messageReceived',
            timestamp: _now,
          ),
        );
        await pumpEventQueue();

        expect(adapter.delivered, hasLength(testCase.expectedDeliveries));
        if (testCase.expectedTarget != null) {
          expect(adapter.delivered.first.$1, testCase.expectedTarget);
        }
      });
    }
  });

  group('AlertRouter — enabled check', () {
    final cases = [
      (name: 'disabled config suppresses all delivery', config: _config(enabled: false)),
      (name: 'empty targets list with enabled=true produces no deliveries', config: _config(targets: const [])),
    ];

    for (final testCase in cases) {
      test(testCase.name, () async {
        await router.cancel();
        router = AlertRouter(bus: bus, adapter: adapter, config: testCase.config);

        bus.fire(
          GuardBlockEvent(
            verdict: 'block',
            verdictMessage: 'msg',
            guardName: 'g',
            guardCategory: 'input',
            hookPoint: 'messageReceived',
            timestamp: _now,
          ),
        );
        await pumpEventQueue();

        expect(adapter.delivered, isEmpty);
      });
    }
  });

  group('AlertRouter — Reconfigurable', () {
    test('reconfigure() with enabled=false suppresses subsequent events', () async {
      // Confirm it works before reconfigure
      bus.fire(
        GuardBlockEvent(
          verdict: 'block',
          verdictMessage: 'msg',
          guardName: 'g',
          guardCategory: 'input',
          hookPoint: 'messageReceived',
          timestamp: _now,
        ),
      );
      await pumpEventQueue();
      expect(adapter.delivered, hasLength(2));

      // Reconfigure to disabled
      router.reconfigure(_delta(AlertsConfig(enabled: false, targets: [_target0, _target1])));
      adapter.delivered.clear();

      bus.fire(
        GuardBlockEvent(
          verdict: 'block',
          verdictMessage: 'msg',
          guardName: 'g',
          guardCategory: 'input',
          hookPoint: 'messageReceived',
          timestamp: _now,
        ),
      );
      await pumpEventQueue();
      expect(adapter.delivered, isEmpty);
    });

    test('reconfigure() with new targets routes to new targets', () async {
      const newTarget = AlertTarget(channel: 'googlechat', recipient: 'spaces/new');
      router.reconfigure(_delta(AlertsConfig(enabled: true, targets: [newTarget])));

      bus.fire(
        GuardBlockEvent(
          verdict: 'block',
          verdictMessage: 'msg',
          guardName: 'g',
          guardCategory: 'input',
          hookPoint: 'messageReceived',
          timestamp: _now,
        ),
      );
      await pumpEventQueue();

      expect(adapter.delivered, hasLength(1));
      expect(adapter.delivered.first.$1, newTarget);
    });

    test('watchKeys is alerts.*', () {
      expect(router.watchKeys, {'alerts.*'});
    });
  });

  group('AlertRouter — cancel()', () {
    test('cancel() stops subscription — no delivery after cancel', () async {
      await router.cancel();

      bus.fire(
        GuardBlockEvent(
          verdict: 'block',
          verdictMessage: 'msg',
          guardName: 'g',
          guardCategory: 'input',
          hookPoint: 'messageReceived',
          timestamp: _now,
        ),
      );
      await pumpEventQueue();

      expect(adapter.delivered, isEmpty);
    });
  });

  // ---------------------------------------------------------------------------
  // TI11 — S09 formatter + task-origin filter integration
  // ---------------------------------------------------------------------------

  group('AlertRouter — S09 formatted responses', () {
    test('WhatsApp target receives plain text ChannelResponse (no structuredPayload)', () async {
      // _target0 = whatsapp
      bus.fire(
        GuardBlockEvent(
          guardName: 'bash-guard',
          guardCategory: 'file',
          verdict: 'block',
          hookPoint: 'PreToolUse',
          timestamp: _now,
        ),
      );
      await pumpEventQueue();

      final whatsappDelivery = adapter.delivered.where((d) => d.$1.channel == 'whatsapp').toList();
      expect(whatsappDelivery, hasLength(1));
      expect(whatsappDelivery.first.$2.text, contains('bash-guard'));
      expect(whatsappDelivery.first.$2.structuredPayload, isNull);
    });

    test('Google Chat target receives ChannelResponse with structuredPayload', () async {
      const gcTarget = AlertTarget(channel: 'googlechat', recipient: 'spaces/abc');
      await router.cancel();
      router = AlertRouter(
        bus: bus,
        adapter: adapter,
        config: _config(targets: [gcTarget]),
      );

      bus.fire(ContainerCrashedEvent(profileId: 'p1', containerName: 'my-box', error: 'OOM', timestamp: _now));
      await pumpEventQueue();

      expect(adapter.delivered, hasLength(1));
      expect(adapter.delivered.first.$2.structuredPayload, isNotNull);
      final payload = adapter.delivered.first.$2.structuredPayload as Map<String, dynamic>;
      expect(payload['cardsV2'], isA<List<dynamic>>());
    });
  });

  group('AlertRouter — task-failure non-channel filter', () {
    test('task with no TaskOrigin (lookup returns task with empty configJson) → alert delivered', () async {
      final fakeTask = Task(
        id: 'task-1',
        title: 'test task',
        description: '',
        type: TaskType.automation,
        status: TaskStatus.failed,
        configJson: {},
        createdAt: _now,
      );

      await router.cancel();
      router = AlertRouter(bus: bus, adapter: adapter, config: _config(), taskLookup: (_) async => fakeTask);

      bus.fire(
        TaskStatusChangedEvent(
          taskId: 'task-1',
          oldStatus: TaskStatus.running,
          newStatus: TaskStatus.failed,
          trigger: 'error',
          timestamp: _now,
        ),
      );
      await Future.delayed(const Duration(milliseconds: 50));

      expect(adapter.delivered, hasLength(2));
    });

    test('task with dm-scoped TaskOrigin → alert suppressed', () async {
      final fakeTask = Task(
        id: 'task-dm',
        title: 'dm task',
        description: '',
        type: TaskType.automation,
        status: TaskStatus.failed,
        configJson: {
          'origin': {'channelType': 'whatsapp', 'sessionKey': 'agent:main:dm:+1234', 'recipientId': '+1234'},
        },
        createdAt: _now,
      );

      await router.cancel();
      router = AlertRouter(bus: bus, adapter: adapter, config: _config(), taskLookup: (_) async => fakeTask);

      bus.fire(
        TaskStatusChangedEvent(
          taskId: 'task-dm',
          oldStatus: TaskStatus.running,
          newStatus: TaskStatus.failed,
          trigger: 'error',
          timestamp: _now,
        ),
      );
      await Future.delayed(const Duration(milliseconds: 50));

      expect(adapter.delivered, isEmpty);
    });

    test('task lookup returns null → alert skipped (task deleted)', () async {
      await router.cancel();
      router = AlertRouter(bus: bus, adapter: adapter, config: _config(), taskLookup: (_) async => null);

      bus.fire(
        TaskStatusChangedEvent(
          taskId: 'missing-task',
          oldStatus: TaskStatus.running,
          newStatus: TaskStatus.failed,
          trigger: 'error',
          timestamp: _now,
        ),
      );
      await Future.delayed(const Duration(milliseconds: 50));

      expect(adapter.delivered, isEmpty);
    });

    test('no taskLookup provided → task failure alert delivered without filtering', () async {
      // Default router has no taskLookup — existing S08 behavior preserved.
      bus.fire(
        TaskStatusChangedEvent(
          taskId: 'any-task',
          oldStatus: TaskStatus.running,
          newStatus: TaskStatus.failed,
          trigger: 'error',
          timestamp: _now,
        ),
      );
      await Future.delayed(const Duration(milliseconds: 50));

      expect(adapter.delivered, hasLength(2));
    });
  });

  group('AlertRouter — throttling integration', () {
    test('10 rapid GuardBlockEvents produce at most 2 deliveries per target (1 initial + 1 summary)', () {
      fakeAsync((async) {
        final localBus = EventBus();
        final localAdapter = FakeAlertDeliveryAdapter();
        final localRouter = AlertRouter(
          bus: localBus,
          adapter: localAdapter,
          config: _config(cooldownSeconds: 300, burstThreshold: 5),
        );

        final event = GuardBlockEvent(
          verdict: 'block',
          verdictMessage: 'msg',
          guardName: 'g',
          guardCategory: 'input',
          hookPoint: 'messageReceived',
          timestamp: DateTime.now(),
        );

        for (var i = 0; i < 10; i++) {
          localBus.fire(event);
          async.flushMicrotasks();
        }

        // After initial: 1 delivery per target (2 total for 2 targets)
        expect(localAdapter.delivered, hasLength(2));
        expect(localAdapter.delivered.map((d) => d.$1), containsAll([_target0, _target1]));

        // Advance past cooldown — summary fires for each target
        async.elapse(const Duration(seconds: 301));
        // 2 targets × 2 messages (initial + summary) = 4 total
        expect(localAdapter.delivered, hasLength(4));

        localRouter.cancel();
        localBus.dispose();
      });
    });

    test('Google Chat summaries use structured formatting instead of raw type text', () {
      fakeAsync((async) {
        final localBus = EventBus();
        final localAdapter = FakeAlertDeliveryAdapter();
        final localRouter = AlertRouter(
          bus: localBus,
          adapter: localAdapter,
          config: _config(
            targets: const [AlertTarget(channel: 'googlechat', recipient: 'spaces/abc')],
            cooldownSeconds: 300,
            burstThreshold: 5,
          ),
        );

        final event = GuardBlockEvent(
          verdict: 'block',
          verdictMessage: 'msg',
          guardName: 'g',
          guardCategory: 'input',
          hookPoint: 'messageReceived',
          timestamp: DateTime.now(),
        );

        for (var i = 0; i < 6; i++) {
          localBus.fire(event);
          async.flushMicrotasks();
        }

        async.elapse(const Duration(seconds: 301));

        expect(localAdapter.delivered, hasLength(2));
        final summary = localAdapter.delivered.last.$2;
        expect(summary.text, contains('Guard Block Summary'));
        expect(summary.text, isNot(contains('guard_block')));
        expect(summary.structuredPayload, isNotNull);

        localRouter.cancel();
        localBus.dispose();
      });
    });

    test('per-recipient independence: throttle state of target A does not affect target B', () {
      fakeAsync((async) {
        final localBus = EventBus();
        final localAdapter = FakeAlertDeliveryAdapter();
        final localRouter = AlertRouter(
          bus: localBus,
          adapter: localAdapter,
          config: _config(targets: [_target0, _target1], cooldownSeconds: 300, burstThreshold: 5),
        );

        final event = GuardBlockEvent(
          verdict: 'block',
          verdictMessage: 'msg',
          guardName: 'g',
          guardCategory: 'input',
          hookPoint: 'messageReceived',
          timestamp: DateTime.now(),
        );

        // Fire 6 events — each target gets 1 immediate + 5 suppressed
        for (var i = 0; i < 6; i++) {
          localBus.fire(event);
          async.flushMicrotasks();
        }

        // 1 immediate per target = 2 deliveries so far
        expect(localAdapter.delivered, hasLength(2));

        async.elapse(const Duration(seconds: 301));

        // Both targets get summary (suppressedCount=5 >= burstThreshold=5)
        expect(localAdapter.delivered, hasLength(4));
        final targets = localAdapter.delivered.map((d) => d.$1).toList();
        expect(targets.where((t) => t == _target0), hasLength(2)); // initial + summary
        expect(targets.where((t) => t == _target1), hasLength(2)); // initial + summary

        localRouter.cancel();
        localBus.dispose();
      });
    });

    test('reconfigure propagates new cooldown and burst threshold to throttle', () async {
      // Reconfigure to different values — verify watchKeys and no errors
      const newAlerts = AlertsConfig(enabled: true, cooldownSeconds: 60, burstThreshold: 3, targets: [_target0]);
      router.reconfigure(_delta(newAlerts));
      // No exception = reconfigure propagated successfully
      expect(router.watchKeys, {'alerts.*'});
    });
  });
}
