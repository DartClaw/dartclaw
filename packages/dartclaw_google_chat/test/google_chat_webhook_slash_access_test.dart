import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_google_chat/dartclaw_google_chat.dart';
import 'package:dartclaw_google_chat/testing.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' show FakeGoogleJwtVerifier;
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

/// Records every command the webhook lets through, so a test can assert that a
/// refused sender reached no executor at all.
class _RecordingSlashCommandExecutor implements SlashCommandExecutor {
  final List<String> handled = [];

  @override
  Future<Map<String, dynamic>> handle(
    SlashCommand command, {
    required String spaceName,
    required String senderJid,
    String? senderDisplayName,
    String? spaceType,
    String? sourceMessageId,
  }) async {
    handled.add(command.name);
    return {'text': 'executed /${command.name}'};
  }
}

/// `commandId` 2 is `/reset` in [SlashCommandParser]'s default mapping.
const _resetCommandId = 2;

/// `commandId` 3 is `/status` in [SlashCommandParser]'s default mapping.
const _statusCommandId = 3;

Map<String, dynamic> _messagePayload({
  int commandId = _resetCommandId,
  String spaceType = 'DM',
  String spaceName = 'spaces/AAAA',
  String userName = 'users/123',
  List<Map<String, dynamic>> annotations = const [],
}) {
  return {
    'type': 'MESSAGE',
    'space': {'name': spaceName, 'type': spaceType, 'displayName': 'Primary'},
    'message': {
      'name': '$spaceName/messages/BBBB',
      'sender': {'name': userName, 'type': 'HUMAN'},
      'text': '/reset',
      'slashCommand': {'commandId': commandId},
      'annotations': annotations,
    },
    'user': {'name': userName, 'displayName': 'Alice', 'type': 'HUMAN'},
  };
}

Map<String, dynamic> _appCommandPayload({
  int commandId = _resetCommandId,
  String spaceType = 'DM',
  String spaceName = 'spaces/AAAA',
  String userName = 'users/123',
}) {
  return {
    'type': 'APP_COMMAND',
    'space': {'name': spaceName, 'type': spaceType, 'displayName': 'Primary'},
    'message': {
      'name': '$spaceName/messages/BBBB',
      'sender': {'name': userName, 'type': 'HUMAN'},
      'text': '/reset',
    },
    'user': {'name': userName, 'displayName': 'Alice', 'type': 'HUMAN'},
    'appCommandMetadata': {'appCommandId': commandId},
  };
}

Future<Response> _post(GoogleChatWebhookHandler handler, Map<String, dynamic> body) {
  return handler.handle(
    Request(
      'POST',
      Uri.parse('http://localhost/integrations/googlechat'),
      headers: {'authorization': 'Bearer token'},
      body: jsonEncode(body),
    ),
  );
}

