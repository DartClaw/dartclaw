import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager;
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart' hide TurnManager;
import 'package:dartclaw_testing/dartclaw_testing.dart' hide FakeTurnManager, TurnManager;
import 'package:test/test.dart';
import 'package:dartclaw_runtime/src/api/session_attachment_routes.dart';

import '../test_utils.dart';
import '../session_turn_manager_test_support.dart';
import 'api_test_helpers.dart';

void main() {
  setUpAll(() async => initTemplates(await resolveTemplatesDir()));
  tearDownAll(resetTemplates);

  test('unsupported and no-match retention requests fail without durable or provider side effects', () async {
    final root = Directory.systemTemp.createTempSync('temporary-routes-');
    addTearDown(() => root.deleteSync(recursive: true));
    final sessions = SessionService(baseDir: root.path);
    final messages = MessageService(baseDir: root.path, retentionForSession: sessions.retentionFor);
    final worker = FakeAgentHarness();
    final turns = FakeTurnManager(messages, worker);
    final unavailable = ApiRouteTestClient(
      localAdminMiddleware()(sessionRoutes(sessions, messages, turns, worker).call),
    );
    expect(
      await unavailable.expectJsonErrorCode(
        'POST',
        '/api/sessions',
        json: {'retention': 'process', 'disclosureAccepted': true},
        status: 409,
      ),
      'TEMPORARY_UNAVAILABLE',
    );
    expect(await sessions.listSessions(), isEmpty);

    final processAttachments = ProcessAttachmentOwner();
    final supportedHandler = localAdminMiddleware()(
      sessionRoutes(
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
        processAttachmentOwner: processAttachments,
      ).call,
    );
    final supported = ApiRouteTestClient(supportedHandler);
    final created = await supported.expectResponse(
      'POST',
      '/api/sessions',
      json: {'retention': 'process', 'disclosureAccepted': true},
      status: 201,
    );
    final id = (jsonDecode(await created.readAsString()) as Map<String, dynamic>)['id'] as String;
    final attachment = await uploadSessionAttachment(supportedHandler, id, content: 'temporary attachment');
    expect(processAttachments.contains(id, attachment['id'] as String), isTrue);
    await supported.expectResponse('POST', '/api/sessions/$id/end-temporary', status: 204);
    expect(processAttachments.contains(id, attachment['id'] as String), isFalse);
    await expectLater(messages.insertMessage(sessionId: id, role: 'user', content: 'forged'), throwsStateError);
    expect(Directory('${root.path}/$id').existsSync(), isFalse);
  });
}
