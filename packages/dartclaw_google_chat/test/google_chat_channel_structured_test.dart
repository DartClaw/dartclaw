import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart' show ChannelResponse, sourceMessageIdMetadataKey;
import 'package:dartclaw_google_chat/testing.dart';
import 'package:dartclaw_google_chat/dartclaw_google_chat.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  late FakeGoogleChatRestClient restClient;
  late GoogleChatChannel channel;
  late Map<String, dynamic> cardPayload;

  setUp(() {
    restClient = FakeGoogleChatRestClient();
    channel = GoogleChatChannel(config: const GoogleChatConfig(enabled: true), restClient: restClient);
    cardPayload = const ChatCardBuilder().confirmationCard(title: 'Done', message: 'Completed.');
  });

  test('sends structured payloads as cards', () async {
    await channel.sendMessage('spaces/AAA', ChannelResponse(text: 'Fallback', structuredPayload: cardPayload));

    expect(restClient.sentCards, hasLength(1));
    expect(restClient.sentCards.single.$1, 'spaces/AAA');
    expect(restClient.sentCards.single.$2, equals(cardPayload));
    expect(restClient.sentMessages, isEmpty);
  });

  test('falls back to plain text when card send fails', () async {
    restClient.failCard = true;

    await channel.sendMessage('spaces/AAA', ChannelResponse(text: 'Fallback', structuredPayload: cardPayload));

    expect(restClient.sentCards, hasLength(1));
    expect(restClient.sentCards.single.$1, 'spaces/AAA');
    expect(restClient.sentCards.single.$2, equals(cardPayload));
    expect(restClient.sentMessages, [('spaces/AAA', 'Fallback')]);
  });

  // A card with no producer text falls through to the generic last resort rather
  // than to a paraphrase derived from the card itself.
  test('sends the generic last resort when a failed card carries no text', () async {
    restClient.failCard = true;

    await channel.sendMessage('spaces/AAA', ChannelResponse(text: '', structuredPayload: cardPayload));

    expect(restClient.sentCards, hasLength(1));
    expect(restClient.sentCards.single.$1, 'spaces/AAA');
    expect(restClient.sentCards.single.$2, equals(cardPayload));
    expect(restClient.sentMessages, [('spaces/AAA', 'DartClaw sent an update.')]);
  });

  test('removes pending placeholders after successful card delivery', () async {
    channel.setPlaceholder(spaceName: 'spaces/AAA', turnId: 'turn-1', messageName: 'spaces/AAA/messages/placeholder');

    await channel.sendMessage(
      'spaces/AAA',
      ChannelResponse(
        text: 'Fallback',
        metadata: const {sourceMessageIdMetadataKey: 'turn-1'},
        structuredPayload: cardPayload,
      ),
    );

    await channel.sendMessage(
      'spaces/AAA',
      const ChannelResponse(text: 'Follow-up', metadata: {sourceMessageIdMetadataKey: 'turn-1'}),
    );

    expect(restClient.sentCards, hasLength(1));
    expect(restClient.sentCards.single.$1, 'spaces/AAA');
    expect(restClient.sentCards.single.$2, equals(cardPayload));
    expect(restClient.editedMessages, isEmpty);
    expect(restClient.sentMessages, [('spaces/AAA', 'Follow-up')]);
  });

  group('every send path falls back to the producer\'s own text', () {
    late List<String> sentTexts;
    late int cardAttempts;
    late GoogleChatChannel threadChannel;

    setUp(() {
      sentTexts = [];
      cardAttempts = 0;
      threadChannel = GoogleChatChannel(
        config: const GoogleChatConfig(enabled: true),
        restClient: GoogleChatRestClient(
          authClient: MockClient((request) async {
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            if (body.containsKey('cardsV2')) {
              cardAttempts++;
              return http.Response('card rejected', 400);
            }
            sentTexts.add(body['text'] as String);
            return http.Response(
              jsonEncode({
                'name': 'spaces/AAA/messages/BBB',
                'thread': {'name': 'spaces/AAA/threads/CCC'},
              }),
              200,
            );
          }),
          apiBase: 'https://chat.googleapis.com/v1',
        ),
      );
    });

    test('sendMessage', () async {
      await threadChannel.sendMessage(
        'spaces/AAA',
        ChannelResponse(text: 'Producer text', structuredPayload: cardPayload),
      );
      expect(cardAttempts, 1);
      expect(sentTexts, ['Producer text']);
    });

    test('sendMessageWithThread', () async {
      final threadName = await threadChannel.sendMessageWithThread(
        'spaces/AAA',
        ChannelResponse(text: 'Producer text', structuredPayload: cardPayload),
        threadKey: 'task-1',
      );
      expect(cardAttempts, 1);
      expect(sentTexts, ['Producer text']);
      expect(threadName, 'spaces/AAA/threads/CCC');
    });

    test('sendMessageToThreadName', () async {
      await threadChannel.sendMessageToThreadName(
        'spaces/AAA',
        ChannelResponse(text: 'Producer text', structuredPayload: cardPayload),
        threadName: 'spaces/AAA/threads/CCC',
      );
      expect(cardAttempts, 1);
      expect(sentTexts, ['Producer text']);
    });
  });
}