void main() {
  late FakeGoogleChatRestClient restClient;
  late FakeGoogleJwtVerifier jwtVerifier;
  late _RecordingSlashCommandExecutor executor;

  GoogleChatWebhookHandler buildHandler({
    DmAccessMode dmMode = DmAccessMode.open,
    Set<String> dmAllowlist = const {},
    GroupAccessMode groupAccess = GroupAccessMode.disabled,
    List<GroupEntry> groupAllowlist = const [],
    bool requireMention = true,
    String? botUser,
  }) {
    final dmAccess = DmAccessController(mode: dmMode, allowlist: dmAllowlist);
    final mentionGating = MentionGating(
      requireMention: requireMention,
      mentionPatterns: const [],
      ownJid: botUser ?? '',
    );
    final channel = GoogleChatChannel(
      config: GoogleChatConfig(
        webhookPath: '/integrations/googlechat',
        typingIndicatorMode: TypingIndicatorMode.disabled,
        groupAccess: groupAccess,
        groupAllowlist: groupAllowlist,
        requireMention: requireMention,
        botUser: botUser,
      ),
      restClient: restClient,
      dmAccess: dmAccess,
      mentionGating: mentionGating,
    );
    return GoogleChatWebhookHandler(
      channel: channel,
      jwtVerifier: jwtVerifier,
      config: channel.config,
      dmAccess: dmAccess,
      mentionGating: mentionGating,
      slashCommandParser: const SlashCommandParser(),
      slashCommandHandler: executor,
      responseTimeout: const Duration(milliseconds: 50),
    );
  }

  setUp(() {
    restClient = FakeGoogleChatRestClient();
    jwtVerifier = FakeGoogleJwtVerifier();
    executor = _RecordingSlashCommandExecutor();
  });

  group('slash commands are subject to the inbound gate (MESSAGE)', () {
    test('a DM sender the allowlist denies cannot reset the session', () async {
      final handler = buildHandler(dmMode: DmAccessMode.allowlist, dmAllowlist: {'users/999'});
      final response = await _post(handler, _messagePayload());
      expect(response.statusCode, 200);
      expect(await response.readAsString(), '{}');
      expect(executor.handled, isEmpty);
    });

    test('a DM sender under dm_access: disabled cannot reset the session', () async {
      final handler = buildHandler(dmMode: DmAccessMode.disabled);
      await _post(handler, _messagePayload());
      expect(executor.handled, isEmpty);
    });

    test('an unpaired DM sender gets a pairing code instead of a reset', () async {
      final handler = buildHandler(dmMode: DmAccessMode.pairing);
      await _post(handler, _messagePayload());
      expect(executor.handled, isEmpty);
      expect(restClient.sentMessages, hasLength(1));
      expect(restClient.sentMessages.first.$2, contains('pairing code'));
    });

    test('a sender in a space outside the group allowlist cannot reset the session', () async {
      final handler = buildHandler(
        groupAccess: GroupAccessMode.allowlist,
        groupAllowlist: [const GroupEntry(id: 'spaces/OTHER')],
        requireMention: false,
      );
      await _post(handler, _messagePayload(spaceType: 'ROOM', spaceName: 'spaces/GRP'));
      expect(executor.handled, isEmpty);
    });

    test('a sender in a space where group access is disabled cannot reset the session', () async {
      final handler = buildHandler(groupAccess: GroupAccessMode.disabled, requireMention: false);
      await _post(handler, _messagePayload(spaceType: 'ROOM', spaceName: 'spaces/GRP'));
      expect(executor.handled, isEmpty);
    });

    test('an admitted DM sender still reaches the executor', () async {
      final handler = buildHandler(dmMode: DmAccessMode.allowlist, dmAllowlist: {'users/123'});
      final response = await _post(handler, _messagePayload());
      expect(executor.handled, ['reset']);
      expect(await response.readAsString(), contains('executed /reset'));
    });

    // A registered slash command names this app explicitly, so mention gating —
    // a noise filter for ambient space chatter — must not swallow it.
    test('an allowlisted space still runs the command without an @mention', () async {
      final handler = buildHandler(
        groupAccess: GroupAccessMode.allowlist,
        groupAllowlist: [const GroupEntry(id: 'spaces/GRP')],
        requireMention: true,
        botUser: 'users/bot',
      );
      await _post(handler, _messagePayload(spaceType: 'ROOM', spaceName: 'spaces/GRP'));
      expect(executor.handled, ['reset']);
    });

    test('/status stays reachable for an admitted sender', () async {
      final handler = buildHandler(dmMode: DmAccessMode.open);
      await _post(handler, _messagePayload(commandId: _statusCommandId));
      expect(executor.handled, ['status']);
    });

    test('/status is refused for a denied sender like every other command', () async {
      final handler = buildHandler(dmMode: DmAccessMode.disabled);
      await _post(handler, _messagePayload(commandId: _statusCommandId));
      expect(executor.handled, isEmpty);
    });
  });

  group('slash commands are subject to the inbound gate (APP_COMMAND)', () {
    test('a DM sender the allowlist denies cannot reset the session', () async {
      final handler = buildHandler(dmMode: DmAccessMode.allowlist, dmAllowlist: {'users/999'});
      final response = await _post(handler, _appCommandPayload());
      expect(response.statusCode, 200);
      expect(await response.readAsString(), '{}');
      expect(executor.handled, isEmpty);
    });

    test('a sender in a space outside the group allowlist cannot reset the session', () async {
      final handler = buildHandler(
        groupAccess: GroupAccessMode.allowlist,
        groupAllowlist: [const GroupEntry(id: 'spaces/OTHER')],
        requireMention: false,
      );
      await _post(handler, _appCommandPayload(spaceType: 'ROOM', spaceName: 'spaces/GRP'));
      expect(executor.handled, isEmpty);
    });

    test('an admitted DM sender still reaches the executor', () async {
      final handler = buildHandler(dmMode: DmAccessMode.allowlist, dmAllowlist: {'users/123'});
      await _post(handler, _appCommandPayload());
      expect(executor.handled, ['reset']);
    });
  });
}
