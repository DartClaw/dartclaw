import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'dart:async';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_signal/dartclaw_signal.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' show FakeChannelManager;
import 'package:fake_async/fake_async.dart';
import 'package:logging/logging.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Test doubles
// ---------------------------------------------------------------------------
class FakeSignalCliManager extends SignalCliManager {
  bool started = false;
  bool stopped = false;
  bool wasReset = false;
  final List<(String, String)> sentMessages = [];
  final List<bool> sentMessageGroups = [];
  final List<List<String>> sentMessageStyles = [];
  final List<(String, bool, bool)> typingCalls = [];
  final List<(String, bool, bool)> typingUpdates = [];
  final List<String> lifecycleEvents = [];
  Completer<void>? nextTypingGate;
  bool failNextTyping = false;
  bool fakeHealthy = true;
  SignalRegistrationState fakeRegistrationState = SignalRegistrationState.registered;
  int registrationChecks = 0;

  final StreamController<Map<String, dynamic>> _fakeEvents = StreamController<Map<String, dynamic>>.broadcast();

  new()
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
  Future<void> reset() async {
    wasReset = true;
    lifecycleEvents.add('reset');
  }

  @override
  Future<SignalRegistrationState> registrationState() async {
    registrationChecks++;
    return fakeRegistrationState;
  }

  @override
  Future<void> sendMessage(
    String recipient,
    String text, {
    required bool isGroup,
    List<String> textStyles = const [],
  }) async {
    sentMessages.add((recipient, text));
    sentMessageGroups.add(isGroup);
    sentMessageStyles.add(textStyles);
  }

  @override
  Future<void> sendTyping(String recipient, {required bool isGroup, required bool isTyping}) async {
    typingCalls.add((recipient, isGroup, isTyping));
    final gate = nextTypingGate;
    nextTypingGate = null;
    final shouldFail = failNextTyping;
    failNextTyping = false;
    await gate?.future;
    if (shouldFail) throw StateError('typing failed');
    typingUpdates.add((recipient, isGroup, isTyping));
    lifecycleEvents.add('typing:${isTyping ? 'start' : 'stop'}:$recipient');
  }

  /// Simulate an inbound SSE event.
  void emitEvent(Map<String, dynamic> payload) {
    _fakeEvents.add(payload);
  }
}

