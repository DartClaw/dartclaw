import 'package:dartclaw_core/dartclaw_core.dart' show ChannelResponse, ChannelType, sourceMessageIdMetadataKey;
import 'package:dartclaw_google_chat/dartclaw_google_chat.dart';
import 'package:http/testing.dart';
import 'package:test/test.dart';

class _FakeGoogleChatRestClient extends GoogleChatRestClient {
  final List<(String, String)> sentMessages = [];
  final List<(String, String)> editedMessages = [];
  final List<String> deletedMessages = [];
  final List<
    ({
      String spaceName,
      String text,
      String? quotedMessageName,
      String? quotedMessageLastUpdateTime,
      String? textWithoutQuote,
    })
  >
  quoteFallbackCalls = [];
  String? lastQuotedMessageName;
  String? lastQuotedMessageLastUpdateTime;
  bool quoteFallbackUsesQuotedMessageMetadata = true;
  bool closeCalled = false;
  bool testConnectionCalled = false;
  bool failEdit = false;
  bool failDelete = false;

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
  Future<String?> sendMessage(
    String spaceName,
    String text, {
    String? quotedMessageName,
    String? quotedMessageLastUpdateTime,
  }) async {
    sentMessages.add((spaceName, text));
    lastQuotedMessageName = quotedMessageName;
    lastQuotedMessageLastUpdateTime = quotedMessageLastUpdateTime;
    return 'spaces/AAA/messages/BBB';
  }

  bool failQuotedSend = false;

  @override
  Future<({String? messageName, bool usedQuotedMessageMetadata})> sendMessageWithQuoteFallback(
    String spaceName,
    String text, {
    String? quotedMessageName,
    String? quotedMessageLastUpdateTime,
    String? textWithoutQuote,
    bool fallbackOnQuoteFailure = true,
  }) async {
    quoteFallbackCalls.add((
      spaceName: spaceName,
      text: text,
      quotedMessageName: quotedMessageName,
      quotedMessageLastUpdateTime: quotedMessageLastUpdateTime,
      textWithoutQuote: textWithoutQuote,
    ));

    if (failQuotedSend && quotedMessageName != null) {
      if (!fallbackOnQuoteFailure) {
        return (messageName: null, usedQuotedMessageMetadata: false);
      }
      sentMessages.add((spaceName, textWithoutQuote ?? text));
      return (messageName: 'spaces/AAA/messages/BBB', usedQuotedMessageMetadata: false);
    }

    lastQuotedMessageName = quoteFallbackUsesQuotedMessageMetadata ? quotedMessageName : null;
    lastQuotedMessageLastUpdateTime = quoteFallbackUsesQuotedMessageMetadata ? quotedMessageLastUpdateTime : null;
    sentMessages.add((spaceName, quoteFallbackUsesQuotedMessageMetadata ? text : (textWithoutQuote ?? text)));

    return (messageName: 'spaces/AAA/messages/BBB', usedQuotedMessageMetadata: quoteFallbackUsesQuotedMessageMetadata);
  }

