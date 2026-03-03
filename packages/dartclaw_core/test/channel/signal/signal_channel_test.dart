import 'dart:async';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_core/src/channel/channel_config.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Test doubles
// ---------------------------------------------------------------------------
class FakeSignalCliManager extends SignalCliManager {
  bool started = false;
  bool stopped = false;
  final List<(String, String)> sentMessages = [];
  bool fakeHealthy = true;

  final StreamController<Map<String, dynamic>> _fakeEvents = StreamController<Map<String, dynamic>>.broadcast();

  FakeSignalCliManager()
    : super(
        executable: 'signal-cli',
        phoneNumber: '+1234567890',
        processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) async {
          throw StateError('Should not spawn');
        },
        delay: (d) => Future.value(),
      );

  @override
  bool get isRunning => fakeHealthy;

  @override
  Stream<Map<String, dynamic>> get events => _fakeEvents.stream;

  @override
  Future<void> start() async {
    started = true;
  }

  @override
  Future<void> stop() async {
    stopped = true;
  }

  @override
  Future<void> sendMessage(String recipient, String text) async {
    sentMessages.add((recipient, text));
  }

  /// Simulate an inbound SSE event.
  void emitEvent(Map<String, dynamic> payload) {
    _fakeEvents.add(payload);
  }
}

class FakeChannelManager extends ChannelManager {
  final List<ChannelMessage> received = [];

  FakeChannelManager()
    : super(
        queue: MessageQueue(dispatcher: (_, _, {senderJid}) async => '', maxConcurrentTurns: 1),
        config: const ChannelConfig.defaults(),
      );

  @override
  void handleInboundMessage(ChannelMessage message) {
    received.add(message);
  }
}

/// Build a signal-cli envelope for testing.
Map<String, dynamic> _signalEnvelope({required String source, String? sourceName, String? message, String? groupId}) =>
    {
      'envelope': {
        'source': source,
        // ignore: use_null_aware_elements
        if (sourceName != null) 'sourceName': sourceName,
        if (message != null || groupId != null)
          'dataMessage': {
            // ignore: use_null_aware_elements
            if (message != null) 'message': message,
            if (groupId != null) 'groupInfo': {'groupId': groupId},
          },
      },
    };