/// Build a signal-cli envelope for testing.
Map<String, dynamic> _signalEnvelope({
  required String source,
  String? sourceNumber,
  String? sourceUuid,
  String? sourceName,
  String? message,
  String? groupId,
}) => {
  'envelope': {
    'source': source,
    // ignore: use_null_aware_elements
    if (sourceNumber != null) 'sourceNumber': sourceNumber,
    // ignore: use_null_aware_elements
    if (sourceUuid != null) 'sourceUuid': sourceUuid,
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

SignalChannel _makeChannel({
  required FakeSignalCliManager sidecar,
  required FakeChannelManager channelManager,
  SignalConfig config = const SignalConfig(enabled: true, groupAccess: GroupAccessMode.open),
  DmAccessController? dmAccess,
  MentionGating? mentionGating,
  String? dataDir,
}) {
  return SignalChannel(
    sidecar: sidecar,
    config: config,
    dmAccess: dmAccess ?? DmAccessController(mode: DmAccessMode.open),
    mentionGating: mentionGating ?? MentionGating(requireMention: false, mentionPatterns: [], ownJid: ''),
    channelManager: channelManager,
    dataDir: dataDir,
  );
}

Future<void> _emitAndPump(FakeSignalCliManager sidecar, Map<String, dynamic> event) async {
  sidecar.emitEvent(event);
  await Future<void>.delayed(Duration.zero);
}

void main() {
  late FakeSignalCliManager sidecar;
  late FakeChannelManager channelManager;
  late SignalChannel channel;

  setUp(() {
    sidecar = FakeSignalCliManager();
    channelManager = FakeChannelManager();
    channel = _makeChannel(sidecar: sidecar, channelManager: channelManager);
  });

  group('SignalChannel', () {
    test('name and type', () {
      expect(channel.name, 'signal');
      expect(channel.type, ChannelType.signal);
    });

    test('ownsJid matches E.164 phone numbers', () {
      expect(channel.ownsJid('+1234567890'), isTrue);
      expect(channel.ownsJid('+44771234567'), isTrue);
      expect(channel.ownsJid('12BFCD5A-1234-5678-9ABC-1234567890AB'), isTrue);
      expect(channel.ownsJid('1234567890'), isFalse); // no + prefix
      expect(channel.ownsJid('user@s.whatsapp.net'), isFalse);
      expect(channel.ownsJid('+123@something'), isFalse); // has @
      expect(channel.ownsJid('+2lnbmFsLWdyb3Vw=='), isFalse); // base64 group ID can start with +
    });

    test('connect starts sidecar and subscribes to events', () async {
      await channel.connect();
      expect(sidecar.started, isTrue);
      expect(sidecar.registrationChecks, 1);
    });

    test('connect warns instead of claiming readiness without a registered account', () async {
      sidecar.fakeRegistrationState = SignalRegistrationState.unregistered;
      final records = <LogRecord>[];
      final sub = Logger.root.onRecord.listen(records.add);
      addTearDown(sub.cancel);

      await channel.connect();

      expect(records.where((record) => record.message == 'Signal channel connected'), isEmpty);
      expect(
        records,
        contains(
          isA<LogRecord>()
              .having((record) => record.level, 'level', Level.WARNING)
              .having((record) => record.message, 'message', contains('no account is registered')),
        ),
      );
    });

    test('connect reports an indeterminate registration check without claiming no account', () async {
      sidecar.fakeRegistrationState = SignalRegistrationState.unknown;
      final records = <LogRecord>[];
      final sub = Logger.root.onRecord.listen(records.add);
      addTearDown(sub.cancel);

      await channel.connect();

      expect(records.where((record) => record.message.contains('no account is registered')), isEmpty);
      expect(
        records,
        contains(
          isA<LogRecord>()
              .having((record) => record.level, 'level', Level.WARNING)
              .having((record) => record.message, 'message', contains('could not be confirmed')),
        ),
      );
    });

    test('disconnect resets sidecar for re-pairing', () async {
      await channel.connect();
      await channel.disconnect();
      expect(sidecar.wasReset, isTrue);
    });

    test('sendMessage sends text via sidecar', () async {
      await channel.sendMessage('+1234567890', const ChannelResponse(text: 'Hello'));
      expect(sidecar.sentMessages, [('+1234567890', 'Hello')]);
      expect(sidecar.sentMessageGroups, [false]);
    });

    test('sendMessage forwards native Signal text styles', () async {
      await channel.sendMessage(
        '+1234567890',
        const ChannelResponse(
          text: 'Hello',
          metadata: {
            'textStyles': ['0:5:BOLD'],
          },
        ),
      );

      expect(sidecar.sentMessageStyles, [
        ['0:5:BOLD'],
      ]);
    });

    test('sendMessage routes group IDs through the group RPC parameter', () async {
      await channel.sendMessage('+2lnbmFsLWdyb3Vw==', const ChannelResponse(text: 'Hello group'));

      expect(sidecar.sentMessages, [('+2lnbmFsLWdyb3Vw==', 'Hello group')]);
      expect(sidecar.sentMessageGroups, [true]);
    });

    test('sendMessage treats mixed-case Signal UUIDs as direct recipients', () async {
      await channel.sendMessage(
        '12BFCD5A-1234-5678-9ABC-1234567890AB',
        const ChannelResponse(text: 'Hello sealed sender'),
      );

      expect(sidecar.sentMessageGroups, [false]);
    });

    test('startTyping and stopTyping use direct recipient semantics', () async {
      await channel.startTyping('+1234567890');
      await channel.stopTyping('+1234567890');

      expect(sidecar.typingUpdates, [('+1234567890', false, true), ('+1234567890', false, false)]);
    });

    test('startTyping and stopTyping use group semantics for group IDs', () async {
      await channel.startTyping('+2lnbmFsLWdyb3Vw==');
      await channel.stopTyping('+2lnbmFsLWdyb3Vw==');

      expect(sidecar.typingUpdates, [('+2lnbmFsLWdyb3Vw==', true, true), ('+2lnbmFsLWdyb3Vw==', true, false)]);
    });

    test('serializes an in-flight refresh before STOP and prevents later refreshes', () {
      fakeAsync((async) {
        unawaited(channel.startTyping('+1234567890'));
        async.flushMicrotasks();

        final refreshGate = Completer<void>();
        sidecar.nextTypingGate = refreshGate;
        async.elapse(const Duration(seconds: 10));
        async.flushMicrotasks();

        expect(sidecar.typingCalls, [('+1234567890', false, true), ('+1234567890', false, true)]);
        expect(sidecar.typingUpdates, [('+1234567890', false, true)]);

        unawaited(channel.stopTyping('+1234567890'));
        async.flushMicrotasks();

        expect(sidecar.typingCalls, [('+1234567890', false, true), ('+1234567890', false, true)]);

        refreshGate.complete();
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 20));
        async.flushMicrotasks();

        expect(sidecar.typingUpdates, [
          ('+1234567890', false, true),
          ('+1234567890', false, true),
          ('+1234567890', false, false),
        ]);
      });
    });

    test('keeps shared recipient typing active until every turn settles', () async {
      final startGate = Completer<void>();
      sidecar.nextTypingGate = startGate;

      final starts = [
        channel.startTyping('+1234567890'),
        channel.startTyping('+1234567890'),
        channel.startTyping('+1234567890'),
      ];
      await pumpEventQueue();

      expect(sidecar.typingCalls, [('+1234567890', false, true)]);

      startGate.complete();
      await Future.wait(starts);
      await channel.stopTyping('+1234567890');
      await channel.stopTyping('+1234567890');

      expect(sidecar.typingUpdates, [('+1234567890', false, true)]);

      await channel.stopTyping('+1234567890');
      expect(sidecar.typingUpdates, [('+1234567890', false, true), ('+1234567890', false, false)]);
    });

    test('disconnect stops active typing before reset and rejects later starts', () async {
      await channel.startTyping('+1234567890');

      await channel.disconnect();
      await channel.startTyping('+1234567890');

      expect(sidecar.typingUpdates, [('+1234567890', false, true), ('+1234567890', false, false)]);
      expect(sidecar.lifecycleEvents, ['typing:start:+1234567890', 'typing:stop:+1234567890', 'reset']);
    });

    test('disconnect retries a failed final typing STOP', () async {
      await channel.startTyping('+1234567890');
      sidecar.failNextTyping = true;

      await expectLater(channel.stopTyping('+1234567890'), throwsStateError);
      await channel.disconnect();

      expect(sidecar.typingCalls, [
        ('+1234567890', false, true),
        ('+1234567890', false, false),
        ('+1234567890', false, false),
      ]);
      expect(sidecar.lifecycleEvents, ['typing:start:+1234567890', 'typing:stop:+1234567890', 'reset']);
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
      await _emitAndPump(sidecar, _signalEnvelope(source: '+1234567890', sourceName: 'Alice', message: 'Hello agent'));
      expect(channelManager.received, hasLength(1));
      expect(channelManager.received.first.text, 'Hello agent');
      expect(channelManager.received.first.senderJid, '+1234567890');
      expect(channelManager.received.first.channelType, ChannelType.signal);
      expect(channelManager.received.first.metadata['sourceName'], 'Alice');
    });

    test('SSE event parses group message', () async {
      await channel.connect();
      await _emitAndPump(
        sidecar,
        _signalEnvelope(source: '+1234567890', message: 'group msg', groupId: 'group-abc-123'),
      );
      expect(channelManager.received, hasLength(1));
      expect(channelManager.received.first.groupJid, 'group-abc-123');
    });

    test('SSE event ignores missing envelope', () async {
      await channel.connect();
      await _emitAndPump(sidecar, {'other': 'data'});
      expect(channelManager.received, isEmpty);
    });

    test('SSE event ignores missing dataMessage', () async {
      await channel.connect();
      await _emitAndPump(sidecar, {
        'envelope': {'source': '+1234567890'},
      });
      expect(channelManager.received, isEmpty);
    });

    test('SSE event ignores missing message text', () async {
      await channel.connect();
      await _emitAndPump(sidecar, _signalEnvelope(source: '+1234567890'));
      expect(channelManager.received, isEmpty);
    });

    test('SSE event ignores empty source', () async {
      await channel.connect();
      await _emitAndPump(sidecar, _signalEnvelope(source: '', message: 'text'));
      expect(channelManager.received, isEmpty);
    });

    test('SSE event handles malformed envelope gracefully', () async {
      await channel.connect();
      await _emitAndPump(sidecar, {'envelope': 'invalid'});
      expect(channelManager.received, isEmpty);
    });

    test('SSE event respects DM access control', () async {
      final restrictedChannel = _makeChannel(
        sidecar: sidecar,
        channelManager: channelManager,
        config: const SignalConfig(enabled: true),
        dmAccess: DmAccessController(mode: DmAccessMode.disabled),
      );

      await restrictedChannel.connect();
      await _emitAndPump(sidecar, _signalEnvelope(source: '+1234567890', message: 'Hello'));
      expect(channelManager.received, isEmpty);
    });

    test('SSE event respects DM allowlist', () async {
      final allowlistChannel = _makeChannel(
        sidecar: sidecar,
        channelManager: channelManager,
        config: const SignalConfig(enabled: true),
        dmAccess: DmAccessController(mode: DmAccessMode.allowlist, allowlist: {'+9999999999'}),
      );

      await allowlistChannel.connect();

      await _emitAndPump(sidecar, _signalEnvelope(source: '+1234567890', message: 'Hello'));
      expect(channelManager.received, isEmpty);

      await _emitAndPump(sidecar, _signalEnvelope(source: '+9999999999', message: 'Hi'));
      expect(channelManager.received, hasLength(1));
    });

    test('SSE event respects mention gating for groups', () async {
      final gatedChannel = _makeChannel(
        sidecar: sidecar,
        channelManager: channelManager,
        config: const SignalConfig(enabled: true, groupAccess: GroupAccessMode.open),
        mentionGating: MentionGating(requireMention: true, mentionPatterns: [r'@bot'], ownJid: '+0000'),
      );

      await gatedChannel.connect();

      await _emitAndPump(sidecar, _signalEnvelope(source: '+1234567890', message: 'random chat', groupId: 'grp-1'));
      expect(channelManager.received, isEmpty);

      await _emitAndPump(
        sidecar,
        _signalEnvelope(source: '+1234567890', message: '@bot what is 2+2?', groupId: 'grp-1'),
      );
      expect(channelManager.received, hasLength(1));
    });

    // ---- formatResponse ----

    test('formatResponse returns single response for short text', () {
      final responses = channel.formatResponse('Hello from agent');
      expect(responses, hasLength(1));
      expect(responses.first.text, 'Hello from agent');
    });

    test('formatResponse converts Markdown to Signal text and native style ranges', () {
      const markdown = '''## Summary

Use **bold**, _italic_, ~~old~~, and `code`.

| Item | State |
| --- | --- |
| Build | **Pass** |''';

      final response = channel.formatResponse(markdown).single;

      const expected = '''Summary

Use bold, italic, old, and code.

Item | State
Build | Pass''';
      expect(response.text, expected);
      expect(response.metadata['textStyles'], [
        '${expected.indexOf('Summary')}:7:BOLD',
        '${expected.indexOf('bold')}:4:BOLD',
        '${expected.indexOf('italic')}:6:ITALIC',
        '${expected.indexOf(', old') + 2}:3:STRIKETHROUGH',
        '${expected.indexOf('code')}:4:MONOSPACE',
        '${expected.indexOf('Item')}:4:BOLD',
        '${expected.indexOf('State')}:5:BOLD',
        '${expected.indexOf('Pass')}:4:BOLD',
      ]);
    });

    test('formatResponse measures Signal styles in UTF-16 code units', () {
      final response = channel.formatResponse('**😀 bold**').single;

      expect(response.text, '😀 bold');
      expect(response.metadata['textStyles'], ['0:7:BOLD']);
    });

    test('formatResponse remaps styles across chunk prefixes', () {
      final smallChunkChannel = _makeChannel(
        sidecar: sidecar,
        channelManager: channelManager,
        config: const SignalConfig(enabled: true, maxChunkSize: 50),
      );

      final responses = smallChunkChannel.formatResponse('**${'A' * 120}**');

      expect(responses.map((response) => response.text.length), [50, 50, 38]);
      expect(responses.map((response) => response.metadata['textStyles']), [
        ['6:44:BOLD'],
        ['6:44:BOLD'],
        ['6:32:BOLD'],
      ]);
    });

    test('formatResponse keeps styled emoji intact at a hard chunk boundary', () {
      final smallChunkChannel = _makeChannel(
        sidecar: sidecar,
        channelManager: channelManager,
        config: const SignalConfig(enabled: true, maxChunkSize: 50),
      );

      final responses = smallChunkChannel.formatResponse('**${'a' * 43}😀${'b' * 20}**');

      expect(responses, hasLength(2));
      expect(responses.first.text, '(1/2) ${'a' * 43}');
      expect(responses.last.text, '(2/2) 😀${'b' * 20}');
      expect(responses.map((response) => response.metadata['textStyles']), [
        ['6:43:BOLD'],
        ['6:22:BOLD'],
      ]);
    });

    test('formatResponse preserves indented code across chunk boundaries', () {
      final smallChunkChannel = _makeChannel(
        sidecar: sidecar,
        channelManager: channelManager,
        config: const SignalConfig(enabled: true, maxChunkSize: 50),
      );
      final codeLine = '  indented value';

      final responses = smallChunkChannel.formatResponse('```\n${List.filled(8, codeLine).join('\n')}\n```');

      expect(responses, hasLength(greaterThan(1)));
      expect(responses.map((response) => response.text).join().split(codeLine).length - 1, 8);
    });

    test('formatResponse renders links, images, nested lists, tasks, quotes, and fenced code', () {
      const markdown = '''[docs](https://example.com) and ![shot](https://example.com/shot.png)

- parent
  - child
- [x] done

> first
>
> second

```dart
final value = 1;
```''';

      final response = channel.formatResponse(markdown).single;

      expect(response.text, contains('docs (https://example.com)'));
      expect(response.text, contains('shot (https://example.com/shot.png)'));
      expect(response.text, contains('• parent'));
      expect(response.text, contains('  • child'));
      expect(response.text, contains('[x] done'));
      expect(response.text, contains('│ first\n\n│ second'));
      expect(response.text, contains('final value = 1;'));
      expect(response.metadata['textStyles'], contains(contains('MONOSPACE')));
    });

    test('formatResponse retains nested bold and italic styles', () {
      final response = channel.formatResponse('***both***').single;

      expect(response.text, 'both');
      expect(response.metadata['textStyles'], ['0:4:BOLD', '0:4:ITALIC']);
    });

    test('formatResponse chunks long messages', () {
      final smallChunkChannel = _makeChannel(
        sidecar: sidecar,
        channelManager: channelManager,
        config: const SignalConfig(enabled: true, maxChunkSize: 50),
      );

      final longText = 'A' * 120;
      final responses = smallChunkChannel.formatResponse(longText);
      expect(responses.length, greaterThan(1));
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
      final disabledGroupChannel = _makeChannel(
        sidecar: sidecar,
        channelManager: channelManager,
        config: const SignalConfig(enabled: true, groupAccess: GroupAccessMode.disabled),
      );

      await disabledGroupChannel.connect();
      await _emitAndPump(sidecar, _signalEnvelope(source: '+1234567890', message: 'group msg', groupId: 'grp-1'));
      expect(channelManager.received, isEmpty);
    });

    test('group access open allows group messages', () async {
      final openGroupChannel = _makeChannel(sidecar: sidecar, channelManager: channelManager);

      await openGroupChannel.connect();
      await _emitAndPump(sidecar, _signalEnvelope(source: '+1234567890', message: 'group msg', groupId: 'grp-1'));
      expect(channelManager.received, hasLength(1));
    });

    test('group access allowlist allows listed groups', () async {
      final allowlistGroupChannel = _makeChannel(
        sidecar: sidecar,
        channelManager: channelManager,
        config: const SignalConfig(
          enabled: true,
          groupAccess: GroupAccessMode.allowlist,
          groupAllowlist: [GroupEntry(id: 'grp-allowed')],
        ),
      );

      await allowlistGroupChannel.connect();

      await _emitAndPump(sidecar, _signalEnvelope(source: '+1234567890', message: 'msg', groupId: 'grp-denied'));
      expect(channelManager.received, isEmpty);

      await _emitAndPump(sidecar, _signalEnvelope(source: '+1234567890', message: 'msg', groupId: 'grp-allowed'));
      expect(channelManager.received, hasLength(1));
    });

    test('group access does not affect DM messages', () async {
      final disabledGroupChannel = _makeChannel(
        sidecar: sidecar,
        channelManager: channelManager,
        config: const SignalConfig(enabled: true, groupAccess: GroupAccessMode.disabled),
      );

      await disabledGroupChannel.connect();
      await _emitAndPump(sidecar, _signalEnvelope(source: '+1234567890', message: 'DM'));
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
      expect(config.dmAccess, DmAccessMode.open);
      expect(config.groupAccess, GroupAccessMode.allowlist);
      expect(config.dmAllowlist, ['+9999999999']);
      expect(config.groupIds, ['grp-abc']);
      expect(config.requireMention, isFalse);
      expect(config.mentionPatterns, [r'@bot']);
    });

    test('defaults access fields when not specified', () {
      final warns = <String>[];
      final config = SignalConfig.fromYaml({'enabled': true}, warns);
      expect(warns, isEmpty);
      expect(config.dmAccess, DmAccessMode.allowlist);
      expect(config.groupAccess, GroupAccessMode.disabled);
      expect(config.dmAllowlist, isEmpty);
      expect(config.groupIds, isEmpty);
      expect(config.requireMention, isTrue);
      expect(config.mentionPatterns, isEmpty);
    });

    test('accepts pairing as valid dm_access value', () {
      final warns = <String>[];
      final config = SignalConfig.fromYaml({'dm_access': 'pairing'}, warns);
      expect(warns, isEmpty);
      expect(config.dmAccess, DmAccessMode.pairing);
    });

    test('warns on invalid dm_access value', () {
      final warns = <String>[];
      final config = SignalConfig.fromYaml({
        'dm_access': 'invite', // not a valid mode
      }, warns);
      expect(warns, hasLength(1));
      expect(warns.first, contains('dm_access'));
      expect(config.dmAccess, DmAccessMode.allowlist); // default
    });

    test('warns on invalid group_access value', () {
      final warns = <String>[];
      final config = SignalConfig.fromYaml({'group_access': 'invite'}, warns);
      expect(warns, hasLength(1));
      expect(warns.first, contains('group_access'));
      expect(config.groupAccess, GroupAccessMode.disabled); // default
    });

    test('mixed string/map group_allowlist parses to correct entries', () {
      final warns = <String>[];
      final config = SignalConfig.fromYaml({
        'group_allowlist': [
          'grp-plain',
          {'id': 'grp-structured', 'name': 'Dev Group', 'effort': 'high'},
        ],
      }, warns);
      expect(warns, isEmpty);
      expect(config.groupIds, ['grp-plain', 'grp-structured']);
      expect(config.groupAllowlist[1].name, 'Dev Group');
      expect(config.groupAllowlist[1].effort, 'high');
      expect(config.groupAllowlist[0].name, isNull);
    });

    test('plain string group_allowlist is backward compatible', () {
      final config = SignalConfig.fromYaml({
        'group_allowlist': ['grp-1', 'grp-2'],
      }, []);
      expect(config.groupIds, ['grp-1', 'grp-2']);
    });
  });

  // ---- DM pairing mode wiring ----
  group('SignalChannel DM pairing wiring', () {
    late FakeSignalCliManager pairingSidecar;
    late FakeChannelManager pairingManager;

    setUp(() {
      pairingSidecar = FakeSignalCliManager();
      pairingManager = FakeChannelManager();
    });

    test('pairing mode: unknown sender triggers createPairing, message NOT forwarded', () async {
      final dmAccess = DmAccessController(mode: DmAccessMode.pairing);
      final ch = _makeChannel(sidecar: pairingSidecar, channelManager: pairingManager, dmAccess: dmAccess);

      await ch.connect();
      await _emitAndPump(pairingSidecar, _signalEnvelope(source: '+9876543210', sourceName: 'Bob', message: 'Hello'));

      expect(pairingManager.received, isEmpty);
      expect(dmAccess.pendingPairings, hasLength(1));
      expect(dmAccess.pendingPairings.first.jid, '+9876543210');
      expect(dmAccess.pendingPairings.first.displayName, 'Bob');
    });

    test('pairing mode: known sender (in allowlist) message forwarded normally', () async {
      final dmAccess = DmAccessController(mode: DmAccessMode.pairing, allowlist: {'+9876543210'});
      final ch = _makeChannel(sidecar: pairingSidecar, channelManager: pairingManager, dmAccess: dmAccess);

      await ch.connect();
      await _emitAndPump(pairingSidecar, _signalEnvelope(source: '+9876543210', message: 'Hello'));

      expect(pairingManager.received, hasLength(1));
      expect(dmAccess.pendingPairings, isEmpty);
    });

    test('allowlist mode: unknown sender drops without createPairing', () async {
      final dmAccess = DmAccessController(mode: DmAccessMode.allowlist);
      final ch = _makeChannel(sidecar: pairingSidecar, channelManager: pairingManager, dmAccess: dmAccess);

      await ch.connect();
      await _emitAndPump(pairingSidecar, _signalEnvelope(source: '+9876543210', message: 'Hello'));

      expect(pairingManager.received, isEmpty);
      expect(dmAccess.pendingPairings, isEmpty);
    });

    // ---- Sealed-sender dual-form allowlist ----

    // signal-cli's UUID casing is not part of the identity. The sealed-sender
    // fallback compares `metadata['sourceUuid']` against allowlist entries by
    // exact string, and an accepted entry is stored lowercase — so an inbound
    // UUID has to arrive canonical or the fallback misses the sender the entry
    // was written for.
    test('sealed-sender: a mixed-case inbound UUID still matches its lowercase allowlist entry', () async {
      const upper = '12BFCD5A-3363-45F4-94B6-3FE247F11AB8';
      const lower = '12bfcd5a-3363-45f4-94b6-3fe247f11ab8';
      const phone = '+46701234567';
      final dmAccess = DmAccessController(mode: DmAccessMode.allowlist, allowlist: {lower});
      final ch = _makeChannel(sidecar: pairingSidecar, channelManager: pairingManager, dmAccess: dmAccess);

      await ch.connect();
      await _emitAndPump(
        pairingSidecar,
        _signalEnvelope(source: upper, sourceNumber: phone, sourceUuid: upper, message: 'Hello'),
      );

      expect(pairingManager.received, hasLength(1));
      expect(pairingManager.received.first.metadata['sourceUuid'], lower);
      expect(dmAccess.allowlist, containsAll([lower, phone]));
    });

    test('sealed-sender: a uuid-only mixed-case sender resolves to the canonical spelling', () async {
      const upper = '12BFCD5A-3363-45F4-94B6-3FE247F11AB8';
      const lower = '12bfcd5a-3363-45f4-94b6-3fe247f11ab8';
      final dmAccess = DmAccessController(mode: DmAccessMode.allowlist, allowlist: {lower});
      final ch = _makeChannel(sidecar: pairingSidecar, channelManager: pairingManager, dmAccess: dmAccess);

      await ch.connect();
      await _emitAndPump(pairingSidecar, _signalEnvelope(source: upper, sourceUuid: upper, message: 'Hello'));

      expect(pairingManager.received, hasLength(1));
      expect(pairingManager.received.first.senderJid, lower);
    });

    test('sealed-sender: phone message allowed when allowlist holds UUID, allowlist normalized', () async {
      const uuid = '12bfcd5a-3363-45f4-94b6-3fe247f11ab8';
      const phone = '+46701234567';
      final dmAccess = DmAccessController(mode: DmAccessMode.allowlist, allowlist: {uuid});
      final ch = _makeChannel(sidecar: pairingSidecar, channelManager: pairingManager, dmAccess: dmAccess);

      await ch.connect();
      await _emitAndPump(
        pairingSidecar,
        _signalEnvelope(source: uuid, sourceNumber: phone, sourceUuid: uuid, message: 'Hello'),
      );

      expect(pairingManager.received, hasLength(1));
      expect(pairingManager.received.first.senderJid, phone);
      // Phone form should now be in allowlist (self-healing normalization)
      expect(dmAccess.allowlist, containsAll([uuid, phone]));
    });

    test('sealed-sender: UUID message NOT resolved when allowlist holds phone (documented limitation)', () async {
      const uuid = '12bfcd5a-3363-45f4-94b6-3fe247f11ab8';
      const phone = '+46701234567';
      final dmAccess = DmAccessController(mode: DmAccessMode.allowlist, allowlist: {phone});
      final ch = _makeChannel(sidecar: pairingSidecar, channelManager: pairingManager, dmAccess: dmAccess);

      await ch.connect();
      await _emitAndPump(pairingSidecar, _signalEnvelope(source: uuid, sourceUuid: uuid, message: 'Hello'));

      // Expected: dropped — UUID→phone resolution requires contact_aliases (deferred to 0.8)
      expect(pairingManager.received, isEmpty);
    });
  });

  // ---- Sender normalization ----
  group('sender normalization', () {
    late FakeSignalCliManager normSidecar;
    late FakeChannelManager normManager;
    late Directory tempDir;

    setUp(() {
      normSidecar = FakeSignalCliManager();
      normManager = FakeChannelManager();
      tempDir = Directory.systemTemp.createTempSync('signal_norm_test_');
    });

    tearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    test('UUID-only message uses UUID as senderJid when no prior mapping', () async {
      final ch = _makeChannel(sidecar: normSidecar, channelManager: normManager, dataDir: tempDir.path);

      await ch.connect();
      await _emitAndPump(
        normSidecar,
        _signalEnvelope(
          source: '12bfcd5a-3363-45f4-94b6-3fe247f11ab8',
          sourceUuid: '12bfcd5a-3363-45f4-94b6-3fe247f11ab8',
          message: 'Hello',
        ),
      );

      expect(normManager.received, hasLength(1));
      expect(normManager.received.first.senderJid, '12bfcd5a-3363-45f4-94b6-3fe247f11ab8');
    });

    test('UUID-only message resolves to phone after prior message with both', () async {
      final ch = _makeChannel(sidecar: normSidecar, channelManager: normManager, dataDir: tempDir.path);

      await ch.connect();

      await _emitAndPump(
        normSidecar,
        _signalEnvelope(
          source: '+1234567890',
          sourceNumber: '+1234567890',
          sourceUuid: '12bfcd5a-3363-45f4-94b6-3fe247f11ab8',
          message: 'First',
        ),
      );
      expect(normManager.received, hasLength(1));
      expect(normManager.received.first.senderJid, '+1234567890');

      await _emitAndPump(
        normSidecar,
        _signalEnvelope(
          source: '12bfcd5a-3363-45f4-94b6-3fe247f11ab8',
          sourceUuid: '12bfcd5a-3363-45f4-94b6-3fe247f11ab8',
          message: 'Second',
        ),
      );
      expect(normManager.received, hasLength(2));
      expect(normManager.received[1].senderJid, '+1234567890');
    });

    test('phone change updates mapping', () async {
      final ch = _makeChannel(sidecar: normSidecar, channelManager: normManager, dataDir: tempDir.path);

      await ch.connect();

      await _emitAndPump(
        normSidecar,
        _signalEnvelope(
          source: '+1234567890',
          sourceNumber: '+1234567890',
          sourceUuid: '12bfcd5a-3363-45f4-94b6-3fe247f11ab8',
          message: 'First',
        ),
      );

      await _emitAndPump(
        normSidecar,
        _signalEnvelope(
          source: '+9876543210',
          sourceNumber: '+9876543210',
          sourceUuid: '12bfcd5a-3363-45f4-94b6-3fe247f11ab8',
          message: 'Second',
        ),
      );

      await _emitAndPump(
        normSidecar,
        _signalEnvelope(
          source: '12bfcd5a-3363-45f4-94b6-3fe247f11ab8',
          sourceUuid: '12bfcd5a-3363-45f4-94b6-3fe247f11ab8',
          message: 'Third',
        ),
      );

      expect(normManager.received, hasLength(3));
      expect(normManager.received[2].senderJid, '+9876543210');
    });

    test('sender normalization works without dataDir (no persistence)', () async {
      final ch = _makeChannel(sidecar: normSidecar, channelManager: normManager);

      await ch.connect();
      await _emitAndPump(
        normSidecar,
        _signalEnvelope(source: '+1234567890', sourceNumber: '+1234567890', message: 'Hello'),
      );

      expect(normManager.received, hasLength(1));
      expect(normManager.received.first.senderJid, '+1234567890');
    });
  });
}
