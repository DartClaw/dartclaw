import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Test doubles
// ---------------------------------------------------------------------------
class FakeGowaManager extends GowaManager {
  bool started = false;
  bool stopped = false;
  final List<(String, String)> sentTexts = [];
  final List<(String, String)> sentMedia = [];
  GowaStatus statusResult = (isConnected: false, isLoggedIn: false, deviceId: null);
  String? loginQrResult;

  FakeGowaManager()
      : super(
          executable: 'whatsapp',
          processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) async {
            return _NeverExitProcess();
          },
        );

  @override
  Future<void> start() async {
    started = true;
  }

  @override
  Future<void> stop() async {
    stopped = true;
  }

  @override
  Future<void> sendText(String jid, String text) async {
    sentTexts.add((jid, text));
  }

  @override
  Future<void> sendMedia(String jid, String filePath, {String? caption}) async {
    sentMedia.add((jid, filePath));
  }

  @override
  Future<GowaStatus> getStatus() async => statusResult;

  @override
  Future<String?> getLoginQr() async => loginQrResult;
}

class FakeChannelManager extends ChannelManager {
  final List<ChannelMessage> received = [];

  FakeChannelManager()
      : super(
          queue: MessageQueue(
            dispatcher: (_, _, {senderJid}) async => '',
            maxConcurrentTurns: 1,
          ),
          config: const ChannelConfig.defaults(),
        );

  @override
  void handleInboundMessage(ChannelMessage message) {
    received.add(message);
  }
}

class _NeverExitProcess implements Process {
  @override
  int get pid => 1;
  @override
  IOSink get stdin => _NullIOSink();
  @override
  Stream<List<int>> get stdout => const Stream.empty();
  @override
  Stream<List<int>> get stderr => const Stream.empty();
  @override
  Future<int> get exitCode => Completer<int>().future;
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) => true;
}

class _NullIOSink implements IOSink {
  @override Encoding get encoding => utf8;
  @override set encoding(Encoding value) {}
  @override void add(List<int> data) {}
  @override void addError(Object error, [StackTrace? stackTrace]) {}
  @override Future<void> addStream(Stream<List<int>> stream) => Future.value();
  @override Future<void> close() => Future.value();
  @override Future<void> get done => Future.value();
  @override Future<void> flush() => Future.value();
  @override void write(Object? object) {}
  @override void writeAll(Iterable<Object?> objects, [String separator = '']) {}
  @override void writeCharCode(int charCode) {}
  @override void writeln([Object? object = '']) {}
}

/// Build a GOWA v8 webhook envelope for testing.
Map<String, dynamic> _v8Envelope({
  String event = 'message',
  String? deviceId,
  required Map<String, dynamic> payload,
}) => {
  'event': event,
  'device_id': ?deviceId,
  'payload': payload,
};

