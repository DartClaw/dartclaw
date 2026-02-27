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

  FakeGowaManager()
      : super(
          executable: 'gowa',
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

    test('handleWebhook routes DM message to channel manager', () {
      channel.handleWebhook({
        'jid': '123@s.whatsapp.net',
        'message': 'Hello agent',
        'is_group': false,
      });
      expect(channelManager.received, hasLength(1));
      expect(channelManager.received.first.text, 'Hello agent');
      expect(channelManager.received.first.senderJid, '123@s.whatsapp.net');
    });

    test('handleWebhook drops message with missing text', () {
      channel.handleWebhook({'jid': '123@s.whatsapp.net'});
      expect(channelManager.received, isEmpty);
    });

    test('handleWebhook drops message with missing jid', () {
      channel.handleWebhook({'message': 'text'});
      expect(channelManager.received, isEmpty);
    });

    test('handleWebhook parses group message', () {
      channel.handleWebhook({
        'jid': '123@s.whatsapp.net',
        'message': 'group msg',
        'is_group': true,
        'group_jid': 'grp@g.us',
      });
      expect(channelManager.received, hasLength(1));
      expect(channelManager.received.first.groupJid, 'grp@g.us');
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

      disabledChannel.handleWebhook({
        'jid': '123@s.whatsapp.net',
        'message': 'group msg',
        'is_group': true,
        'group_jid': 'grp@g.us',
      });
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

      restrictedChannel.handleWebhook({
        'jid': '123@s.whatsapp.net',
        'message': 'Hello',
        'is_group': false,
      });
      expect(channelManager.received, isEmpty);
    });

    test('handleWebhook parses mentioned JIDs', () {
      channel.handleWebhook({
        'jid': '123@s.whatsapp.net',
        'message': 'Hello @bot',
        'is_group': true,
        'group_jid': 'grp@g.us',
        'mentioned_jids': ['bot@s.whatsapp.net'],
      });
      expect(channelManager.received.first.mentionedJids, ['bot@s.whatsapp.net']);
    });

    test('formatAgentResponse returns ChannelResponse list', () {
      final responses = channel.formatAgentResponse('Hello from agent');
      expect(responses, isNotEmpty);
      expect(responses.first.text, isNotEmpty);
    });
  });
}
