import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager;
import 'package:dartclaw_runtime/dartclaw_runtime.dart' hide TurnManager;
import 'package:dartclaw_runtime/src/conversation/human_command_catalog.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' hide FakeTurnManager, TurnManager;
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import '../session_turn_manager_test_support.dart';
import '../test_utils.dart';

void main() {
  setUpAll(() async => initTemplates(await resolveTemplatesDir()));
  tearDownAll(resetTemplates);

  test('unknown slash text stays byte-identical on the ordinary send route', () async {
    final root = Directory.systemTemp.createTempSync('command_passthrough_');
    final sessions = SessionService(baseDir: root.path);
    final messages = MessageService(baseDir: root.path);
    final worker = FakeAgentHarness();
    final turns = FakeTurnManager(messages, worker);
    final handler = localAdminMiddleware()(
      sessionRoutes(sessions, messages, turns, worker, ownerWorkspaceDir: sessions.baseDir).call,
    );
    addTearDown(() async {
      await messages.dispose();
      root.deleteSync(recursive: true);
    });
    final session = await sessions.createSession();
    const input = '/unowned  keep\tbytes + symbols=%25';

    final response = await handler(
      Request(
        'POST',
        Uri.parse('http://localhost/api/sessions/${session.id}/send'),
        body: 'message=%2Funowned++keep%09bytes+%2B+symbols%3D%2525',
        headers: {'content-type': 'application/x-www-form-urlencoded'},
      ),
    );

    expect(response.statusCode, 200);
    expect((await messages.getMessages(session.id)).single.content, input);
    expect(turns.lastExecuteMessages!.last['content'], input);
    final catalog = HumanCommandCatalog(harnessFactory: HarnessFactory());
    expect(catalog.unknownSlashDisposition(input), 'Send to provider');
  });
}
