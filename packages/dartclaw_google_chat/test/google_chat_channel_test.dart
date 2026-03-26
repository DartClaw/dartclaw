import 'package:dartclaw_google_chat/dartclaw_google_chat.dart';
import 'package:http/testing.dart';
import 'package:test/test.dart';

class _FakeGoogleChatRestClient extends GoogleChatRestClient {
  final List<String> operations = [];
  final List<(String, String, String?)> sentMessages = [];
  final List<(String, String)> editedMessages = [];
  final List<String> deletedMessages = [];
  final List<String> removedReactions = [];
  bool closeCalled = false;
  bool testConnectionCalled = false;
  bool failSendMessage = false;
  bool failEdit = false;
  bool failDelete = false;
  bool failRemoveReaction = false;

  _FakeGoogleChatRestClient() : super(authClient: MockClient((request) async => throw UnimplementedError()));

  @override
  Future<void> close() async {
    closeCalled = true;
  }

  @override
  Future<bool> editMessage(String messageName, String newText) async {
    operations.add('editMessage');
    editedMessages.add((messageName, newText));
    return !failEdit;
  }

  @override
  Future<bool> deleteMessage(String messageName) async {
    operations.add('deleteMessage');
    deletedMessages.add(messageName);
    return !failDelete;
  }

  @override
  Future<String?> addReaction(String messageName, String emoji) async {
    operations.add('addReaction');
    return '$messageName/reactions/added';
  }

  @override
  Future<bool> removeReaction(String reactionName) async {
    operations.add('removeReaction');
    removedReactions.add(reactionName);
    return !failRemoveReaction;
  }

  @override
  Future<String?> sendMessage(String spaceName, String text, {String? quotedMessageName}) async {
    operations.add('sendMessage');
    sentMessages.add((spaceName, text, quotedMessageName));
    return failSendMessage ? null : 'spaces/AAA/messages/BBB';
  }

  @override
  Future<String?> sendCard(String spaceName, Map<String, dynamic> cardPayload, {String? quotedMessageName}) async {
    operations.add('sendCard');
    return 'spaces/AAA/messages/CARD';
  }

  @override
  Future<void> testConnection() async {
    testConnectionCalled = true;
  }
}

