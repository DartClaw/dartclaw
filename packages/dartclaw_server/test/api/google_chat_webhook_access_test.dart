import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_google_chat/dartclaw_google_chat.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:http/testing.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

class _FakeGoogleChatRestClient extends GoogleChatRestClient {
  final List<(String, String)> sentMessages = [];

  _FakeGoogleChatRestClient() : super(authClient: MockClient((request) async => throw UnimplementedError()));

  @override
  Future<String?> sendMessage(
    String spaceName,
    String text, {
    String? quotedMessageName,
    String? quotedMessageLastUpdateTime,
  }) async {
    sentMessages.add((spaceName, text));
    return '$spaceName/messages/1';
  }

  @override
  Future<bool> editMessage(String messageName, String newText) async => true;

  @override
  Future<void> testConnection() async {}
}

class _FakeGoogleJwtVerifier extends GoogleJwtVerifier {
  _FakeGoogleJwtVerifier()
    : super(
        audience: const GoogleChatAudienceConfig(
          mode: GoogleChatAudienceMode.appUrl,
          value: 'https://example.com/integrations/googlechat',
        ),
      );

  @override
  Future<bool> verify(String? authHeader) async => true;
}

Map<String, dynamic> _payload({
  String type = 'MESSAGE',
  String? text = 'Hello agent',
  String senderType = 'HUMAN',
  String senderName = 'users/123',
  String userName = 'users/123',
  String userDisplayName = 'Alice',
  String spaceType = 'DM',
  String spaceName = 'spaces/AAAA',
  List<Map<String, dynamic>> annotations = const [],
}) {
  return {
    'type': type,
    'space': {'name': spaceName, 'type': spaceType, 'displayName': 'Primary'},
    'message': {
      'name': '$spaceName/messages/BBBB',
      'sender': {'name': senderName, 'type': senderType},
      'text': text,
      'annotations': annotations,
    },
    'user': {'name': userName, 'displayName': userDisplayName, 'type': 'HUMAN'},
  };
}

Future<Response> _post(GoogleChatWebhookHandler handler, {required Object body}) {
  return handler.handle(
    Request(
      'POST',
      Uri.parse('http://localhost/integrations/googlechat'),
      headers: {'authorization': 'Bearer token'},
      body: body is String ? body : jsonEncode(body),
    ),
  );
}

