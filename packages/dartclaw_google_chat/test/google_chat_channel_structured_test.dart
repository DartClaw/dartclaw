import 'package:dartclaw_core/dartclaw_core.dart' show ChannelResponse, sourceMessageIdMetadataKey;
import 'package:dartclaw_testing/dartclaw_testing.dart' show FakeGoogleChatRestClient;
import 'package:dartclaw_google_chat/dartclaw_google_chat.dart';
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

  test('synthesizes fallback text from the structured payload when text is empty', () async {
    restClient.failCard = true;

    await channel.sendMessage('spaces/AAA', ChannelResponse(text: '', structuredPayload: cardPayload));

    expect(restClient.sentCards, hasLength(1));
    expect(restClient.sentCards.single.$1, 'spaces/AAA');
    expect(restClient.sentCards.single.$2, equals(cardPayload));
    expect(restClient.sentMessages, [('spaces/AAA', 'Done\nConfirmation\nCompleted.')]);
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
}