void main() {
  late _FakeGoogleChatRestClient restClient;
  late GoogleChatChannel channel;

  setUp(() {
    restClient = _FakeGoogleChatRestClient();
    channel = GoogleChatChannel(config: const GoogleChatConfig(enabled: true), restClient: restClient);
  });

  group('GoogleChatChannel', () {
    test('name and type', () {
      expect(channel.name, 'googlechat');
      expect(channel.type, ChannelType.googlechat);
    });

    test('ownsJid matches Google Chat spaces', () {
      expect(channel.ownsJid('spaces/AAAA'), isTrue);
      expect(channel.ownsJid('123456@s.whatsapp.net'), isFalse);
      expect(channel.ownsJid('+1234567890'), isFalse);
      expect(channel.ownsJid(''), isFalse);
    });

    test('connect validates credentials', () async {
      await channel.connect();
      expect(restClient.testConnectionCalled, isTrue);
    });

    test('formatResponse returns single chunk for short text', () {
      final responses = channel.formatResponse('Hello');
      expect(responses, hasLength(1));
      expect(responses.first.text, 'Hello');
    });

    test('formatResponse chunks long text', () {
      final responses = channel.formatResponse('A' * 9000);
      expect(responses.length, greaterThan(1));
      expect(responses.first.text, startsWith('(1/'));
      expect(responses.last.text, startsWith('('));
    });

    test('sendMessage sends text through rest client', () async {
      await channel.sendMessage('spaces/AAA', const ChannelResponse(text: 'Hello'));
      expect(restClient.sentMessages, [('spaces/AAA', 'Hello', null)]);
    });

    test('sendMessage skips empty text', () async {
      await channel.sendMessage('spaces/AAA', const ChannelResponse(text: ''));
      expect(restClient.sentMessages, isEmpty);
    });

    test('sendMessage replaces placeholder when available', () async {
      channel.setPlaceholder(spaceName: 'spaces/AAA', turnId: 'turn-1', messageName: 'spaces/AAA/messages/placeholder');

      await channel.sendMessage('spaces/AAA', const ChannelResponse(text: 'Hello', replyToMessageId: 'turn-1'));

      expect(restClient.editedMessages, [('spaces/AAA/messages/placeholder', 'Hello')]);
      expect(restClient.sentMessages, isEmpty);
    });

    test('sendMessage falls back to new message when placeholder patch fails', () async {
      restClient.failEdit = true;
      channel.setPlaceholder(spaceName: 'spaces/AAA', turnId: 'turn-1', messageName: 'spaces/AAA/messages/placeholder');

      await channel.sendMessage('spaces/AAA', const ChannelResponse(text: 'Hello', replyToMessageId: 'turn-1'));

      expect(restClient.editedMessages, [('spaces/AAA/messages/placeholder', 'Hello')]);
      expect(restClient.sentMessages, [('spaces/AAA', 'Hello', null)]);
    });

    test('sendMessage quotes replyToMessageId when quoteReply is enabled', () async {
      channel = GoogleChatChannel(
        config: const GoogleChatConfig(enabled: true, quoteReply: true),
        restClient: restClient,
      );

      await channel.sendMessage(
        'spaces/AAA',
        const ChannelResponse(text: 'Hello', replyToMessageId: 'spaces/AAA/messages/source'),
      );

      expect(restClient.sentMessages, [('spaces/AAA', 'Hello', 'spaces/AAA/messages/source')]);
    });

    test('sendMessage does not quote replyToMessageId when quoteReply is disabled', () async {
      await channel.sendMessage(
        'spaces/AAA',
        const ChannelResponse(text: 'Hello', replyToMessageId: 'spaces/AAA/messages/source'),
      );

      expect(restClient.sentMessages, [('spaces/AAA', 'Hello', null)]);
    });

    test('sendMessage keeps the message-name guard for quote targets', () async {
      channel = GoogleChatChannel(
        config: const GoogleChatConfig(enabled: true, quoteReply: true),
        restClient: restClient,
      );

      await channel.sendMessage('spaces/AAA', const ChannelResponse(text: 'Hello', replyToMessageId: 'turn-1'));

      expect(restClient.sentMessages, [('spaces/AAA', 'Hello', null)]);
    });

    test('sendMessage deletes a placeholder after a successful quoted reply', () async {
      channel = GoogleChatChannel(
        config: const GoogleChatConfig(enabled: true, quoteReply: true),
        restClient: restClient,
      );
      channel.setPlaceholder(
        spaceName: 'spaces/AAA',
        turnId: 'spaces/AAA/messages/source',
        messageName: 'spaces/AAA/messages/placeholder',
      );

      await channel.sendMessage(
        'spaces/AAA',
        const ChannelResponse(text: 'Hello', replyToMessageId: 'spaces/AAA/messages/source'),
      );

      expect(restClient.operations, ['sendMessage', 'deleteMessage']);
      expect(restClient.deletedMessages, ['spaces/AAA/messages/placeholder']);
      expect(restClient.sentMessages, [('spaces/AAA', 'Hello', 'spaces/AAA/messages/source')]);
    });

    test('sendMessage keeps the placeholder when a quoted reply send fails', () async {
      channel = GoogleChatChannel(
        config: const GoogleChatConfig(enabled: true, quoteReply: true),
        restClient: restClient,
      );
      restClient.failSendMessage = true;
      channel.setPlaceholder(
        spaceName: 'spaces/AAA',
        turnId: 'spaces/AAA/messages/source',
        messageName: 'spaces/AAA/messages/placeholder',
      );

      await channel.sendMessage(
        'spaces/AAA',
        const ChannelResponse(text: 'Hello', replyToMessageId: 'spaces/AAA/messages/source'),
      );

      expect(restClient.operations, ['sendMessage', 'editMessage']);
      expect(restClient.deletedMessages, isEmpty);
      expect(restClient.editedMessages, [('spaces/AAA/messages/placeholder', 'Hello')]);
      expect(restClient.sentMessages, [('spaces/AAA', 'Hello', 'spaces/AAA/messages/source')]);
    });

    test('sendMessage removes pending reactions before sending', () async {
      channel.setReaction(
        spaceName: 'spaces/AAA',
        turnId: 'turn-1',
        reactionName: 'spaces/AAA/messages/placeholder/reactions/abc',
      );

      await channel.sendMessage('spaces/AAA', const ChannelResponse(text: 'Hello', replyToMessageId: 'turn-1'));

      expect(restClient.operations.first, 'removeReaction');
      expect(restClient.removedReactions, ['spaces/AAA/messages/placeholder/reactions/abc']);
      expect(restClient.sentMessages, [('spaces/AAA', 'Hello', null)]);
    });

    test('sendMessage keeps overlapping placeholders separate within the same space', () async {
      channel.setPlaceholder(spaceName: 'spaces/AAA', turnId: 'turn-1', messageName: 'spaces/AAA/messages/first');
      channel.setPlaceholder(spaceName: 'spaces/AAA', turnId: 'turn-2', messageName: 'spaces/AAA/messages/second');

      await channel.sendMessage('spaces/AAA', const ChannelResponse(text: 'First reply', replyToMessageId: 'turn-1'));
      await channel.sendMessage('spaces/AAA', const ChannelResponse(text: 'Second reply', replyToMessageId: 'turn-2'));

      expect(restClient.editedMessages, [
        ('spaces/AAA/messages/first', 'First reply'),
        ('spaces/AAA/messages/second', 'Second reply'),
      ]);
      expect(restClient.sentMessages, isEmpty);
    });

    test('disconnect closes rest client', () async {
      await channel.disconnect();
      expect(restClient.closeCalled, isTrue);
      expect(restClient.deletedMessages, isEmpty);
    });
  });
}
