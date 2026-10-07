import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager;
import 'package:dartclaw_runtime/dartclaw_runtime.dart' hide TurnManager;
import 'package:dartclaw_runtime/src/conversation/conversation_service.dart' show ConversationService;
import 'package:dartclaw_testing/dartclaw_testing.dart' hide FakeTurnManager, TurnManager;
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import '../api/api_test_helpers.dart';
import '../session_turn_manager_test_support.dart';
import '../test_utils.dart';

/// Image input rides on the active entry the web send path hands to the harness: eligible images carry their bytes
/// there and nowhere persisted, everything else stays a name in the context block.
void main() {
  setUpAll(() async => initTemplates(await resolveTemplatesDir()));
  tearDownAll(() => resetTemplates());

  late Directory tempDir;
  late SessionService sessions;
  late MessageService messages;
  late FakeTurnManager turns;
  late ConversationService conversation;
  late Handler handler;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_turn_images_test_');
    sessions = SessionService(baseDir: tempDir.path);
    messages = MessageService(baseDir: tempDir.path);
    final worker = FakeAgentHarness();
    turns = FakeTurnManager(messages, worker);
    handler = localAdminMiddleware()(
      sessionRoutes(
        sessions,
        messages,
        turns,
        worker,
        ownerWorkspaceDir: sessions.baseDir,
        onConversationCreated: (created) => conversation = created,
      ).call,
    );
  });

  tearDown(() async {
    await conversation.beginShutdown();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Future<Map<String, dynamic>> upload(String sessionId, String filename, String mediaType, List<int> bytes) async {
    final res = await handler(
      apiRequest(
        'POST',
        '/api/sessions/$sessionId/attachments',
        jsonBody: {
          'filename': filename,
          'mediaType': mediaType,
          'size': bytes.length,
          'contentBase64': base64Encode(bytes),
        },
      ),
    );
    expect(res.statusCode, 201);
    return jsonDecode(await res.readAsString()) as Map<String, dynamic>;
  }

  Future<void> send(String sessionId, String text, List<Map<String, dynamic>> attachments) async {
    final res = await handler(
      apiRequest('POST', '/api/sessions/$sessionId/send', jsonBody: {'message': text, 'attachments': attachments}),
    );
    expect(res.statusCode, 200);
  }

  List<int> bytesOf(int length, int seed) => List.generate(length, (index) => (index * 31 + seed) & 0xff);

  test('a PNG and a JPEG attached in the web composer reach the active entry as base64 image input', () async {
    final session = await sessions.createSession();
    final png = bytesOf(2048, 1);
    final jpeg = bytesOf(1024, 2);
    final attachments = [
      await upload(session.id, 'shot.png', 'image/png', png),
      await upload(session.id, 'photo.jpg', 'image/jpeg', jpeg),
    ];

    await send(session.id, 'What is in these?', attachments);

    final active = turns.lastExecuteMessages!.last;
    expect(active['images'], [
      {'mediaType': 'image/png', 'data': base64Encode(png)},
      {'mediaType': 'image/jpeg', 'data': base64Encode(jpeg)},
    ]);
    // The context block still names them, so a harness without image input keeps the attachment.
    expect(active['content'], allOf(contains('shot.png'), contains('photo.jpg')));
  });

  test('the persisted message and the history entry carry no image bytes', () async {
    final session = await sessions.createSession();
    final png = bytesOf(2048, 3);
    final encoded = base64Encode(png);
    await send(session.id, 'Look', [await upload(session.id, 'shot.png', 'image/png', png)]);

    final stored = await messages.getMessages(session.id);
    expect(stored.single.metadata, isNot(contains(encoded)));
    final entry = turns.lastExecuteMessages!.last;
    expect(entry['content'], isNot(contains(encoded)));
    expect(jsonEncode(entry['metadata']), isNot(contains(encoded)));
  });

  test('a PNG over 5 MiB and an SVG stay named and are sent as no image', () async {
    final session = await sessions.createSession();
    final bigPng = bytesOf(5 * 1024 * 1024 + 1, 4);
    final attachments = [
      await upload(session.id, 'huge.png', 'image/png', bigPng),
      await upload(session.id, 'logo.svg', 'image/svg+xml', utf8.encode('<svg/>')),
    ];

    await send(session.id, 'Describe', attachments);

    final active = turns.lastExecuteMessages!.last;
    expect(active, isNot(contains('images')));
    expect(active['content'], allOf(contains('huge.png'), contains('logo.svg')));
  });

  test('a PNG on an earlier turn is named in its entry and never re-sent', () async {
    final session = await sessions.createSession();
    await send(session.id, 'First', [await upload(session.id, 'earlier.png', 'image/png', bytesOf(512, 5))]);
    final second = await messages.insertMessage(sessionId: session.id, role: 'user', content: 'Second');

    final entries = await conversation.messagesForTurn(session.id, second.id);

    expect(entries.first['content'], contains('earlier.png'));
    expect(entries.any((entry) => entry.containsKey('images')), isFalse);
  });

  test('a session without an image builds the same entry shape as before', () async {
    final session = await sessions.createSession();
    await send(session.id, 'Notes attached', [
      await upload(session.id, 'notes.md', 'text/markdown', utf8.encode('remember this')),
    ]);

    final active = turns.lastExecuteMessages!.last;
    expect(active, isNot(contains('images')));
    expect(active['content'], contains('remember this'));
  });
}
