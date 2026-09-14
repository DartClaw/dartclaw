import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager;
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart' hide TurnManager;
import 'package:dartclaw_testing/dartclaw_testing.dart' hide FakeTurnManager, TurnManager;
import 'package:test/test.dart';

import '../test_utils.dart';
import '../session_turn_manager_test_support.dart';
import 'api_test_helpers.dart';

void main() {
  setUpAll(() async => initTemplates(await resolveTemplatesDir()));
  tearDownAll(resetTemplates);

  test('ordinary and temporary exports require authorization and stream Markdown without spill files', () async {
    final root = Directory.systemTemp.createTempSync('conversation-export-');
    addTearDown(() => root.deleteSync(recursive: true));
    final sessions = SessionService(baseDir: root.path);
    final messages = MessageService(baseDir: root.path, retentionForSession: sessions.retentionFor);
    final worker = FakeAgentHarness();
    final turns = FakeTurnManager(messages, worker);
    final raw = sessionRoutes(
      sessions,
      messages,
      turns,
      worker,
      defaultProvider: 'codex',
      temporaryConversationCapability: const TemporaryConversationCapability(
        providerId: 'codex',
        policy: ExecutionPolicy.container('workspace'),
        available: true,
        reason: '',
      ),
    ).call;
    final admin = ApiRouteTestClient(localAdminMiddleware()(raw));
    final denied = ApiRouteTestClient(raw);
    for (final session in [
      await sessions.createSession(),
      await sessions.createSession(retention: ConversationRetention.process),
    ]) {
      await messages.insertMessage(sessionId: session.id, role: 'user', content: 'export marker');
      await denied.expectResponse('GET', '/api/sessions/${session.id}/export', status: 403);
      final response = await admin.expectResponse(
        'POST',
        '/api/sessions/${session.id}/export',
        json: {'confirmed': true, 'durableCopyAccepted': true},
        status: 200,
      );
      expect(response.headers['content-disposition'], contains(session.id));
      final markdown = await response.readAsString();
      expect(markdown, contains('export marker'));
      expect(markdown, contains('Attachment bytes are not included'));
    }
    expect(root.listSync(recursive: true).whereType<File>().any((file) => file.path.endsWith('.md')), isFalse);
  });
}
