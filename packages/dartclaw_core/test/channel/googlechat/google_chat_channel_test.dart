import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:http/testing.dart';
import 'package:test/test.dart';

class _FakeGoogleChatRestClient extends GoogleChatRestClient {
  final List<(String, String)> sentMessages = [];
  final List<(String, String)> editedMessages = [];
  bool closeCalled = false;
  bool testConnectionCalled = false;
  bool failEdit = false;

  _FakeGoogleChatRestClient() : super(authClient: MockClient((request) async => throw UnimplementedError()));

  @override
  Future<void> close() async {
    closeCalled = true;
  }

  @override
  Future<bool> editMessage(String messageName, String newText) async {
    editedMessages.add((messageName, newText));
    return !failEdit;
  }

  @override
  Future<String?> sendMessage(String spaceName, String text) async {
    sentMessages.add((spaceName, text));
    return 'spaces/AAA/messages/BBB';
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
      expect(restClient.sentMessages, [('spaces/AAA', 'Hello')]);
    });

    test('sendMessage skips empty text', () async {
      await channel.sendMessage('spaces/AAA', const ChannelResponse(text: ''));
      expect(restClient.sentMessages, isEmpty);
    });

    test('sendMessage replaces placeholder when available', () async {
      channel.setPlaceholder(spaceName: 'spaces/AAA', turnId: 'turn-1', messageName: 'spaces/AAA/messages/placeholder');

      await channel.sendMessage(
        'spaces/AAA',
        const ChannelResponse(text: 'Hello', metadata: {sourceMessageIdMetadataKey: 'turn-1'}),
      );

      expect(restClient.editedMessages, [('spaces/AAA/messages/placeholder', 'Hello')]);
      expect(restClient.sentMessages, isEmpty);
    });

    test('sendMessage falls back to new message when placeholder patch fails', () async {
      restClient.failEdit = true;
      channel.setPlaceholder(spaceName: 'spaces/AAA', turnId: 'turn-1', messageName: 'spaces/AAA/messages/placeholder');

      await channel.sendMessage(
        'spaces/AAA',
        const ChannelResponse(text: 'Hello', metadata: {sourceMessageIdMetadataKey: 'turn-1'}),
      );

      expect(restClient.editedMessages, [('spaces/AAA/messages/placeholder', 'Hello')]);
      expect(restClient.sentMessages, [('spaces/AAA', 'Hello')]);
    });

    test('sendMessage keeps overlapping placeholders separate within the same space', () async {
      channel.setPlaceholder(spaceName: 'spaces/AAA', turnId: 'turn-1', messageName: 'spaces/AAA/messages/first');
      channel.setPlaceholder(spaceName: 'spaces/AAA', turnId: 'turn-2', messageName: 'spaces/AAA/messages/second');

      await channel.sendMessage(
        'spaces/AAA',
        const ChannelResponse(text: 'First reply', metadata: {sourceMessageIdMetadataKey: 'turn-1'}),
      );
      await channel.sendMessage(
        'spaces/AAA',
        const ChannelResponse(text: 'Second reply', metadata: {sourceMessageIdMetadataKey: 'turn-2'}),
      );

      expect(restClient.editedMessages, [
        ('spaces/AAA/messages/first', 'First reply'),
        ('spaces/AAA/messages/second', 'Second reply'),
      ]);
      expect(restClient.sentMessages, isEmpty);
    });

    test('disconnect closes rest client', () async {
      await channel.disconnect();
      expect(restClient.closeCalled, isTrue);
    });
  });
}
