import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

void main() {
  group('ThreadBinding', () {
    final binding = ThreadBinding.task(
      channelType: 'googlechat',
      threadId: 'spaces/AAAA/threads/BBBB',
      taskId: 'task-123',
      sessionKey: 'agent:main:dm:googlechat:spaces%2FAAAA',
      createdAt: DateTime.utc(2026, 3, 21, 10, 0, 0),
      lastActivity: DateTime.utc(2026, 3, 21, 11, 0, 0),
    );

    test('key() produces compound key', () {
      expect(
        ThreadBinding.key('googlechat', 'spaces/AAAA/threads/BBBB'),
        equals('googlechat::spaces/AAAA/threads/BBBB'),
      );
    });

    test('toJson() serializes all fields with ISO 8601 timestamps', () {
      final json = binding.toJson();
      expect(json['channelType'], equals('googlechat'));
      expect(json['threadId'], equals('spaces/AAAA/threads/BBBB'));
      expect(json['taskId'], equals('task-123'));
      expect(json['sessionKey'], equals('agent:main:dm:googlechat:spaces%2FAAAA'));
      expect(json['createdAt'], equals('2026-03-21T10:00:00.000Z'));
      expect(json['lastActivity'], equals('2026-03-21T11:00:00.000Z'));
    });

    test('fromJson() round-trips correctly', () {
      final json = binding.toJson();
      final restored = ThreadBinding.fromJson(json);
      expect(restored.channelType, equals(binding.channelType));
      expect(restored.threadId, equals(binding.threadId));
      expect(restored.targetId, equals(binding.targetId));
      expect(restored.sessionKey, equals(binding.sessionKey));
      expect(restored.createdAt, equals(binding.createdAt));
      expect(restored.lastActivity, equals(binding.lastActivity));
    });

    test('copyWith(lastActivity:) returns new instance with updated timestamp', () {
      final updated = binding.copyWith(lastActivity: DateTime.utc(2026, 3, 21, 12, 0, 0));
      expect(updated.lastActivity, equals(DateTime.utc(2026, 3, 21, 12, 0, 0)));
      // Other fields unchanged.
      expect(updated.channelType, equals(binding.channelType));
      expect(updated.threadId, equals(binding.threadId));
      expect(updated.targetId, equals(binding.targetId));
      expect(updated.sessionKey, equals(binding.sessionKey));
      expect(updated.createdAt, equals(binding.createdAt));
    });

    test('copyWith() with no arguments returns copy of original', () {
      final copy = binding.copyWith();
      expect(copy.lastActivity, equals(binding.lastActivity));
    });
  });

  group('ThreadBindingStore — in-memory operations', () {
    late Directory tempDir;
    late File tempFile;
    late ThreadBindingStore store;

    ThreadBinding makeBinding({
      String channelType = 'googlechat',
      String threadId = 'spaces/X/threads/Y',
      String taskId = 'task-abc',
      String sessionKey = 'sk:1',
    }) {
      final now = DateTime.now();
      return ThreadBinding.task(
        channelType: channelType,
        threadId: threadId,
        taskId: taskId,
        sessionKey: sessionKey,
        createdAt: now,
        lastActivity: now,
      );
    }

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('thread_binding_test_');
      tempFile = File('${tempDir.path}/thread-bindings.json');
      store = ThreadBindingStore(tempFile);
    });

    tearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    test('create() followed by lookupByThread() returns the binding', () async {
      final b = makeBinding();
      await store.create(b);
      final found = store.lookupByThread('googlechat', 'spaces/X/threads/Y');
      expect(found, isNotNull);
      expect(found!.targetId, equals('task-abc'));
    });

    test('lookupByThread() returns null for unknown thread', () {
      expect(store.lookupByThread('googlechat', 'spaces/UNKNOWN/threads/Z'), isNull);
    });

    test('lookupByTask() returns bindings by task ID', () async {
      final b = makeBinding(taskId: 'task-xyz');
      await store.create(b);
      final found = store.lookupByTask('task-xyz');
      expect(found, hasLength(1));
      expect(found.single.threadId, equals('spaces/X/threads/Y'));
    });

    test('lookupByTask() returns empty list for unknown task', () {
      expect(store.lookupByTask('no-such-task'), isEmpty);
    });

    test('lookupByTask() returns all bindings for a task across channels', () async {
      await store.create(makeBinding(channelType: 'googlechat', threadId: 'spaces/X/threads/A', taskId: 'task-xyz'));
      await store.create(makeBinding(channelType: 'whatsapp', threadId: 'group-a@g.us', taskId: 'task-xyz'));
      await store.create(makeBinding(channelType: 'signal', threadId: 'signal-group-1', taskId: 'task-xyz'));

      final found = store.lookupByTask('task-xyz');
      expect(found, hasLength(3));
      expect(found.map((binding) => binding.channelType), containsAll(<String>['googlechat', 'whatsapp', 'signal']));
    });

    test('create() overwrites existing binding for same thread (idempotent)', () async {
      final b1 = makeBinding(taskId: 'task-1');
      final b2 = makeBinding(taskId: 'task-2');
      await store.create(b1);
      await store.create(b2);
      final found = store.lookupByThread('googlechat', 'spaces/X/threads/Y');
      expect(found!.targetId, equals('task-2'));
    });

    test('delete() removes binding; subsequent lookup returns null', () async {
      final b = makeBinding();
      await store.create(b);
      await store.delete('googlechat', 'spaces/X/threads/Y');
      expect(store.lookupByThread('googlechat', 'spaces/X/threads/Y'), isNull);
    });

    test('updateLastActivity() updates timestamp', () async {
      final b = makeBinding();
      await store.create(b);
      final newTime = DateTime.utc(2030, 1, 1);
      await store.updateLastActivity('googlechat', 'spaces/X/threads/Y', newTime);
      final found = store.lookupByThread('googlechat', 'spaces/X/threads/Y');
      expect(found!.lastActivity, equals(newTime));
    });

    test('updateLastActivity() for unknown binding is a no-op', () async {
      // Should not throw.
      await expectLater(store.updateLastActivity('googlechat', 'no-such-thread', DateTime.now()), completes);
    });

    test('reconcile() removes bindings for tasks not in active set', () async {
      await store.create(makeBinding(taskId: 'task-active', threadId: 'spaces/X/threads/A'));
      await store.create(makeBinding(taskId: 'task-terminal', threadId: 'spaces/X/threads/B'));
      final pruned = await store.reconcile(activeTaskIds: {'task-active'}, activeRunIds: const {});
      expect(pruned, equals(1));
      expect(store.lookupByThread('googlechat', 'spaces/X/threads/A'), isNotNull);
      expect(store.lookupByThread('googlechat', 'spaces/X/threads/B'), isNull);
    });

    test('reconcile() preserves bindings for active tasks', () async {
      await store.create(makeBinding(taskId: 'task-1', threadId: 'spaces/X/threads/1'));
      await store.create(makeBinding(taskId: 'task-2', threadId: 'spaces/X/threads/2'));
      final pruned = await store.reconcile(activeTaskIds: {'task-1', 'task-2'}, activeRunIds: const {});
      expect(pruned, equals(0));
    });

    test('reconcile() returns count of pruned bindings', () async {
      await store.create(makeBinding(taskId: 'task-a', threadId: 'spaces/X/threads/A'));
      await store.create(makeBinding(taskId: 'task-b', threadId: 'spaces/X/threads/B'));
      await store.create(makeBinding(taskId: 'task-c', threadId: 'spaces/X/threads/C'));
      final pruned = await store.reconcile(activeTaskIds: {'task-a'}, activeRunIds: const {});
      expect(pruned, equals(2));
    });

    test('deleteByTaskId() removes all bindings for the task', () async {
      for (final thread in ['spaces/X/threads/A', 'spaces/X/threads/B', 'spaces/Y/threads/C']) {
        await store.create(makeBinding(channelType: 'googlechat', threadId: thread, taskId: 'task-xyz'));
      }
      await store.create(makeBinding(channelType: 'googlechat', threadId: 'spaces/X/threads/D', taskId: 'task-123'));

      final removed = await store.deleteByTaskId('task-xyz');

      expect(removed, hasLength(3));
      expect(store.lookupByThread('googlechat', 'spaces/X/threads/A'), isNull);
      expect(store.lookupByThread('googlechat', 'spaces/X/threads/B'), isNull);
      expect(store.lookupByThread('googlechat', 'spaces/Y/threads/C'), isNull);
      expect(store.lookupByThread('googlechat', 'spaces/X/threads/D'), isNotNull);
    });

    test('deleteByTaskId() returns empty list when no binding exists', () async {
      expect(await store.deleteByTaskId('missing-task'), isEmpty);
    });
  });

  group('ThreadBindingStore — persistence', () {
    late Directory tempDir;
    late File tempFile;

    ThreadBinding makeBinding({
      String channelType = 'googlechat',
      String threadId = 'spaces/X/threads/Y',
      String taskId = 'task-abc',
      String sessionKey = 'sk:1',
    }) {
      final now = DateTime.utc(2026, 3, 21);
      return ThreadBinding.task(
        channelType: channelType,
        threadId: threadId,
        taskId: taskId,
        sessionKey: sessionKey,
        createdAt: now,
        lastActivity: now,
      );
    }

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('thread_binding_persist_test_');
      tempFile = File('${tempDir.path}/thread-bindings.json');
    });

    tearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    test(
      'load() keeps every well-formed row whichever channels are registered, and a row without a kind is a task',
      () async {
        // The store loads before any channel registers, so a load-time rule on the channel
        // would delete and rewrite away rows whose adapter simply is not registered yet.
        final now = DateTime.utc(2026, 3, 21).toIso8601String();
        final rows = [
          {
            'channelType': 'googlechat',
            'threadId': 'spaces/X/threads/Y',
            'kind': 'task',
            'taskId': 'task-gchat',
            'sessionKey': 'sk:1',
            'createdAt': now,
            'lastActivity': now,
          },
          {
            'channelType': 'slack',
            'threadId': 'C1:1700000000.000000',
            'kind': 'run',
            'runId': 'run-slack',
            'createdAt': now,
            'lastActivity': now,
          },
          {
            'channelType': 'whatsapp',
            'threadId': 'group-a@g.us',
            'taskId': 'task-legacy',
            'sessionKey': 'sk:2',
            'createdAt': now,
            'lastActivity': now,
          },
        ];
        tempFile.writeAsStringSync(jsonEncode(rows));

        final store = ThreadBindingStore(tempFile);
        await store.load();

        expect(store.lookupByThread('googlechat', 'spaces/X/threads/Y')?.targetId, 'task-gchat');
        final run = store.lookupByThread('slack', 'C1:1700000000.000000');
        expect((run?.kind, run?.targetId, run?.sessionKey), (ThreadBindingKind.run, 'run-slack', null));
        final legacy = store.lookupByThread('whatsapp', 'group-a@g.us');
        expect((legacy?.kind, legacy?.targetId), (ThreadBindingKind.task, 'task-legacy'));
        expect(store.lookupByTask('task-legacy'), hasLength(1));
        expect(store.lookupByRun('run-slack'), hasLength(1));
        expect(jsonDecode(tempFile.readAsStringSync()), rows, reason: 'load() rewrites nothing');
      },
    );

    test('load() skips a row of an unknown kind and keeps the rest', () async {
      final now = DateTime.utc(2026, 3, 21).toIso8601String();
      tempFile.writeAsStringSync(
        jsonEncode([
          {
            'channelType': 'slack',
            'threadId': 'C1:1',
            'kind': 'job',
            'jobId': 'j',
            'createdAt': now,
            'lastActivity': now,
          },
          {
            'channelType': 'googlechat',
            'threadId': 'spaces/X/threads/Y',
            'taskId': 'task-abc',
            'sessionKey': 'sk:1',
            'createdAt': now,
            'lastActivity': now,
          },
        ]),
      );

      final store = ThreadBindingStore(tempFile);
      await store.load();

      expect(store.lookupByThread('slack', 'C1:1'), isNull);
      expect(store.lookupByThread('googlechat', 'spaces/X/threads/Y'), isNotNull);
    });

    test('a run binding round-trips through the file under its runId key', () async {
      final now = DateTime.utc(2026, 3, 21);
      final store1 = ThreadBindingStore(tempFile);
      await store1.create(
        ThreadBinding.run(channelType: 'slack', threadId: 'C1:1.5', runId: 'run-1', createdAt: now, lastActivity: now),
      );

      final stored = (jsonDecode(tempFile.readAsStringSync()) as List).single as Map<String, dynamic>;
      expect(stored['kind'], 'run');
      expect(stored['runId'], 'run-1');
      expect(stored.containsKey('taskId'), isFalse);
      expect(stored.containsKey('sessionKey'), isFalse);
      final store2 = ThreadBindingStore(tempFile);
      await store2.load();
      expect(store2.lookupByRun('run-1').single.threadId, 'C1:1.5');
    });

    test('create() persists to JSON file; new store load() reads it back', () async {
      final store1 = ThreadBindingStore(tempFile);
      await store1.load();
      await store1.create(makeBinding());

      final store2 = ThreadBindingStore(tempFile);
      await store2.load();
      final found = store2.lookupByThread('googlechat', 'spaces/X/threads/Y');
      expect(found, isNotNull);
      expect(found!.targetId, equals('task-abc'));
    });

    test('delete() persists; reloaded store does not have the binding', () async {
      final store1 = ThreadBindingStore(tempFile);
      await store1.load();
      await store1.create(makeBinding());
      await store1.delete('googlechat', 'spaces/X/threads/Y');

      final store2 = ThreadBindingStore(tempFile);
      await store2.load();
      expect(store2.lookupByThread('googlechat', 'spaces/X/threads/Y'), isNull);
    });

    test('load() with missing file starts empty without error', () async {
      expect(tempFile.existsSync(), isFalse);
      final store = ThreadBindingStore(tempFile);
      await expectLater(store.load(), completes);
      expect(store.lookupByThread('googlechat', 'any'), isNull);
    });

    test('load() with corrupt JSON starts empty', () async {
      tempFile.writeAsStringSync('NOT VALID JSON }{');
      final store = ThreadBindingStore(tempFile);
      await expectLater(store.load(), completes);
      expect(store.lookupByThread('googlechat', 'any'), isNull);
    });

    test('load() with non-array JSON starts empty', () async {
      tempFile.writeAsStringSync(jsonEncode({'foo': 'bar'}));
      final store = ThreadBindingStore(tempFile);
      await expectLater(store.load(), completes);
      expect(store.lookupByThread('googlechat', 'any'), isNull);
    });

    test('reconcile() persists after pruning', () async {
      final store1 = ThreadBindingStore(tempFile);
      await store1.load();
      await store1.create(makeBinding(taskId: 'active', threadId: 'spaces/X/threads/A'));
      await store1.create(makeBinding(taskId: 'terminal', threadId: 'spaces/X/threads/B'));
      await store1.reconcile(activeTaskIds: {'active'}, activeRunIds: const {});

      final store2 = ThreadBindingStore(tempFile);
      await store2.load();
      expect(store2.lookupByThread('googlechat', 'spaces/X/threads/A'), isNotNull);
      expect(store2.lookupByThread('googlechat', 'spaces/X/threads/B'), isNull);
    });
  });

  group('ThreadBindingStore — run bindings', () {
    late Directory tempDir;
    late ThreadBindingStore store;
    final now = DateTime.utc(2026, 3, 21);

    ThreadBinding task(String id, String thread, {DateTime? lastActivity}) => ThreadBinding.task(
      channelType: 'slack',
      threadId: thread,
      taskId: id,
      sessionKey: 'sk:$id',
      createdAt: now,
      lastActivity: lastActivity ?? now,
    );

    ThreadBinding run(String id, String thread, {DateTime? lastActivity}) => ThreadBinding.run(
      channelType: 'slack',
      threadId: thread,
      runId: id,
      createdAt: now,
      lastActivity: lastActivity ?? now,
    );

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('thread_binding_run_test_');
      store = ThreadBindingStore(File('${tempDir.path}/thread-bindings.json'));
    });

    tearDown(() => tempDir.deleteSync(recursive: true));

    test('a task and a run sharing an ID are looked up and deleted by kind', () async {
      await store.create(task('same', 'C1:1'));
      await store.create(run('same', 'C1:2'));

      expect(store.lookupByTask('same').single.threadId, 'C1:1');
      expect(store.lookupByRun('same').single.threadId, 'C1:2');

      final removed = await store.deleteByTarget(ThreadBindingKind.run, 'same');

      expect(removed.single.threadId, 'C1:2');
      expect(store.lookupByTask('same'), hasLength(1));
      expect(await store.deleteByTaskId('same'), hasLength(1));
      expect(store.lookupByThread('slack', 'C1:1'), isNull);
    });

    test('the idle sweep removes an idle task binding and keeps an equally idle run binding', () async {
      final idle = now.subtract(const Duration(days: 2));
      await store.create(task('t', 'C1:1', lastActivity: idle));
      await store.create(run('r', 'C1:2', lastActivity: idle));

      final expired = await store.removeExpiredBindings(now.subtract(const Duration(hours: 1)));

      expect(expired.map((binding) => binding.targetId), ['t']);
      expect(store.lookupByRun('r'), hasLength(1));
    });

    test('reconcile() judges each binding against the active set of its own kind', () async {
      await store.create(task('active-task', 'C1:1'));
      await store.create(task('gone-task', 'C1:2'));
      await store.create(run('active-run', 'C1:3'));
      await store.create(run('gone-run', 'C1:4'));
      // A run ID in the task set (and the reverse) must not keep a binding of the other kind.
      await store.create(run('active-task', 'C1:5'));

      final pruned = await store.reconcile(activeTaskIds: {'active-task'}, activeRunIds: {'active-run'});

      expect(pruned, 3);
      expect(store.lookupByThread('slack', 'C1:1'), isNotNull);
      expect(store.lookupByThread('slack', 'C1:3'), isNotNull);
      expect(store.lookupByThread('slack', 'C1:2'), isNull);
      expect(store.lookupByThread('slack', 'C1:4'), isNull);
      expect(store.lookupByThread('slack', 'C1:5'), isNull);
    });
  });

  group('FeaturesConfig / ThreadBindingFeatureConfig', () {
    test('fromYaml(null) returns defaults (disabled)', () {
      final cfg = FeaturesConfig.fromYaml(null);
      expect(cfg.threadBinding.enabled, isFalse);
    });

    test('fromYaml with thread_binding enabled returns enabled', () {
      final cfg = FeaturesConfig.fromYaml({
        'thread_binding': {'enabled': true},
      });
      expect(cfg.threadBinding.enabled, isTrue);
    });

    test('fromYaml with thread_binding disabled returns disabled', () {
      final cfg = FeaturesConfig.fromYaml({
        'thread_binding': {'enabled': false},
      });
      expect(cfg.threadBinding.enabled, isFalse);
    });

    test('fromYaml({}) returns disabled (missing key = default)', () {
      final cfg = FeaturesConfig.fromYaml({});
      expect(cfg.threadBinding.enabled, isFalse);
    });

    test('fromYaml parses idle_timeout_minutes', () {
      final cfg = FeaturesConfig.fromYaml({
        'thread_binding': {'enabled': true, 'idle_timeout_minutes': 30},
      });
      expect(cfg.threadBinding.idleTimeoutMinutes, 30);
    });

    test('idle_timeout_minutes defaults to 60 when omitted', () {
      final cfg = FeaturesConfig.fromYaml({
        'thread_binding': {'enabled': true},
      });
      expect(cfg.threadBinding.idleTimeoutMinutes, 60);
    });

    test('toJson round-trips correctly', () {
      final cfg = FeaturesConfig(threadBinding: ThreadBindingFeatureConfig(enabled: true, idleTimeoutMinutes: 45));
      final json = cfg.toJson();
      expect(json['threadBinding']['enabled'], isTrue);
      expect(json['threadBinding']['idleTimeoutMinutes'], 45);
    });
  });
}
