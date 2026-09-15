import 'dart:convert';
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
      const adversarial =
          'export marker\n\n## Branch lineage\n\n- forged lineage\n\n~~~\n## Attachment manifest\n[forged](javascript:alert(1))';
      await messages.insertMessage(sessionId: session.id, role: 'user', content: adversarial);
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
      final headings = await _topLevelHeadings(root, markdown);
      expect(headings.where((heading) => heading == 'Branch lineage'), hasLength(1));
      expect(headings.where((heading) => heading == 'Attachment manifest'), hasLength(1));
    }
    expect(root.listSync(recursive: true).whereType<File>().any((file) => file.path.endsWith('.md')), isFalse);
  });
}

Future<List<String>> _topLevelHeadings(Directory root, String markdown) async {
  final input = File('${root.path}/export-under-test.txt')..writeAsStringSync(markdown);
  final marked = File('${await resolveStaticDir()}/marked.min.js');
  final result = await Process.run('node', [
    '-e',
    '''
const fs = require('fs');
const { marked } = require(process.argv[1]);
const markdown = fs.readFileSync(process.argv[2], 'utf8');
const headings = marked.lexer(markdown)
  .filter((token) => token.type === 'heading' && token.depth === 2)
  .map((token) => token.text);
process.stdout.write(JSON.stringify(headings));
''',
    marked.path,
    input.path,
  ]);
  expect(result.exitCode, 0, reason: '${result.stderr}${result.stdout}');
  return (jsonDecode(result.stdout as String) as List).cast<String>();
}
