import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late SessionService sessions;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_test_sessions_');
    sessions = SessionService(baseDir: tempDir.path);
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  group('createSession', () {
    test('creates session with UUID id', () async {
      final session = await sessions.createSession();
      expect(session.id, matches(RegExp(r'^[0-9a-f-]{36}$')));
      expect(session.title, isNull);
      expect(session.createdAt, isA<DateTime>());
      expect(session.updatedAt, isA<DateTime>());
    });

    test('creates directory and meta.json', () async {
      final session = await sessions.createSession();
      final dir = Directory('${tempDir.path}/${session.id}');
      expect(dir.existsSync(), isTrue);
      final meta = File('${dir.path}/meta.json');
      expect(meta.existsSync(), isTrue);
    });
  });

  group('getSession', () {
    test('returns session by id', () async {
      final created = await sessions.createSession();
      final fetched = await sessions.getSession(created.id);
      expect(fetched, isNotNull);
      expect(fetched!.id, equals(created.id));
    });

    test('returns null for non-existent id', () async {
      final result = await sessions.getSession('00000000-0000-0000-0000-000000000000');
      expect(result, isNull);
    });

    test('returns null for invalid UUID (path traversal defense)', () async {
      final result = await sessions.getSession('../etc/passwd');
      expect(result, isNull);
    });
  });

  group('listSessions', () {
    test('returns empty list when no sessions', () async {
      final list = await sessions.listSessions();
      expect(list, isEmpty);
    });

    test('returns sessions sorted by updatedAt DESC', () async {
      final s1 = await sessions.createSession();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final s2 = await sessions.createSession();

      final list = await sessions.listSessions();
      expect(list.length, equals(2));
      expect(list.first.id, equals(s2.id));
      expect(list.last.id, equals(s1.id));
    });
  });

  group('updateTitle', () {
    test('updates title and updatedAt', () async {
      final session = await sessions.createSession();
      final result = await sessions.updateTitle(session.id, 'New Title');
      expect(result, equals(1));

      final updated = await sessions.getSession(session.id);
      expect(updated!.title, equals('New Title'));
      expect(updated.updatedAt.isAfter(session.updatedAt) || updated.updatedAt == session.updatedAt, isTrue);
    });

    test('returns 0 for non-existent session', () async {
      final result = await sessions.updateTitle('00000000-0000-0000-0000-000000000000', 'Title');
      expect(result, equals(0));
    });
  });

  group('touchUpdatedAt', () {
    test('updates only updatedAt', () async {
      final session = await sessions.createSession();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await sessions.touchUpdatedAt(session.id);

      final updated = await sessions.getSession(session.id);
      expect(updated!.title, isNull);
      expect(updated.updatedAt.isAfter(session.updatedAt) || updated.updatedAt == session.updatedAt, isTrue);
    });
  });

  group('getOrCreateByKey', () {
    test('creates new session for unknown key', () async {
      final session = await sessions.getOrCreateByKey('cron:daily-summary');
      expect(session.id, matches(RegExp(r'^[0-9a-f-]{36}$')));
    });

    test('returns same session for same key', () async {
      final first = await sessions.getOrCreateByKey('cron:daily-summary');
      final second = await sessions.getOrCreateByKey('cron:daily-summary');
      expect(second.id, equals(first.id));
    });

    test('returns different sessions for different keys', () async {
      final a = await sessions.getOrCreateByKey('cron:job-a');
      final b = await sessions.getOrCreateByKey('cron:job-b');
      expect(a.id, isNot(equals(b.id)));
    });

    test('recreates session if mapped UUID was deleted (stale mapping)', () async {
      final first = await sessions.getOrCreateByKey('cron:stale');
      await sessions.deleteSession(first.id);

      final second = await sessions.getOrCreateByKey('cron:stale');
      expect(second.id, isNot(equals(first.id)));
    });

    test('session is retrievable via getSession', () async {
      final keyed = await sessions.getOrCreateByKey('agent:main');
      final fetched = await sessions.getSession(keyed.id);
      expect(fetched, isNotNull);
      expect(fetched!.id, equals(keyed.id));
    });
  });

  group('session types', () {
    test('createSession defaults to user type', () async {
      final session = await sessions.createSession();
      expect(session.type, equals(SessionType.user));
    });

    test('createSession accepts type parameter', () async {
      final session = await sessions.createSession(type: SessionType.channel, channelKey: 'wa:alice');
      expect(session.type, equals(SessionType.channel));
      expect(session.channelKey, equals('wa:alice'));

      final fetched = await sessions.getSession(session.id);
      expect(fetched!.type, equals(SessionType.channel));
      expect(fetched.channelKey, equals('wa:alice'));
    });

    test('getOrCreateMain creates main session', () async {
      final main = await sessions.getOrCreateMain();
      expect(main.type, equals(SessionType.main));

      final again = await sessions.getOrCreateMain();
      expect(again.id, equals(main.id));
    });

    test('getOrCreateByKey passes type through', () async {
      final session = await sessions.getOrCreateByKey('wa:bob', type: SessionType.channel);
      expect(session.type, equals(SessionType.channel));
      expect(session.channelKey, equals('wa:bob'));
    });

    test('listSessions filters by type', () async {
      await sessions.createSession(type: SessionType.user);
      await sessions.createSession(type: SessionType.channel, channelKey: 'wa:test');
      await sessions.getOrCreateMain();
      await sessions.createSession(type: SessionType.task);

      final all = await sessions.listSessions();
      expect(all.length, equals(3));

      final users = await sessions.listSessions(type: SessionType.user);
      expect(users.length, equals(1));

      final channels = await sessions.listSessions(type: SessionType.channel);
      expect(channels.length, equals(1));

      final mains = await sessions.listSessions(type: SessionType.main);
      expect(mains.length, equals(1));

      final taskSessions = await sessions.listSessions(type: SessionType.task);
      expect(taskSessions.length, equals(1));
    });

    test('listSessions filters by multiple types', () async {
      await sessions.createSession(type: SessionType.user);
      await sessions.createSession(type: SessionType.archive);
      await sessions.getOrCreateMain();

      final sidebarSessions = await sessions.listSessions(types: [SessionType.user, SessionType.archive]);
      expect(sidebarSessions.length, equals(2));
    });

    test('listSessions excludes task sessions by default', () async {
      await sessions.createSession(type: SessionType.user);
      await sessions.createSession(type: SessionType.task);

      final all = await sessions.listSessions();
      expect(all.map((session) => session.type), isNot(contains(SessionType.task)));
    });

    test('listSessions can include task sessions explicitly', () async {
      await sessions.createSession(type: SessionType.user);
      await sessions.createSession(type: SessionType.task);

      final all = await sessions.listSessions(includeTaskSessions: true);
      expect(all.map((session) => session.type), contains(SessionType.task));
    });

    test('updateSessionType changes type', () async {
      final session = await sessions.createSession(type: SessionType.archive);
      final updated = await sessions.updateSessionType(session.id, SessionType.user);
      expect(updated!.type, equals(SessionType.user));

      final fetched = await sessions.getSession(session.id);
      expect(fetched!.type, equals(SessionType.user));
    });

    test('updateSessionType returns null for non-existent id', () async {
      final result = await sessions.updateSessionType('00000000-0000-0000-0000-000000000000', SessionType.user);
      expect(result, isNull);
    });
  });

  group('backward compatibility', () {
    test('Session.fromJson defaults missing type to user', () {
      final json = {
        'id': '00000000-0000-0000-0000-000000000001',
        'title': 'Old session',
        'createdAt': '2025-01-01T00:00:00.000',
        'updatedAt': '2025-01-01T00:00:00.000',
      };
      final session = Session.fromJson(json);
      expect(session.type, equals(SessionType.user));
      expect(session.channelKey, isNull);
    });

    test('Session.toJson includes type', () {
      final session = Session(
        id: 'test',
        type: SessionType.channel,
        channelKey: 'wa:alice',
        createdAt: DateTime(2025),
        updatedAt: DateTime(2025),
      );
      final json = session.toJson();
      expect(json['type'], equals('channel'));
      expect(json['channelKey'], equals('wa:alice'));
    });
  });

  group('deleteSession', () {
    test('deletes session directory', () async {
      final session = await sessions.createSession();
      final result = await sessions.deleteSession(session.id);
      expect(result, equals(1));
      expect(await sessions.getSession(session.id), isNull);
    });

    test('returns 0 for non-existent session', () async {
      final result = await sessions.deleteSession('00000000-0000-0000-0000-000000000000');
      expect(result, equals(0));
    });

    test('rejects invalid UUID', () async {
      final result = await sessions.deleteSession('not-a-uuid');
      expect(result, equals(0));
    });

    test('throws StateError for main session', () async {
      final session = await sessions.createSession(type: SessionType.main, channelKey: 'main');
      expect(() => sessions.deleteSession(session.id), throwsStateError);
    });

    test('throws StateError for channel session', () async {
      final session = await sessions.createSession(type: SessionType.channel, channelKey: 'wa:123');
      expect(() => sessions.deleteSession(session.id), throwsStateError);
    });

    test('throws StateError for task session', () async {
      final session = await sessions.createSession(type: SessionType.task);
      expect(() => sessions.deleteSession(session.id), throwsStateError);
    });

    test('allows deleting archive session', () async {
      final session = await sessions.createSession(type: SessionType.archive);
      final result = await sessions.deleteSession(session.id);
      expect(result, equals(1));
    });

    test('allows deleting user session', () async {
      final session = await sessions.createSession(type: SessionType.user);
      final result = await sessions.deleteSession(session.id);
      expect(result, equals(1));
    });
  });
}