void main() {
  late FakeSignalCliManager sidecar;
  late FakeChannelManager channelManager;
  late SignalChannel channel;

  setUp(() {
    sidecar = FakeSignalCliManager();
    channelManager = FakeChannelManager();
    channel = SignalChannel(
      sidecar: sidecar,
      config: const SignalConfig(enabled: true, groupAccess: SignalGroupAccessMode.open),
      dmAccess: SignalDmAccessController(mode: SignalDmAccessMode.open),
      mentionGating: SignalMentionGating(requireMention: false, mentionPatterns: [], ownNumber: ''),
      channelManager: channelManager,
    );
  });

  group('SignalChannel', () {
    test('name and type', () {
      expect(channel.name, 'signal');
      expect(channel.type, ChannelType.signal);
    });

    test('ownsJid matches E.164 phone numbers', () {
      expect(channel.ownsJid('+1234567890'), isTrue);
      expect(channel.ownsJid('+44771234567'), isTrue);
      expect(channel.ownsJid('1234567890'), isFalse); // no + prefix
      expect(channel.ownsJid('user@s.whatsapp.net'), isFalse);
      expect(channel.ownsJid('+123@something'), isFalse); // has @
    });

    test('connect starts sidecar and subscribes to events', () async {
      await channel.connect();
      expect(sidecar.started, isTrue);
    });

    test('disconnect stops sidecar', () async {
      await channel.connect();
      await channel.disconnect();
      expect(sidecar.stopped, isTrue);
    });

    test('sendMessage sends text via sidecar', () async {
      await channel.sendMessage('+1234567890', const ChannelResponse(text: 'Hello'));
      expect(sidecar.sentMessages, [('+1234567890', 'Hello')]);
    });

    test('sendMessage skips empty text', () async {
      await channel.sendMessage('+1234567890', const ChannelResponse(text: ''));
      expect(sidecar.sentMessages, isEmpty);
    });

    test('sendMessage is no-op when sidecar not running', () async {
      sidecar.fakeHealthy = false;
      await channel.sendMessage('+1234567890', const ChannelResponse(text: 'Hello'));
      expect(sidecar.sentMessages, isEmpty);
    });

    // ---- SSE event routing ----

    test('SSE event routes DM message', () async {
      await channel.connect();
      sidecar.emitEvent(_signalEnvelope(source: '+1234567890', sourceName: 'Alice', message: 'Hello agent'));
      // Allow microtask to propagate
      await Future<void>.delayed(Duration.zero);
      expect(channelManager.received, hasLength(1));
      expect(channelManager.received.first.text, 'Hello agent');
      expect(channelManager.received.first.senderJid, '+1234567890');
      expect(channelManager.received.first.channelType, ChannelType.signal);
      expect(channelManager.received.first.metadata['sourceName'], 'Alice');
    });

    test('SSE event parses group message', () async {
      await channel.connect();
      sidecar.emitEvent(_signalEnvelope(source: '+1234567890', message: 'group msg', groupId: 'group-abc-123'));
      await Future<void>.delayed(Duration.zero);
      expect(channelManager.received, hasLength(1));
      expect(channelManager.received.first.groupJid, 'group-abc-123');
    });

    test('SSE event ignores missing envelope', () async {
      await channel.connect();
      sidecar.emitEvent({'other': 'data'});
      await Future<void>.delayed(Duration.zero);
      expect(channelManager.received, isEmpty);
    });

    test('SSE event ignores missing dataMessage', () async {
      await channel.connect();
      sidecar.emitEvent({
        'envelope': {'source': '+1234567890'},
      });
      await Future<void>.delayed(Duration.zero);
      expect(channelManager.received, isEmpty);
    });

    test('SSE event ignores missing message text', () async {
      await channel.connect();
      sidecar.emitEvent(_signalEnvelope(source: '+1234567890'));
      await Future<void>.delayed(Duration.zero);
      expect(channelManager.received, isEmpty);
    });

    test('SSE event ignores empty source', () async {
      await channel.connect();
      sidecar.emitEvent(_signalEnvelope(source: '', message: 'text'));
      await Future<void>.delayed(Duration.zero);
      expect(channelManager.received, isEmpty);
    });

    test('SSE event handles malformed envelope gracefully', () async {
      await channel.connect();
      sidecar.emitEvent({'envelope': 'invalid'});
      await Future<void>.delayed(Duration.zero);
      expect(channelManager.received, isEmpty);
    });

    test('SSE event respects DM access control', () async {
      final restrictedChannel = SignalChannel(
        sidecar: sidecar,
        config: const SignalConfig(enabled: true),
        dmAccess: SignalDmAccessController(mode: SignalDmAccessMode.disabled),
        mentionGating: SignalMentionGating(requireMention: false, mentionPatterns: [], ownNumber: ''),
        channelManager: channelManager,
      );

      await restrictedChannel.connect();
      sidecar.emitEvent(_signalEnvelope(source: '+1234567890', message: 'Hello'));
      await Future<void>.delayed(Duration.zero);
      expect(channelManager.received, isEmpty);
    });

    test('SSE event respects DM allowlist', () async {
      final allowlistChannel = SignalChannel(
        sidecar: sidecar,
        config: const SignalConfig(enabled: true),
        dmAccess: SignalDmAccessController(mode: SignalDmAccessMode.allowlist, allowlist: {'+9999999999'}),
        mentionGating: SignalMentionGating(requireMention: false, mentionPatterns: [], ownNumber: ''),
        channelManager: channelManager,
      );

      await allowlistChannel.connect();

      // Denied sender
      sidecar.emitEvent(_signalEnvelope(source: '+1234567890', message: 'Hello'));
      await Future<void>.delayed(Duration.zero);
      expect(channelManager.received, isEmpty);

      // Allowed sender
      sidecar.emitEvent(_signalEnvelope(source: '+9999999999', message: 'Hi'));
      await Future<void>.delayed(Duration.zero);
      expect(channelManager.received, hasLength(1));
    });

    test('SSE event respects mention gating for groups', () async {
      final gatedChannel = SignalChannel(
        sidecar: sidecar,
        config: const SignalConfig(enabled: true, groupAccess: SignalGroupAccessMode.open),
        dmAccess: SignalDmAccessController(mode: SignalDmAccessMode.open),
        mentionGating: SignalMentionGating(requireMention: true, mentionPatterns: [r'@bot'], ownNumber: '+0000'),
        channelManager: channelManager,
      );

      await gatedChannel.connect();

      // Group message without mention -> dropped
      sidecar.emitEvent(_signalEnvelope(source: '+1234567890', message: 'random chat', groupId: 'grp-1'));
      await Future<void>.delayed(Duration.zero);
      expect(channelManager.received, isEmpty);

      // Group message with mention pattern -> processed
      sidecar.emitEvent(_signalEnvelope(source: '+1234567890', message: '@bot what is 2+2?', groupId: 'grp-1'));
      await Future<void>.delayed(Duration.zero);
      expect(channelManager.received, hasLength(1));
    });

    // ---- formatResponse ----

    test('formatResponse returns single response for short text', () {
      final responses = channel.formatResponse('Hello from agent');
      expect(responses, hasLength(1));
      expect(responses.first.text, 'Hello from agent');
    });

    test('formatResponse chunks long messages', () {
      // Create a channel with small chunk size for easy testing
      final smallChunkChannel = SignalChannel(
        sidecar: sidecar,
        config: const SignalConfig(enabled: true, maxChunkSize: 50),
        dmAccess: SignalDmAccessController(mode: SignalDmAccessMode.open),
        mentionGating: SignalMentionGating(requireMention: false, mentionPatterns: [], ownNumber: ''),
        channelManager: channelManager,
      );

      final longText = 'A' * 120; // 120 chars, will need multiple chunks at maxSize=50
      final responses = smallChunkChannel.formatResponse(longText);
      expect(responses.length, greaterThan(1));
      // All responses should be ChannelResponse with text
      for (final r in responses) {
        expect(r.text, isNotEmpty);
      }
    });

    test('formatResponse returns empty list for empty text', () {
      // chunkText with empty string returns single empty chunk
      final responses = channel.formatResponse('');
      expect(responses, hasLength(1));
      expect(responses.first.text, isEmpty);
    });

    // ---- Group access control ----

    test('group access disabled drops group messages', () async {
      final disabledGroupChannel = SignalChannel(
        sidecar: sidecar,
        config: const SignalConfig(
          enabled: true,
          groupAccess: SignalGroupAccessMode.disabled,
        ),
        dmAccess: SignalDmAccessController(mode: SignalDmAccessMode.open),
        mentionGating: SignalMentionGating(requireMention: false, mentionPatterns: [], ownNumber: ''),
        channelManager: channelManager,
      );

      await disabledGroupChannel.connect();
      sidecar.emitEvent(_signalEnvelope(source: '+1234567890', message: 'group msg', groupId: 'grp-1'));
      await Future<void>.delayed(Duration.zero);
      expect(channelManager.received, isEmpty);
    });

    test('group access open allows group messages', () async {
      final openGroupChannel = SignalChannel(
        sidecar: sidecar,
        config: const SignalConfig(
          enabled: true,
          groupAccess: SignalGroupAccessMode.open,
        ),
        dmAccess: SignalDmAccessController(mode: SignalDmAccessMode.open),
        mentionGating: SignalMentionGating(requireMention: false, mentionPatterns: [], ownNumber: ''),
        channelManager: channelManager,
      );

      await openGroupChannel.connect();
      sidecar.emitEvent(_signalEnvelope(source: '+1234567890', message: 'group msg', groupId: 'grp-1'));
      await Future<void>.delayed(Duration.zero);
      expect(channelManager.received, hasLength(1));
    });

    test('group access allowlist allows listed groups', () async {
      final allowlistGroupChannel = SignalChannel(
        sidecar: sidecar,
        config: const SignalConfig(
          enabled: true,
          groupAccess: SignalGroupAccessMode.allowlist,
          groupAllowlist: ['grp-allowed'],
        ),
        dmAccess: SignalDmAccessController(mode: SignalDmAccessMode.open),
        mentionGating: SignalMentionGating(requireMention: false, mentionPatterns: [], ownNumber: ''),
        channelManager: channelManager,
      );

      await allowlistGroupChannel.connect();

      // Unlisted group -> dropped
      sidecar.emitEvent(_signalEnvelope(source: '+1234567890', message: 'msg', groupId: 'grp-denied'));
      await Future<void>.delayed(Duration.zero);
      expect(channelManager.received, isEmpty);

      // Listed group -> processed
      sidecar.emitEvent(_signalEnvelope(source: '+1234567890', message: 'msg', groupId: 'grp-allowed'));
      await Future<void>.delayed(Duration.zero);
      expect(channelManager.received, hasLength(1));
    });

    test('group access does not affect DM messages', () async {
      final disabledGroupChannel = SignalChannel(
        sidecar: sidecar,
        config: const SignalConfig(
          enabled: true,
          groupAccess: SignalGroupAccessMode.disabled,
        ),
        dmAccess: SignalDmAccessController(mode: SignalDmAccessMode.open),
        mentionGating: SignalMentionGating(requireMention: false, mentionPatterns: [], ownNumber: ''),
        channelManager: channelManager,
      );

      await disabledGroupChannel.connect();
      // DM (no groupId) should still pass even with groupAccess disabled
      sidecar.emitEvent(_signalEnvelope(source: '+1234567890', message: 'DM'));
      await Future<void>.delayed(Duration.zero);
      expect(channelManager.received, hasLength(1));
    });
  });

  // ---- SignalConfig parsing ----
  group('SignalConfig.fromYaml', () {
    test('parses access control fields', () {
      final warns = <String>[];
      final config = SignalConfig.fromYaml({
        'enabled': true,
        'phone_number': '+1234567890',
        'dm_access': 'open',
        'group_access': 'allowlist',
        'dm_allowlist': ['+9999999999'],
        'group_allowlist': ['grp-abc'],
        'require_mention': false,
        'mention_patterns': [r'@bot'],
      }, warns);
      expect(warns, isEmpty);
      expect(config.dmAccess, SignalDmAccessMode.open);
      expect(config.groupAccess, SignalGroupAccessMode.allowlist);
      expect(config.dmAllowlist, ['+9999999999']);
      expect(config.groupAllowlist, ['grp-abc']);
      expect(config.requireMention, isFalse);
      expect(config.mentionPatterns, [r'@bot']);
    });

    test('defaults access fields when not specified', () {
      final warns = <String>[];
      final config = SignalConfig.fromYaml({'enabled': true}, warns);
      expect(warns, isEmpty);
      expect(config.dmAccess, SignalDmAccessMode.allowlist);
      expect(config.groupAccess, SignalGroupAccessMode.disabled);
      expect(config.dmAllowlist, isEmpty);
      expect(config.groupAllowlist, isEmpty);
      expect(config.requireMention, isTrue);
      expect(config.mentionPatterns, isEmpty);
    });

    test('warns on invalid dm_access value', () {
      final warns = <String>[];
      final config = SignalConfig.fromYaml({
        'dm_access': 'pairing', // not valid for Signal
      }, warns);
      expect(warns, hasLength(1));
      expect(warns.first, contains('dm_access'));
      expect(config.dmAccess, SignalDmAccessMode.allowlist); // default
    });

    test('warns on invalid group_access value', () {
      final warns = <String>[];
      final config = SignalConfig.fromYaml({
        'group_access': 'invite',
      }, warns);
      expect(warns, hasLength(1));
      expect(warns.first, contains('group_access'));
      expect(config.groupAccess, SignalGroupAccessMode.disabled); // default
    });
  });
}
