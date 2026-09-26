import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager;
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart' hide TurnManager;
import 'package:dartclaw_testing/dartclaw_testing.dart' show FakeAgentHarness, FakeProjectService;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../session_turn_manager_test_support.dart';
import 'api_test_helpers.dart';

void main() {
  late Directory root;
  late Directory owner;
  late Directory first;
  late SessionService sessions;
  late MessageService messages;
  late FakeTurnManager turns;
  late ApiRouteTestClient api;

  setUp(() {
    root = Directory.systemTemp.createTempSync('general_project_creation_');
    owner = Directory(p.join(root.path, 'owner'))..createSync();
    first = Directory(p.join(root.path, 'first'))..createSync();
    final second = Directory(p.join(root.path, 'second'))..createSync();
    sessions = SessionService(baseDir: root.path);
    messages = MessageService(baseDir: root.path);
    final worker = FakeAgentHarness();
    turns = FakeTurnManager(messages, worker);
    Project project(String id, Directory directory) => Project(
      id: id,
      name: id,
      remoteUrl: '',
      localPath: directory.path,
      defaultBranch: 'main',
      status: ProjectStatus.ready,
      createdAt: DateTime.utc(2026),
    );
    final projects = FakeProjectService(
      localProject: project('_local', root),
      projects: [project('first', first), project('second', second)],
      defaultProjectId: 'first',
    );
    api = ApiRouteTestClient(
      localAdminMiddleware()(
        sessionRoutes(sessions, messages, turns, worker, projectService: projects, ownerWorkspaceDir: owner.path).call,
      ),
    );
  });

  tearDown(() => root.deleteSync(recursive: true));

  test('reuses the newest blank default chat across sequential requests', () async {
    final first = await api.expectJsonObject('POST', '/api/sessions/open', status: 201);
    final second = await api.expectJsonObject('POST', '/api/sessions/open');

    expect(second['id'], first['id']);
    expect(await sessions.listSessions(type: SessionType.user), hasLength(1));
  });

  test('coalesces concurrent requests into one blank chat', () async {
    final responses = await Future.wait(List.generate(4, (_) => api.request('POST', '/api/sessions/open')));
    final ids = <String>{};
    for (final response in responses) {
      expect(response.statusCode, anyOf(200, 201));
      ids.add((jsonDecode(await response.readAsString()) as Map<String, dynamic>)['id'] as String);
    }

    expect(ids, hasLength(1));
    expect(await sessions.listSessions(type: SessionType.user), hasLength(1));
  });

  test('reuses the newest duplicate blank without deleting older drafts', () async {
    final older = await sessions.createSession();
    await Future<void>.delayed(const Duration(milliseconds: 1));
    final newer = await sessions.createSession();

    final opened = await api.expectJsonObject('POST', '/api/sessions/open');

    expect(opened['id'], newer.id);
    expect(opened['id'], isNot(older.id));
    expect(await sessions.listSessions(type: SessionType.user), hasLength(2));
  });

  test('does not reuse an empty chat with an active turn', () async {
    final active = await sessions.createSession();
    await turns.reserveTurn(active.id);

    final opened = await api.expectJsonObject('POST', '/api/sessions/open', status: 201);

    expect(opened['id'], isNot(active.id));
    expect(await sessions.listSessions(type: SessionType.user), hasLength(2));
  });

  test('does not reuse an untitled chat that already has messages', () async {
    final existing = await sessions.createSession();
    await messages.insertMessage(sessionId: existing.id, role: 'user', content: 'Hello');

    final opened = await api.expectJsonObject('POST', '/api/sessions/open', status: 201);

    expect(opened['id'], isNot(existing.id));
    expect(await sessions.listSessions(type: SessionType.user), hasLength(2));
  });

  test('does not reuse titled, keyed, or provider-specific empty chats', () async {
    final titled = await sessions.createSession();
    await sessions.updateTitle(titled.id, 'Saved draft');
    await sessions.createSession(type: SessionType.user, channelKey: 'custom:key');
    await sessions.createSession(provider: 'codex');

    final opened = await api.expectJsonObject('POST', '/api/sessions/open', status: 201);

    expect(opened['id'], isNot(titled.id));
    expect(await sessions.listSessions(type: SessionType.user), hasLength(4));
  });

  test('GET /references bounds file suggestions and preserves current project suggestion', () async {
    final session = await sessions.createSession();
    await sessions.updateTitle(session.id, 'Release planning');
    for (var i = 0; i < 25; i++) {
      File(p.join(first.path, 'release_file_${i.toString().padLeft(2, '0')}.md')).writeAsStringSync('release');
    }
    final state = await sessions.getConversationState(session.id);
    await sessions.updateConversationState(
      session.id,
      state.stageContext(
        EffectiveConversationContext(
          projectId: 'first',
          directory: first.path,
          referenceRoot: first.path,
          provider: 'claude',
        ),
      ),
    );

    final response = await api.request('GET', '/api/sessions/${session.id}/references');
    expect(response.statusCode, 200);
    final body = jsonDecode(await response.readAsString()) as Map<String, dynamic>;
    final refs = (body['references'] as List<dynamic>).cast<Map<String, dynamic>>();
    expect(refs.where((ref) => ref['type'] == 'file'), hasLength(10));
    expect(
      refs,
      contains(
        predicate(
          (ref) => ref is Map<String, dynamic> && ref['type'] == 'session' && ref['label'] == 'Release planning',
        ),
      ),
    );
    expect(
      refs,
      contains(predicate((ref) => ref is Map<String, dynamic> && ref['type'] == 'project' && ref['label'] == 'first')),
    );
  });

  test('global chat stays general while named projects reuse only their own drafts', () async {
    final general = await api.expectJsonObject('POST', '/api/sessions/open', status: 201);
    final first = await api.expectJsonObject('POST', '/api/sessions/open', json: {'project_id': 'first'}, status: 201);
    final second = await api.expectJsonObject(
      'POST',
      '/api/sessions/open',
      json: {'project_id': 'second'},
      status: 201,
    );
    expect({general['id'], first['id'], second['id']}, hasLength(3));

    final again = await api.expectJsonObject('POST', '/api/sessions/open');
    final firstAgain = await api.expectJsonObject('POST', '/api/sessions/open', json: {'project_id': 'first'});
    expect(again['id'], general['id']);
    expect(firstAgain['id'], first['id']);
    expect((await sessions.getConversationState(general['id'] as String)).nextContext?.projectId, isNull);
    expect((await sessions.getConversationState(first['id'] as String)).nextContext?.projectId, 'first');
    expect((await sessions.getConversationState(second['id'] as String)).nextContext?.projectId, 'second');
  });

  test('global General chat never reuses a named-agent draft', () async {
    final namedAgent = await sessions.createSession(
      workspace: AgentWorkspace.pinned(agentId: 'fixture-agent', directory: owner.path),
    );
    final opened = await api.expectJsonObject('POST', '/api/sessions/open', json: {'project_id': null}, status: 201);
    expect(opened['id'], isNot(namedAgent.id));
    expect((await sessions.getSession(opened['id'] as String))?.workspace, isNull);
    expect((await sessions.getConversationState(opened['id'] as String)).nextContext?.projectId, isNull);
  });

  test('invalid destinations leave existing drafts and their contexts intact', () async {
    final general = await api.expectJsonObject('POST', '/api/sessions/open', status: 201);
    for (final projectId in ['_local', 'missing']) {
      final code = await api.expectJsonErrorCode(
        'POST',
        '/api/sessions/open',
        json: {'project_id': projectId},
        status: 403,
      );
      expect(code, 'PROJECT_FORBIDDEN');
    }
    expect(await sessions.listSessions(type: SessionType.user), hasLength(1));
    expect((await sessions.getConversationState(general['id'] as String)).nextContext?.projectId, isNull);
  });

  test('context PATCH distinguishes explicit null from omission', () async {
    final first = await api.expectJsonObject('POST', '/api/sessions/open', json: {'project_id': 'first'}, status: 201);
    final id = first['id'] as String;
    final before = await api.expectJsonObject('GET', '/api/sessions/$id/conversation-state');
    final revision = before['revision'] as int;
    expect(
      await api.expectJsonErrorCode(
        'PATCH',
        '/api/sessions/$id/context',
        json: {'conversation_revision': revision, 'directory': owner.path, 'provider': 'claude'},
        status: 400,
      ),
      'INVALID_INPUT',
    );
    final moved = await api.expectJsonObject(
      'PATCH',
      '/api/sessions/$id/context',
      json: {'conversation_revision': revision, 'project_id': null, 'directory': owner.path, 'provider': 'claude'},
    );
    expect((moved['next_context'] as Map)['projectId'], isNull);
    expect((moved['effective_context'] as Map)['projectId'], isNull);
    expect((moved['records'] as List).single['kind'], 'contextChange');
  });
}