void main() {
  late FakeGowaManager gowa;
  late FakeChannelManager channelManager;
  late WhatsAppChannel channel;

  setUp(() {
    gowa = FakeGowaManager();
    channelManager = FakeChannelManager();
    channel = WhatsAppChannel(
      gowa: gowa,
      config: WhatsAppConfig(
        enabled: true,
        groupAccess: GroupAccessMode.open,
      ),
      dmAccess: DmAccessController(mode: DmAccessMode.open),
      mentionGating: MentionGating(requireMention: false, mentionPatterns: [], ownJid: ''),
      channelManager: channelManager,
      workspaceDir: '/tmp',
    );
  });

  group('WhatsAppChannel', () {
    test('name and type', () {
      expect(channel.name, 'whatsapp');
      expect(channel.type, ChannelType.whatsapp);
    });

    test('ownsJid matches WhatsApp JID formats', () {
      expect(channel.ownsJid('123456@s.whatsapp.net'), isTrue);
      expect(channel.ownsJid('group123@g.us'), isTrue);
      expect(channel.ownsJid('user@telegram.org'), isFalse);
      expect(channel.ownsJid('plain-string'), isFalse);
    });

    test('connect starts GOWA', () async {
      await channel.connect();
      expect(gowa.started, isTrue);
    });

    test('disconnect stops GOWA', () async {
      await channel.disconnect();
      expect(gowa.stopped, isTrue);
    });

    test('sendMessage sends text via GOWA', () async {
      await channel.sendMessage('123@s.whatsapp.net', ChannelResponse(text: 'Hello'));
      expect(gowa.sentTexts, [('123@s.whatsapp.net', 'Hello')]);
    });

    test('sendMessage sends media before text', () async {
      await channel.sendMessage(
        '123@s.whatsapp.net',
        ChannelResponse(text: 'Caption', mediaAttachments: ['/tmp/photo.jpg']),
      );
      expect(gowa.sentMedia, [('123@s.whatsapp.net', '/tmp/photo.jpg')]);
      expect(gowa.sentTexts, [('123@s.whatsapp.net', 'Caption')]);
    });

    test('sendMessage skips empty text', () async {
      await channel.sendMessage(
        '123@s.whatsapp.net',
        ChannelResponse(text: '', mediaAttachments: ['/tmp/photo.jpg']),
      );
      expect(gowa.sentMedia, hasLength(1));
      expect(gowa.sentTexts, isEmpty);
    });

    // ---- v8 webhook parsing ----

    test('handleWebhook routes DM message (v8 envelope)', () {
      channel.handleWebhook(_v8Envelope(
        payload: {
          'from': '123@s.whatsapp.net',
          'body': 'Hello agent',
          'chat_id': '123@s.whatsapp.net',
          'from_name': 'Alice',
        },
      ));
      expect(channelManager.received, hasLength(1));
      expect(channelManager.received.first.text, 'Hello agent');
      expect(channelManager.received.first.senderJid, '123@s.whatsapp.net');
      expect(channelManager.received.first.metadata['pushname'], 'Alice');
    });

    test('handleWebhook parses group message (v8 envelope)', () {
      channel.handleWebhook(_v8Envelope(
        payload: {
          'from': '123@s.whatsapp.net',
          'body': 'group msg',
          'chat_id': 'grp@g.us',
          'from_name': 'Bob',
        },
      ));
      expect(channelManager.received, hasLength(1));
      expect(channelManager.received.first.groupJid, 'grp@g.us');
    });

    test('handleWebhook ignores non-message events', () {
      channel.handleWebhook(_v8Envelope(
        event: 'reaction',
        payload: {
          'from': '123@s.whatsapp.net',
          'body': 'some reaction',
          'chat_id': '123@s.whatsapp.net',
        },
      ));
      expect(channelManager.received, isEmpty);
    });

    test('handleWebhook ignores is_from_me messages', () {
      channel.handleWebhook(_v8Envelope(
        payload: {
          'from': '123@s.whatsapp.net',
          'body': 'my own message',
          'chat_id': '123@s.whatsapp.net',
          'is_from_me': true,
        },
      ));
      expect(channelManager.received, isEmpty);
    });

    test('handleWebhook drops message with missing body', () {
      channel.handleWebhook(_v8Envelope(
        payload: {
          'from': '123@s.whatsapp.net',
          'chat_id': '123@s.whatsapp.net',
        },
      ));
      expect(channelManager.received, isEmpty);
    });

    test('handleWebhook drops message with missing from', () {
      channel.handleWebhook(_v8Envelope(
        payload: {
          'body': 'text',
          'chat_id': '123@s.whatsapp.net',
        },
      ));
      expect(channelManager.received, isEmpty);
    });

    test('handleWebhook handles malformed envelope gracefully', () {
      // Missing payload entirely
      channel.handleWebhook({'event': 'message'});
      expect(channelManager.received, isEmpty);

      // Payload is not a map
      channel.handleWebhook({'event': 'message', 'payload': 'invalid'});
      expect(channelManager.received, isEmpty);
    });

    test('handleWebhook preserves replied_to_id in metadata', () {
      channel.handleWebhook(_v8Envelope(
        payload: {
          'from': '123@s.whatsapp.net',
          'body': 'replying',
          'chat_id': '123@s.whatsapp.net',
          'replied_to_id': 'msg-id-456',
        },
      ));
      expect(channelManager.received.first.metadata['repliedToId'], 'msg-id-456');
    });

    test('handleWebhook respects group disabled policy', () {
      final disabledChannel = WhatsAppChannel(
        gowa: gowa,
        config: WhatsAppConfig(enabled: true, groupAccess: GroupAccessMode.disabled),
        dmAccess: DmAccessController(mode: DmAccessMode.open),
        mentionGating: MentionGating(requireMention: false, mentionPatterns: [], ownJid: ''),
        channelManager: channelManager,
        workspaceDir: '/tmp',
      );

      disabledChannel.handleWebhook(_v8Envelope(
        payload: {
          'from': '123@s.whatsapp.net',
          'body': 'group msg',
          'chat_id': 'grp@g.us',
        },
      ));
      expect(channelManager.received, isEmpty);
    });

    test('handleWebhook respects DM access control', () {
      final restrictedChannel = WhatsAppChannel(
        gowa: gowa,
        config: WhatsAppConfig(enabled: true),
        dmAccess: DmAccessController(mode: DmAccessMode.disabled),
        mentionGating: MentionGating(requireMention: false, mentionPatterns: [], ownJid: ''),
        channelManager: channelManager,
        workspaceDir: '/tmp',
      );

      restrictedChannel.handleWebhook(_v8Envelope(
        payload: {
          'from': '123@s.whatsapp.net',
          'body': 'Hello',
          'chat_id': '123@s.whatsapp.net',
        },
      ));
      expect(channelManager.received, isEmpty);
    });

    test('v8 mentionedJids are empty (removed in v8)', () {
      channel.handleWebhook(_v8Envelope(
        payload: {
          'from': '123@s.whatsapp.net',
          'body': 'Hello @bot',
          'chat_id': 'grp@g.us',
        },
      ));
      expect(channelManager.received.first.mentionedJids, isEmpty);
    });

    test('formatResponse returns ChannelResponse list', () {
      final responses = channel.formatResponse('Hello from agent');
      expect(responses, isNotEmpty);
      expect(responses.first.text, isNotEmpty);
    });

    test('formatResponse overrides Channel default with WhatsApp formatting', () {
      final responses = channel.formatResponse('Test output');
      expect(responses.first.text, contains('Claude'));
    });

    test('connect sets ownJid from GOWA getStatus deviceId', () async {
      gowa.statusResult = (isConnected: true, isLoggedIn: true, deviceId: '1234567890@s.whatsapp.net');
      final mg = MentionGating(requireMention: true, mentionPatterns: [], ownJid: '');
      final ch = WhatsAppChannel(
        gowa: gowa,
        config: WhatsAppConfig(enabled: true),
        dmAccess: DmAccessController(mode: DmAccessMode.open),
        mentionGating: mg,
        channelManager: channelManager,
        workspaceDir: '/tmp',
      );
      await ch.connect();
      expect(mg.ownJid, '1234567890@s.whatsapp.net');
    });

    test('connect handles missing deviceId gracefully', () async {
      gowa.statusResult = (isConnected: false, isLoggedIn: false, deviceId: null);
      final mg = MentionGating(requireMention: true, mentionPatterns: [], ownJid: '');
      final ch = WhatsAppChannel(
        gowa: gowa,
        config: WhatsAppConfig(enabled: true),
        dmAccess: DmAccessController(mode: DmAccessMode.open),
        mentionGating: mg,
        channelManager: channelManager,
        workspaceDir: '/tmp',
      );
      await ch.connect();
      expect(mg.ownJid, ''); // Stays empty, no crash
    });
  });
}
