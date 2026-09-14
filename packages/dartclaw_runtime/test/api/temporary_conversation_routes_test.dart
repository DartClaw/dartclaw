import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager;
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart' hide TurnManager;
import 'package:dartclaw_testing/dartclaw_testing.dart' hide FakeTurnManager, TurnManager;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:dartclaw_runtime/src/api/session_attachment_routes.dart';

import '../test_utils.dart';
import '../session_turn_manager_test_support.dart';
import 'api_test_helpers.dart';

const _temporaryCapability = TemporaryConversationCapability(
  providerId: 'codex',
  policy: ExecutionPolicy.container('workspace'),
  available: true,
  reason: '',
);

void main() {
  setUpAll(() async => initTemplates(await resolveTemplatesDir()));
  tearDownAll(resetTemplates);

  group('temporary conversations', () {
    late Directory root;
    late SessionService sessions;
    late MessageService messages;
    late FakeAgentHarness worker;

    setUp(() {
      root = Directory.systemTemp.createTempSync('temporary-routes-');
      sessions = SessionService(baseDir: root.path);
      messages = MessageService(baseDir: root.path, retentionForSession: sessions.retentionFor);
      worker = FakeAgentHarness();
    });

    tearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    test('requires disclosure and pins the mediated Codex container row', () async {
      final turns = FakeTurnManager(messages, worker);
      final api = ApiRouteTestClient(
        localAdminMiddleware()(
          sessionRoutes(
            sessions,
            messages,
            turns,
            worker,
            defaultProvider: 'codex',
            temporaryConversationCapability: _temporaryCapability,
          ).call,
        ),
      );
      expect(
        await api.expectJsonErrorCode('POST', '/api/sessions', json: {'retention': 'process'}, status: 400),
        'DISCLOSURE_REQUIRED',
      );
      final response = await api.expectResponse(
        'POST',
        '/api/sessions',
        json: {'retention': 'process', 'disclosureAccepted': true},
        status: 201,
      );
      expect(response.headers['cache-control'], 'no-store');
      final created = jsonDecode(await response.readAsString()) as Map<String, dynamic>;
      expect(created, containsPair('retention', 'process'));
      expect(created, containsPair('provider', 'codex'));
      expect(created, containsPair('executionMode', 'container'));
      expect(created, containsPair('securityProfile', 'workspace'));
      expect(Directory(p.join(root.path, created['id'] as String)).existsSync(), isFalse);
    });

    test('exports visible Markdown then irreversibly ends the process conversation', () async {
      final turns = FakeTurnManager(messages, worker);
      final handler = localAdminMiddleware()(
        sessionRoutes(
          sessions,
          messages,
          turns,
          worker,
          defaultProvider: 'codex',
          temporaryConversationCapability: _temporaryCapability,
        ).call,
      );
      final api = ApiRouteTestClient(handler);
      final created = await api.expectJsonObject(
        'POST',
        '/api/sessions',
        json: {'retention': 'process', 'disclosureAccepted': true},
        status: 201,
      );
      final id = created['id'] as String;
      await messages.insertMessage(sessionId: id, role: 'user', content: 'private prompt');
      final disclosure = await api.expectJsonObject('GET', '/api/sessions/$id/export');
      expect(disclosure['confirmation_required'], isTrue);
      final export = await api.expectResponse(
        'POST',
        '/api/sessions/$id/export',
        json: {'confirmed': true, 'durableCopyAccepted': true},
        status: 200,
      );
      expect(export.headers['content-type'], contains('text/markdown'));
      expect(await export.readAsString(), contains('private prompt'));
      await api.expectResponse('POST', '/api/sessions/$id/end-temporary', status: 204);
      await api.expectResponse('GET', '/api/sessions/$id', status: 404);
      await api.expectResponse('POST', '/api/sessions/$id/end-temporary', status: 404);
    });
  });

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