void main() {
  late _FakeGoogleChatRestClient restClient;
  late _FakeGoogleJwtVerifier jwtVerifier;
  late ChannelMessage? dispatchedMessage;

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
      dispatchMessage: (message) async {
        dispatchedMessage = message;
        return 'Agent reply';
      },
      responseTimeout: const Duration(milliseconds: 50),
    );
  }

  setUp(() {
    restClient = _FakeGoogleChatRestClient();
    jwtVerifier = _FakeGoogleJwtVerifier();
    dispatchedMessage = null;
  });

  group('DM access control', () {
    test('dm_access: open — allows all senders', () async {
      final handler = buildHandler(dmMode: DmAccessMode.open);
      final response = await _post(handler, body: _payload());
      expect(response.statusCode, 200);
      expect(dispatchedMessage, isNotNull);
    });

    test('dm_access: disabled — blocks all senders', () async {
      final handler = buildHandler(dmMode: DmAccessMode.disabled);
      final response = await _post(handler, body: _payload());
      expect(response.statusCode, 200);
      expect(await response.readAsString(), '{}');
      expect(dispatchedMessage, isNull);
    });

    test('dm_access: allowlist — allows listed sender', () async {
      final handler = buildHandler(dmMode: DmAccessMode.allowlist, dmAllowlist: {'users/123'});
      final response = await _post(handler, body: _payload());
      expect(response.statusCode, 200);
      expect(dispatchedMessage, isNotNull);
    });

    test('dm_access: allowlist — blocks unlisted sender', () async {
      final handler = buildHandler(dmMode: DmAccessMode.allowlist, dmAllowlist: {'users/999'});
      final response = await _post(handler, body: _payload());
      expect(response.statusCode, 200);
      expect(dispatchedMessage, isNull);
    });

    test('dm_access: pairing — sends pairing code for unknown sender', () async {
      final handler = buildHandler(dmMode: DmAccessMode.pairing);
      final response = await _post(handler, body: _payload());
      expect(response.statusCode, 200);
      expect(dispatchedMessage, isNull);
      expect(restClient.sentMessages, hasLength(1));
      expect(restClient.sentMessages.first.$1, 'spaces/AAAA');
      expect(restClient.sentMessages.first.$2, contains('pairing code'));
    });

    test('dm_access: pairing — allows already-allowlisted sender', () async {
      final handler = buildHandler(dmMode: DmAccessMode.pairing, dmAllowlist: {'users/123'});
      final response = await _post(handler, body: _payload());
      expect(response.statusCode, 200);
      expect(dispatchedMessage, isNotNull);
      expect(restClient.sentMessages, isEmpty);
    });
  });

  group('Group access control', () {
    test('group_access: disabled — drops group messages', () async {
      final handler = buildHandler(groupAccess: GroupAccessMode.disabled);
      final response = await _post(
        handler,
        body: _payload(spaceType: 'ROOM', spaceName: 'spaces/GRP'),
      );
      expect(response.statusCode, 200);
      expect(dispatchedMessage, isNull);
    });

    test('group_access: open — allows all group messages', () async {
      final handler = buildHandler(groupAccess: GroupAccessMode.open, requireMention: false);
      final response = await _post(
        handler,
        body: _payload(spaceType: 'ROOM', spaceName: 'spaces/GRP'),
      );
      expect(response.statusCode, 200);
      expect(dispatchedMessage, isNotNull);
    });

    test('group_access: allowlist — allows listed space', () async {
      final handler = buildHandler(
        groupAccess: GroupAccessMode.allowlist,
        groupAllowlist: [const GroupEntry(id: 'spaces/GRP')],
        requireMention: false,
      );
      final response = await _post(
        handler,
        body: _payload(spaceType: 'ROOM', spaceName: 'spaces/GRP'),
      );
      expect(response.statusCode, 200);
      expect(dispatchedMessage, isNotNull);
    });

    test('group_access: allowlist — blocks unlisted space', () async {
      final handler = buildHandler(
        groupAccess: GroupAccessMode.allowlist,
        groupAllowlist: [const GroupEntry(id: 'spaces/OTHER')],
        requireMention: false,
      );
      final response = await _post(
        handler,
        body: _payload(spaceType: 'ROOM', spaceName: 'spaces/GRP'),
      );
      expect(response.statusCode, 200);
      expect(dispatchedMessage, isNull);
    });
  });

  group('Mention gating', () {
    test('requireMention: true — drops group message without mention', () async {
      final handler = buildHandler(groupAccess: GroupAccessMode.open, requireMention: true, botUser: 'users/bot');
      final response = await _post(
        handler,
        body: _payload(spaceType: 'ROOM', spaceName: 'spaces/GRP'),
      );
      expect(response.statusCode, 200);
      expect(dispatchedMessage, isNull);
    });

    test('requireMention: true — processes group message with bot mention', () async {
      final handler = buildHandler(groupAccess: GroupAccessMode.open, requireMention: true, botUser: 'users/bot');
      final response = await _post(
        handler,
        body: _payload(
          spaceType: 'ROOM',
          spaceName: 'spaces/GRP',
          annotations: [
            {
              'type': 'USER_MENTION',
              'userMention': {
                'user': {'name': 'users/bot'},
              },
            },
          ],
        ),
      );
      expect(response.statusCode, 200);
      expect(dispatchedMessage, isNotNull);
    });

    test('requireMention: false — processes group message without mention', () async {
      final handler = buildHandler(groupAccess: GroupAccessMode.open, requireMention: false, botUser: 'users/bot');
      final response = await _post(
        handler,
        body: _payload(spaceType: 'ROOM', spaceName: 'spaces/GRP'),
      );
      expect(response.statusCode, 200);
      expect(dispatchedMessage, isNotNull);
    });

    test('DM messages bypass mention gating', () async {
      final handler = buildHandler(dmMode: DmAccessMode.open, requireMention: true, botUser: 'users/bot');
      final response = await _post(handler, body: _payload(spaceType: 'DM'));
      expect(response.statusCode, 200);
      expect(dispatchedMessage, isNotNull);
    });
  });

  group('Session keying fields', () {
    test('DM message has senderJid=user.name and no groupJid', () async {
      final handler = buildHandler(dmMode: DmAccessMode.open);
      await _post(
        handler,
        body: _payload(spaceType: 'DM', userName: 'users/456'),
      );
      expect(dispatchedMessage, isNotNull);
      expect(dispatchedMessage!.senderJid, 'users/456');
      expect(dispatchedMessage!.groupJid, isNull);
    });

    test('ROOM message has senderJid=user.name and groupJid=space.name', () async {
      final handler = buildHandler(groupAccess: GroupAccessMode.open, requireMention: false);
      await _post(
        handler,
        body: _payload(spaceType: 'ROOM', spaceName: 'spaces/GRP', userName: 'users/789'),
      );
      expect(dispatchedMessage, isNotNull);
      expect(dispatchedMessage!.senderJid, 'users/789');
      expect(dispatchedMessage!.groupJid, 'spaces/GRP');
    });

    test('SPACE message has groupJid=space.name', () async {
      final handler = buildHandler(groupAccess: GroupAccessMode.open, requireMention: false);
      await _post(
        handler,
        body: _payload(spaceType: 'SPACE', spaceName: 'spaces/TEAM', userName: 'users/111'),
      );
      expect(dispatchedMessage, isNotNull);
      expect(dispatchedMessage!.senderJid, 'users/111');
      expect(dispatchedMessage!.groupJid, 'spaces/TEAM');
    });

    test('metadata includes spaceName', () async {
      final handler = buildHandler(dmMode: DmAccessMode.open);
      await _post(handler, body: _payload(spaceName: 'spaces/XYZ'));
      expect(dispatchedMessage!.metadata['spaceName'], 'spaces/XYZ');
    });
  });
}
