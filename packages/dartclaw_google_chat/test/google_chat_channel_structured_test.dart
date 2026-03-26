import 'package:dartclaw_google_chat/dartclaw_google_chat.dart';
import 'package:http/testing.dart';
import 'package:test/test.dart';

class _FakeGoogleChatRestClient extends GoogleChatRestClient {
  final List<(String, String, String?)> sentMessages = [];
  final List<(String, Map<String, dynamic>, String?)> sentCards = [];
  final List<(String, String)> editedMessages = [];
  final List<String> deletedMessages = [];
  bool failCard = false;

  _FakeGoogleChatRestClient() : super(authClient: MockClient((request) async => throw UnimplementedError()));

  @override
  Future<String?> sendCard(String spaceName, Map<String, dynamic> cardPayload, {String? quotedMessageName}) async {
    sentCards.add((spaceName, cardPayload, quotedMessageName));
    return failCard ? null : '$spaceName/messages/card';
  }

  @override
  Future<bool> editMessage(String messageName, String newText) async {
    editedMessages.add((messageName, newText));
    return true;
  }

  @override
  Future<String?> sendMessage(String spaceName, String text, {String? quotedMessageName}) async {
    sentMessages.add((spaceName, text, quotedMessageName));
    return '$spaceName/messages/text';
  }

  @override
  Future<bool> deleteMessage(String messageName) async {
    deletedMessages.add(messageName);
    return true;
  }
}

void main() {
  late _FakeGoogleChatRestClient restClient;
  late GoogleChatChannel channel;
  late Map<String, dynamic> cardPayload;

  setUp(() {
    restClient = _FakeGoogleChatRestClient();
    channel = GoogleChatChannel(config: const GoogleChatConfig(enabled: true), restClient: restClient);
    cardPayload = const ChatCardBuilder().confirmationCard(title: 'Done', message: 'Completed.');
  });

  test('sends structured payloads as cards', () async {
    await channel.sendMessage('spaces/AAA', ChannelResponse(text: 'Fallback', structuredPayload: cardPayload));

    expect(restClient.sentCards, [('spaces/AAA', cardPayload, null)]);
    expect(restClient.sentMessages, isEmpty);
  });

  test('falls back to plain text when card send fails', () async {
    restClient.failCard = true;

    await channel.sendMessage('spaces/AAA', ChannelResponse(text: 'Fallback', structuredPayload: cardPayload));

    expect(restClient.sentCards, [('spaces/AAA', cardPayload, null)]);
    expect(restClient.sentMessages, [('spaces/AAA', 'Fallback', null)]);
  });

  test('synthesizes fallback text from the structured payload when text is empty', () async {
    restClient.failCard = true;

    await channel.sendMessage('spaces/AAA', ChannelResponse(text: '', structuredPayload: cardPayload));

    expect(restClient.sentCards, [('spaces/AAA', cardPayload, null)]);
    expect(restClient.sentMessages, [('spaces/AAA', 'Done\nConfirmation\nCompleted.', null)]);
  });

  test('removes pending placeholders after successful card delivery', () async {
    channel.setPlaceholder(spaceName: 'spaces/AAA', turnId: 'turn-1', messageName: 'spaces/AAA/messages/placeholder');

    await channel.sendMessage(
      'spaces/AAA',
      ChannelResponse(
        text: 'Fallback',
        replyToMessageId: 'turn-1',
        structuredPayload: cardPayload,
      ),
    );

    await channel.sendMessage(
      'spaces/AAA',
      const ChannelResponse(text: 'Follow-up', replyToMessageId: 'turn-1'),
    );

    expect(restClient.sentCards, [('spaces/AAA', cardPayload, null)]);
    expect(restClient.editedMessages, isEmpty);
    expect(restClient.sentMessages, [('spaces/AAA', 'Follow-up', null)]);
  });

  test('quotes structured payloads when quoteReply is enabled', () async {
    channel = GoogleChatChannel(
      config: const GoogleChatConfig(enabled: true, quoteReply: true),
      restClient: restClient,
    );

    await channel.sendMessage(
      'spaces/AAA',
      ChannelResponse(
        text: 'Fallback',
        replyToMessageId: 'spaces/AAA/messages/source',
        structuredPayload: cardPayload,
      ),
    );

    expect(restClient.sentCards, [('spaces/AAA', cardPayload, 'spaces/AAA/messages/source')]);
  });
}
