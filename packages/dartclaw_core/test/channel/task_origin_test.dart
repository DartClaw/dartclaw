import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

void main() {
  group('TaskOrigin', () {
    test('round-trips from json', () {
      final origin = TaskOrigin.fromJson({
        'channelType': 'googlechat',
        'sessionKey': 'agent:main:group:googlechat:spaces%2FAAAA',
        'recipientId': 'spaces/AAAA',
        'contactId': 'users/123',
        'sourceMessageId': 'spaces/AAAA/messages/BBBB',
      });

      expect(origin.channelType, 'googlechat');
      expect(origin.sessionKey, 'agent:main:group:googlechat:spaces%2FAAAA');
      expect(origin.recipientId, 'spaces/AAAA');
      expect(origin.contactId, 'users/123');
      expect(origin.sourceMessageId, 'spaces/AAAA/messages/BBBB');
    });

    test('extracts from configJson origin entry', () {
      final origin = TaskOrigin.fromConfigJson({
        'origin': {
          'channelType': 'whatsapp',
          'sessionKey': 'agent:main:dm:contact:alice',
          'recipientId': 'alice@s.whatsapp.net',
        },
      });

      expect(origin, isNotNull);
      expect(origin!.recipientId, 'alice@s.whatsapp.net');
    });

    test('returns null when origin is absent', () {
      expect(TaskOrigin.fromConfigJson(const {}), isNull);
    });

    test('returns null when origin is malformed', () {
      expect(TaskOrigin.fromConfigJson(const {'origin': 'bogus'}), isNull);
      expect(
        TaskOrigin.fromConfigJson({
          'origin': {'channelType': 'whatsapp'},
        }),
        isNull,
      );
    });
  });
}
