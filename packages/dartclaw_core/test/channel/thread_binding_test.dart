import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

void main() {
  group('ThreadBinding', () {
    final binding = ThreadBinding(
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
      expect(restored.taskId, equals(binding.taskId));
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
      expect(updated.taskId, equals(binding.taskId));
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
      expect(found!.taskId, equals('task-abc'));
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
      expect(found!.taskId, equals('task-2'));
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
      final pruned = await store.reconcile({'task-active'});
      expect(pruned, equals(1));
      expect(store.lookupByThread('googlechat', 'spaces/X/threads/A'), isNotNull);
      expect(store.lookupByThread('googlechat', 'spaces/X/threads/B'), isNull);
    });

    test('reconcile() preserves bindings for active tasks', () async {
      await store.create(makeBinding(taskId: 'task-1', threadId: 'spaces/X/threads/1'));
      await store.create(makeBinding(taskId: 'task-2', threadId: 'spaces/X/threads/2'));
      final pruned = await store.reconcile({'task-1', 'task-2'});
      expect(pruned, equals(0));
    });

    test('reconcile() returns count of pruned bindings', () async {
      await store.create(makeBinding(taskId: 'task-a', threadId: 'spaces/X/threads/A'));
      await store.create(makeBinding(taskId: 'task-b', threadId: 'spaces/X/threads/B'));
      await store.create(makeBinding(taskId: 'task-c', threadId: 'spaces/X/threads/C'));
      final pruned = await store.reconcile({'task-a'});
      expect(pruned, equals(2));
    });

    test('deleteByTaskId() removes all bindings for the task', () async {
      await store.create(makeBinding(channelType: 'googlechat', threadId: 'spaces/X/threads/A', taskId: 'task-xyz'));
      await store.create(makeBinding(channelType: 'whatsapp', threadId: 'group-a@g.us', taskId: 'task-xyz'));
      await store.create(makeBinding(channelType: 'signal', threadId: 'signal-group-1', taskId: 'task-xyz'));
      await store.create(makeBinding(channelType: 'googlechat', threadId: 'spaces/X/threads/B', taskId: 'task-123'));

      final removed = store.deleteByTaskId('task-xyz');

      expect(removed, hasLength(3));
      expect(store.lookupByThread('googlechat', 'spaces/X/threads/A'), isNull);
      expect(store.lookupByThread('whatsapp', 'group-a@g.us'), isNull);
      expect(store.lookupByThread('signal', 'signal-group-1'), isNull);
      expect(store.lookupByThread('googlechat', 'spaces/X/threads/B'), isNotNull);
    });

    test('deleteByTaskId() returns empty list when no binding exists', () {
      expect(store.deleteByTaskId('missing-task'), isEmpty);
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
      tempDir = Directory.systemTemp.createTempSync('thread_binding_persist_test_');
      tempFile = File('${tempDir.path}/thread-bindings.json');
    });

    tearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    test('create() persists to JSON file; new store load() reads it back', () async {
      final store1 = ThreadBindingStore(tempFile);
      await store1.load();
      await store1.create(makeBinding());

      final store2 = ThreadBindingStore(tempFile);
      await store2.load();
      final found = store2.lookupByThread('googlechat', 'spaces/X/threads/Y');
      expect(found, isNotNull);
      expect(found!.taskId, equals('task-abc'));
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
      await store1.reconcile({'active'});

      final store2 = ThreadBindingStore(tempFile);
      await store2.load();
      expect(store2.lookupByThread('googlechat', 'spaces/X/threads/A'), isNotNull);
      expect(store2.lookupByThread('googlechat', 'spaces/X/threads/B'), isNull);
    });
  });

  group('extractThreadId', () {
    ChannelMessage makeMessage(Map<String, String> metadata) {
      return ChannelMessage(
        channelType: ChannelType.googlechat,
        senderJid: 'users/123',
        text: 'hello',
        metadata: metadata,
      );
    }

    test('returns threadName when present and non-empty', () {
      final msg = makeMessage({'threadName': 'spaces/X/threads/Y'});
      expect(extractThreadId(msg), equals('spaces/X/threads/Y'));
    });

    test('returns null for empty string', () {
      final msg = makeMessage({'threadName': ''});
      expect(extractThreadId(msg), isNull);
    });

    test('returns null when key is missing', () {
      final msg = makeMessage({});
      expect(extractThreadId(msg), isNull);
    });

    test('returns null when metadata has other keys but not threadName', () {
      final msg = makeMessage({'spaceName': 'spaces/X', 'senderDisplayName': 'Alice'});
      expect(extractThreadId(msg), isNull);
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
