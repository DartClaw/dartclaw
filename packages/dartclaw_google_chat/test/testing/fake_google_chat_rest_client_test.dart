import 'package:dartclaw_google_chat/testing.dart';
import 'package:test/test.dart';

void main() {
  group('FakeGoogleChatRestClient', () {
    test('answers a threaded card send instead of letting it reach the real client', () async {
      final client = FakeGoogleChatRestClient();

      final result = await client.send(spaceName: 'spaces/AAA', card: const {'cardsV2': []}, threadKey: 'task-1');

      expect(client.sentCards, hasLength(1));
      expect(client.sentCards.single.$1, 'spaces/AAA');
      expect(client.sentCards.single.$2, {'cardsV2': <dynamic>[]});
      expect(result.messageName, isNotNull);
      expect(result.threadName, isNotNull);
    });

    test('answers a thread-name text send and reflects the targeted thread', () async {
      final client = FakeGoogleChatRestClient();

      final result = await client.send(spaceName: 'spaces/AAA', text: 'Hello', threadName: 'spaces/AAA/threads/CCC');

      expect(client.sentMessages, [('spaces/AAA', 'Hello')]);
      expect(result.messageName, isNotNull);
      expect(result.threadName, 'spaces/AAA/threads/CCC');
    });

    test('records a quoted text send as a quote-fallback call, not a plain send', () async {
      final client = FakeGoogleChatRestClient();

      await client.send(
        spaceName: 'spaces/AAA',
        text: 'Hello',
        quotedMessageName: 'spaces/AAA/messages/source',
        quotedMessageLastUpdateTime: '2024-03-15T10:30:00.260127Z',
        textWithoutQuote: '*@Alice* – Hello',
      );

      expect(client.quoteFallbackCalls, hasLength(1));
      expect(client.quoteFallbackCalls.single.quotedMessageName, 'spaces/AAA/messages/source');
      expect(client.quoteFallbackCalls.single.textWithoutQuote, '*@Alice* – Hello');
      expect(client.sentMessages, [('spaces/AAA', 'Hello')]);
      expect(client.lastQuotedMessageName, 'spaces/AAA/messages/source');
    });

    test('a refused quoted send with no fallback requested delivers nothing', () async {
      final client = FakeGoogleChatRestClient(failQuotedSend: true);

      final result = await client.send(
        spaceName: 'spaces/AAA',
        text: 'Hello',
        quotedMessageName: 'spaces/AAA/messages/source',
        fallbackOnQuoteFailure: false,
      );

      expect(result.messageName, isNull);
      expect(client.quoteFallbackCalls, hasLength(1));
      expect(client.sentMessages, isEmpty);
    });

    test('a failing card send reports no message name', () async {
      final client = FakeGoogleChatRestClient(failCard: true);

      final result = await client.send(spaceName: 'spaces/AAA', card: const {'cardsV2': []});

      expect(result.messageName, isNull);
      expect(client.sentCards, hasLength(1));
    });

    test('the send callback overrides the recorded default answer', () async {
      final client = FakeGoogleChatRestClient(
        onSend: ({
          required spaceName,
          text,
          card,
          threadKey,
          threadName,
          quotedMessageName,
          quotedMessageLastUpdateTime,
          textWithoutQuote,
          bool fallbackOnQuoteFailure = true,
        }) async => (messageName: '$spaceName/messages/fixed', threadName: null, usedQuotedMessageMetadata: false),
      );

      final result = await client.send(spaceName: 'spaces/AAA', text: 'Hello');

      expect(result.messageName, 'spaces/AAA/messages/fixed');
      expect(client.sentMessages, [('spaces/AAA', 'Hello')]);
    });
  });
}
