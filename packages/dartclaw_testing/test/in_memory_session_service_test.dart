import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:test/test.dart';

void main() {
  group('InMemorySessionService', () {
    test('creates sessions, updates titles, and sorts newest first', () async {
      final service = InMemorySessionService();

      final first = await service.createSession();
      await Future<void>.delayed(const Duration(milliseconds: 1));
      final second = await service.createSession(type: SessionType.channel, channelKey: 'channel:1');

      await service.updateTitle(first.id, 'First');
      final sessions = await service.listSessions(includeTaskSessions: true);

      expect((await service.getSession(first.id))?.title, 'First');
      expect(sessions.map((session) => session.id).toList(), [first.id, second.id]);
    });

    test('getOrCreateByKey reuses existing sessions and can migrate type', () async {
      final service = InMemorySessionService();

      final initial = await service.getOrCreateByKey('main', type: SessionType.user);
      final migrated = await service.getOrCreateByKey('main', type: SessionType.main);

      expect(migrated.id, initial.id);
      expect(migrated.type, SessionType.main);
      expect(migrated.channelKey, 'main');
    });

    test('fires lifecycle events and protects system-managed sessions from deletion', () async {
      final events = TestEventBus();
      final service = InMemorySessionService(eventBus: events);

      final userSession = await service.createSession();
      final mainSession = await service.getOrCreateMain();

      expect(events.eventsOfType<SessionCreatedEvent>(), hasLength(2));

      await service.deleteSession(userSession.id);
      expect(events.eventsOfType<SessionEndedEvent>(), hasLength(1));

      await expectLater(service.deleteSession(mainSession.id), throwsA(isA<StateError>()));
    });
  });
}