  @override
  Future<bool> deleteMessage(String messageName) async {
    deletedMessages.add(messageName);
    return !failDelete;
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

    test('formatResponse marks only the first chunk for attribution', () {
      final responses = channel.formatResponse('A' * 9000);

      expect(responses, hasLength(greaterThan(1)));
      expect(responses.first.metadata['isFirstChunk'], isTrue);
      expect(
        responses.skip(1),
        everyElement(
          predicate((ChannelResponse response) {
            return response.metadata['isFirstChunk'] == false;
          }),
        ),
      );
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

    test('sendMessage with placeholder + quote: sends quoted then deletes placeholder', () async {
      channel = GoogleChatChannel(
        config: const GoogleChatConfig(enabled: true, quoteReplyMode: QuoteReplyMode.native),
        restClient: restClient,
      );
      channel.setPlaceholder(
        spaceName: 'spaces/AAA',
        turnId: 'spaces/AAA/messages/source',
        messageName: 'spaces/AAA/messages/placeholder',
      );

      await channel.sendMessage(
        'spaces/AAA',
        const ChannelResponse(
          text: 'Hello',
          metadata: {
            sourceMessageIdMetadataKey: 'spaces/AAA/messages/source',
            'messageCreateTime': '2024-03-15T10:30:00.260127Z',
          },
        ),
      );

      // Quoted send attempted first (without fallback), then placeholder deleted.
      expect(restClient.quoteFallbackCalls, hasLength(1));
      expect(restClient.deletedMessages, ['spaces/AAA/messages/placeholder']);
      expect(restClient.editedMessages, isEmpty);
    });

    test('sendMessage edits placeholder when quoted send fails (no delete artifact)', () async {
      restClient.failQuotedSend = true;
      channel = GoogleChatChannel(
        config: const GoogleChatConfig(enabled: true, quoteReplyMode: QuoteReplyMode.native),
        restClient: restClient,
      );
      channel.setPlaceholder(
        spaceName: 'spaces/AAA',
        turnId: 'spaces/AAA/messages/source',
        messageName: 'spaces/AAA/messages/placeholder',
      );

      await channel.sendMessage(
        'spaces/AAA',
        const ChannelResponse(
          text: 'Hello',
          metadata: {
            sourceMessageIdMetadataKey: 'spaces/AAA/messages/source',
            'messageCreateTime': '2024-03-15T10:30:00.260127Z',
          },
        ),
      );

      // Quote failed → placeholder edited, no delete, no "deleted" artifact.
      expect(restClient.quoteFallbackCalls, hasLength(1));
      expect(restClient.deletedMessages, isEmpty);
      expect(restClient.editedMessages, [('spaces/AAA/messages/placeholder', 'Hello')]);
      expect(restClient.sentMessages, isEmpty);
    });

    test('sendMessage native mode falls back to sender attribution when API quoting fails', () async {
      restClient.failQuotedSend = true;
      channel = GoogleChatChannel(
        config: const GoogleChatConfig(enabled: true, quoteReplyMode: QuoteReplyMode.native),
        restClient: restClient,
      );
      channel.setPlaceholder(
        spaceName: 'spaces/AAA',
        turnId: 'spaces/AAA/messages/source',
        messageName: 'spaces/AAA/messages/placeholder',
      );

      await channel.sendMessage(
        'spaces/AAA',
        const ChannelResponse(
          text: 'Reply',
          metadata: {
            sourceMessageIdMetadataKey: 'spaces/AAA/messages/source',
            'messageCreateTime': '2024-03-15T10:30:00.260127Z',
            'spaceType': 'SPACE',
            'senderDisplayName': 'Alice',
          },
        ),
      );

      // Native quote failed → placeholder edited with sender attribution.
      expect(restClient.deletedMessages, isEmpty);
      expect(restClient.editedMessages.single.$2, '*@Alice* – Reply');
    });

    test('sendMessage allows quoted replies for dot-format Space Events ids', () async {
      channel = GoogleChatChannel(
        config: const GoogleChatConfig(enabled: true, quoteReplyMode: QuoteReplyMode.native),
        restClient: restClient,
      );

      await channel.sendMessage(
        'spaces/AAA',
        const ChannelResponse(
          text: 'Hello',
          metadata: {
            sourceMessageIdMetadataKey: 'spaces/AAA/messages/abc.def',
            'messageCreateTime': '2024-03-15T10:30:00.260127Z',
          },
        ),
      );

      expect(restClient.sentMessages, [('spaces/AAA', 'Hello')]);
      expect(restClient.lastQuotedMessageName, 'spaces/AAA/messages/abc.def');
      expect(restClient.lastQuotedMessageLastUpdateTime, '2024-03-15T10:30:00.260127Z');
    });

    test('sendMessage prefers replyToMessageId while keeping quoted metadata', () async {
      channel = GoogleChatChannel(
        config: const GoogleChatConfig(enabled: true, quoteReplyMode: QuoteReplyMode.native),
        restClient: restClient,
      );

      await channel.sendMessage(
        'spaces/AAA',
        const ChannelResponse(
          text: 'Hello',
          replyToMessageId: 'spaces/AAA/messages/source',
          metadata: {'messageCreateTime': '2024-03-15T10:30:00.260127Z'},
        ),
      );

      expect(restClient.sentMessages, [('spaces/AAA', 'Hello')]);
      expect(restClient.lastQuotedMessageName, 'spaces/AAA/messages/source');
      expect(restClient.lastQuotedMessageLastUpdateTime, '2024-03-15T10:30:00.260127Z');
    });

    test('sendMessage does not quote DM replies or prepend attribution', () async {
      channel = GoogleChatChannel(
        config: const GoogleChatConfig(enabled: true, quoteReplyMode: QuoteReplyMode.native),
        restClient: restClient,
      );

      await channel.sendMessage(
        'spaces/AAA',
        const ChannelResponse(
          text: 'Hello',
          metadata: {
            sourceMessageIdMetadataKey: 'spaces/AAA/messages/source',
            'messageCreateTime': '2024-03-15T10:30:00.260127Z',
            'spaceType': 'DM',
            'senderDisplayName': 'Alice',
          },
        ),
      );

      expect(restClient.lastQuotedMessageName, isNull);
      expect(restClient.sentMessages, [('spaces/AAA', 'Hello')]);
    });

    test('sendMessage prepends attribution in GROUP_CHAT with sender mode', () async {
      channel = GoogleChatChannel(
        config: const GoogleChatConfig(enabled: true, quoteReplyMode: QuoteReplyMode.sender),
        restClient: restClient,
      );

      await channel.sendMessage(
        'spaces/AAA',
        const ChannelResponse(text: 'Hello', metadata: {'spaceType': 'GROUP_CHAT', 'senderDisplayName': 'Alice Smith'}),
      );

      expect(restClient.sentMessages, [('spaces/AAA', '*@Alice Smith* – Hello')]);
    });

    test('sendMessage allows quoted replies in ROOM spaces', () async {
      channel = GoogleChatChannel(
        config: const GoogleChatConfig(enabled: true, quoteReplyMode: QuoteReplyMode.native),
        restClient: restClient,
      );

      await channel.sendMessage(
        'spaces/AAA',
        const ChannelResponse(
          text: 'Hello',
          metadata: {
            sourceMessageIdMetadataKey: 'spaces/AAA/messages/source',
            'messageCreateTime': '2024-03-15T10:30:00.260127Z',
            'spaceType': 'ROOM',
          },
        ),
      );

      expect(restClient.sentMessages, [('spaces/AAA', 'Hello')]);
      expect(restClient.lastQuotedMessageName, 'spaces/AAA/messages/source');
      expect(restClient.lastQuotedMessageLastUpdateTime, '2024-03-15T10:30:00.260127Z');
    });

    test('sendMessage prepends attribution in ROOM spaces with sender mode', () async {
      channel = GoogleChatChannel(
        config: const GoogleChatConfig(enabled: true, quoteReplyMode: QuoteReplyMode.sender),
        restClient: restClient,
      );

      await channel.sendMessage(
        'spaces/AAA',
        const ChannelResponse(text: 'Hello', metadata: {'spaceType': 'ROOM', 'senderDisplayName': 'Alice Smith'}),
      );

      expect(restClient.lastQuotedMessageName, isNull);
      expect(restClient.sentMessages, [('spaces/AAA', '*@Alice Smith* – Hello')]);
    });

    test('sendMessage carries sender attribution into quote fallback for threaded group spaces', () async {
      restClient.quoteFallbackUsesQuotedMessageMetadata = false;
      channel = GoogleChatChannel(
        config: const GoogleChatConfig(enabled: true, quoteReplyMode: QuoteReplyMode.native),
        restClient: restClient,
      );

      await channel.sendMessage(
        'spaces/AAA',
        const ChannelResponse(
          text: 'Hello',
          metadata: {
            sourceMessageIdMetadataKey: 'spaces/AAA/messages/source',
            'messageCreateTime': '2024-03-15T10:30:00.260127Z',
            'spaceType': 'SPACE',
            'senderDisplayName': 'Alice Smith',
          },
        ),
      );

      expect(restClient.quoteFallbackCalls, hasLength(1));
      expect(restClient.quoteFallbackCalls.single.quotedMessageName, 'spaces/AAA/messages/source');
      expect(restClient.quoteFallbackCalls.single.text, 'Hello');
      expect(restClient.quoteFallbackCalls.single.textWithoutQuote, '*@Alice Smith* – Hello');
      expect(restClient.sentMessages, [('spaces/AAA', '*@Alice Smith* – Hello')]);
      expect(restClient.lastQuotedMessageName, isNull);
    });

    test('sendMessage applies sender attribution only to the first formatted chunk', () async {
      channel = GoogleChatChannel(
        config: const GoogleChatConfig(enabled: true, quoteReplyMode: QuoteReplyMode.sender),
        restClient: restClient,
      );

      final chunks = channel.formatResponse('A' * 9000);
      for (final chunk in chunks) {
        await channel.sendMessage(
          'spaces/AAA',
          ChannelResponse(
            text: chunk.text,
            metadata: {...chunk.metadata, 'spaceType': 'SPACE', 'senderDisplayName': 'Alice Smith'},
          ),
        );
      }

      expect(restClient.sentMessages, hasLength(chunks.length));
      expect(restClient.sentMessages.first.$2, startsWith('*@Alice Smith* – '));
      expect(restClient.sentMessages.skip(1).every((entry) => !entry.$2.startsWith('*@Alice Smith* – ')), isTrue);
    });

    test('sendMessage does not prepend attribution when senderDisplayName is missing', () async {
      channel = GoogleChatChannel(
        config: const GoogleChatConfig(enabled: true, quoteReplyMode: QuoteReplyMode.sender),
        restClient: restClient,
      );

      await channel.sendMessage(
        'spaces/AAA',
        const ChannelResponse(text: 'Hello', metadata: {'spaceType': 'SPACE'}),
      );

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
