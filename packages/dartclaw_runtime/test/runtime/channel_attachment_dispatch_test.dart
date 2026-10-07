import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/src/behavior/behavior_file_service.dart';
import 'package:dartclaw_runtime/src/execution_policy_resolver.dart';
import 'package:dartclaw_runtime/src/runtime/channel_agent_binding.dart';
import 'package:dartclaw_runtime/src/runtime/channel_wiring.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'channel_wiring_test_support.dart' show RecordingChannelTurnManager;

void main() {
  late Directory tempDir;
  late SessionService sessions;
  late MessageService messages;
  late RecordingChannelTurnManager turns;

  const sessionKey = 'agent:main:slack:dm:U1';
  final provenance = TurnProvenance.channel(
    channelType: ChannelType.slack,
    recipientId: 'U1',
    sessionKey: sessionKey,
    senderId: 'U1',
  );
  final png = List<int>.generate(1024 * 1024, (index) => (index * 7) & 0xff);

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('dartclaw-channel-attachments-');
    sessions = SessionService(baseDir: tempDir.path);
    messages = MessageService(baseDir: tempDir.path);
    turns = RecordingChannelTurnManager();
    addTearDown(turns.executions.dispose);
  });

  tearDown(() => tempDir.deleteSync(recursive: true));

  Future<String> dispatch(
    String text, {
    List<ChannelAttachment> attachments = const [],
    ChannelAgentBinding? binding,
  }) => dispatchChannelTurn(
    sessions: sessions,
    messages: messages,
    turnManagerGetter: () => turns,
    sessionKey: sessionKey,
    message: text,
    channelType: ChannelType.slack,
    senderJid: 'U1',
    senderDisplayName: 'Alice',
    provenance: provenance,
    binding: binding,
    attachments: attachments,
  );

  Future<Session> theSession() async => (await sessions.getByKey(sessionKey))!;

  final notes = ChannelAttachment(
    filename: 'notes.md',
    mediaType: 'text/markdown',
    bytes: utf8.encode('# plan\nship it'),
  );
  final shot = ChannelAttachment(filename: 'shot.png', mediaType: 'image/png', bytes: png);

  test('a file and an image are staged in the web composer form and named in the turn', () async {
    await dispatch('see attached', attachments: [notes, shot]);

    final session = await theSession();
    final directory = Directory(p.join(tempDir.path, session.id, 'attachments'));
    final stored = [
      for (final file in directory.listSync().whereType<File>().where((file) => file.path.endsWith('.json')))
        jsonDecode(file.readAsStringSync()) as Map<String, dynamic>,
    ]..sort((a, b) => (a['filename'] as String).compareTo(b['filename'] as String));
    expect(stored.map((meta) => meta['filename']), ['notes.md', 'shot.png']);
    for (final meta in stored) {
      expect(meta['state'], 'ready');
      expect(meta['digest'], startsWith('sha256:'));
      expect(File(p.join(directory.path, '${meta['id']}.data')).existsSync(), isTrue);
    }
    expect(stored.last['size'], png.length);

    final entry = turns.turnEntries.single.last;
    final content = entry['content'] as String;
    expect(content, startsWith('see attached'));
    expect(content, contains('[rich_input_context'));
    expect(content, contains('ship it'), reason: 'text files are inlined as the web composer does');
    expect(content, contains('shot.png'));
    expect(content, contains('image/png'));
    expect(content, isNot(contains(base64Encode(png.take(64).toList()))), reason: 'the PNG is named, never inlined');
    expect(entry['images'], [
      {'mediaType': 'image/png', 'data': base64Encode(png)},
    ]);
  });

  test('the stored user message lists both files without content or image bytes', () async {
    await dispatch('see attached', attachments: [notes, shot]);

    final user = (await messages.getMessages((await theSession()).id)).single;
    final metadata = jsonDecode(user.metadata!) as Map<String, dynamic>;
    expect(metadata['senderDisplayName'], 'Alice');
    final attachments = (metadata['attachments'] as List).cast<Map<String, dynamic>>();
    expect(attachments.map((attachment) => attachment['filename']), ['notes.md', 'shot.png']);
    expect(attachments.every((attachment) => !attachment.containsKey('contentText')), isTrue);
    expect(user.metadata, isNot(contains('ship it')));
    expect(user.metadata, isNot(contains(base64Encode(png.take(64).toList()))));
    expect(user.content, 'see attached');
  });

  test('a message without attachments builds the pre-change history and metadata', () async {
    await dispatch('plain');

    final user = (await messages.getMessages((await theSession()).id)).single;
    expect(user.metadata, jsonEncode({'senderDisplayName': 'Alice'}));
    expect(turns.turnEntries.single, [
      {'role': 'user', 'content': 'plain'},
    ]);
  });

  test('a PNG on an earlier turn is named in its entry and not sent again', () async {
    await dispatch('first', attachments: [shot]);
    await dispatch('second');

    final entries = turns.turnEntries.last;
    expect(entries.first['content'], allOf(contains('shot.png'), contains('[rich_input_context')));
    expect(entries.any((entry) => entry.containsKey('images')), isFalse);
  });

  test('an oversize PNG and an SVG are named and sent as no image', () async {
    final big = ChannelAttachment(
      filename: 'big.png',
      mediaType: 'image/png',
      bytes: List<int>.filled(6 * 1024 * 1024, 1),
    );
    final svg = ChannelAttachment(filename: 'logo.svg', mediaType: 'image/svg+xml', bytes: utf8.encode('<svg/>'));

    await dispatch('look', attachments: [big, svg]);

    final entry = turns.turnEntries.single.last;
    expect(entry, isNot(contains('images')));
    expect(entry['content'], allOf(contains('big.png'), contains('logo.svg')));
  });

  test('a bound agent turn gets the same entry', () async {
    final ownerWorkspace = Directory(p.join(tempDir.path, 'workspace'))..createSync();
    final binder = ChannelAgentBinder(
      agents: const {'ana': AgentDefinition(id: 'ana', description: 'Ana', prompt: 'You are Ana.')},
      policyResolver: ExecutionPolicyResolver(
        config: DartclawConfig.defaults(),
        availableContainerProfiles: const {'workspace', 'restricted'},
      ),
      defaultProviderId: 'claude',
      behavior: BehaviorFileService(workspaceDir: ownerWorkspace.path),
    );

    await dispatch(
      'bound',
      attachments: [shot],
      binding: binder.bind(const GroupEntry(id: 'U1', agent: 'ana')),
    );

    final entry = turns.turnEntries.single.last;
    expect(entry['content'], contains('shot.png'));
    expect(entry['images'], hasLength(1));
  });
}
