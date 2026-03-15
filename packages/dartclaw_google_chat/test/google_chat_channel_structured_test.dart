import 'package:dartclaw_core/dartclaw_core.dart' show ChannelResponse, sourceMessageIdMetadataKey;
import 'package:dartclaw_google_chat/dartclaw_google_chat.dart';
import 'package:http/testing.dart';
import 'package:test/test.dart';

class _FakeGoogleChatRestClient extends GoogleChatRestClient {
  final List<(String, String)> sentMessages = [];
  final List<(String, Map<String, dynamic>)> sentCards = [];
  final List<(String, String)> editedMessages = [];
  bool failCard = false;

  _FakeGoogleChatRestClient() : super(authClient: MockClient((request) async => throw UnimplementedError()));

  @override
  Future<String?> sendCard(String spaceName, Map<String, dynamic> cardPayload) async {
    sentCards.add((spaceName, cardPayload));
    return failCard ? null : '$spaceName/messages/card';
  }

  @override
  Future<bool> editMessage(String messageName, String newText) async {
    editedMessages.add((messageName, newText));
    return true;
  }

  @override
  Future<String?> sendMessage(String spaceName, String text) async {
    sentMessages.add((spaceName, text));
    return '$spaceName/messages/text';
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

    expect(restClient.sentCards, [('spaces/AAA', cardPayload)]);
    expect(restClient.sentMessages, isEmpty);
  });

  test('falls back to plain text when card send fails', () async {
    restClient.failCard = true;

    await channel.sendMessage('spaces/AAA', ChannelResponse(text: 'Fallback', structuredPayload: cardPayload));

    expect(restClient.sentCards, [('spaces/AAA', cardPayload)]);
    expect(restClient.sentMessages, [('spaces/AAA', 'Fallback')]);
  });

  test('synthesizes fallback text from the structured payload when text is empty', () async {
    restClient.failCard = true;

    await channel.sendMessage('spaces/AAA', ChannelResponse(text: '', structuredPayload: cardPayload));

    expect(restClient.sentCards, [('spaces/AAA', cardPayload)]);
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

    expect(restClient.sentCards, [('spaces/AAA', cardPayload)]);
    expect(restClient.editedMessages, isEmpty);
    expect(restClient.sentMessages, [('spaces/AAA', 'Follow-up')]);
  });
}
