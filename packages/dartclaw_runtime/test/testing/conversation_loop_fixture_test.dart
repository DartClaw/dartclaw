import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:test/test.dart';

import '../integration/_fixtures/conversation_loop_browser_process.dart' show seedSearchCommandFixture;

void main() {
  test('search and command states are deterministic', () async {
    final root = Directory.systemTemp.createTempSync('conversation_loop_search_fixture_');
    final sessions = SessionService(baseDir: root.path);
    final messages = MessageService(baseDir: root.path);
    addTearDown(() async {
      await messages.dispose();
      root.deleteSync(recursive: true);
    });
    final agentA = await sessions.createSession(
      provider: 'claude',
      workspace: AgentWorkspace.pinned(agentId: 'fixture-agent', directory: '${root.path}/agent-a'),
    );

    final fixture = await seedSearchCommandFixture(
      sessions,
      messages,
      agentA,
      root.path,
      agentBWorkspace: AgentWorkspace.pinned(agentId: 'fixture-agent-b', directory: '${root.path}/agent-b'),
      searchOwnerWorkspace: AgentWorkspace.pinned(
        agentId: 'fixture-search-owner',
        directory: '${root.path}/search-owner',
      ),
    );

    expect((await messages.getMessages(agentA.id)).single.content, 's07-agent-a-marker s07-scope-marker');
    expect((await messages.getMessages(fixture.agentBSessionId)).single.content, 's07-agent-b-marker');
    final ownerMessages = await messages.getMessages(fixture.ownerSessionId);
    expect(ownerMessages, hasLength(280));
    expect(
      ownerMessages.firstWhere((message) => message.id == fixture.exactMessageId).content,
      'unsafe <img src=x onerror=globalThis.__s07Injected=true> s07-exact-unloaded-marker result 7',
    );
    expect((await sessions.getSession(fixture.settledSessionId))!.settledAt, DateTime.utc(2026, 9, 14));
    expect((await sessions.getSession(fixture.archivedSessionId))!.type, SessionType.archive);
    expect((await sessions.getSession(agentA.id))!.workspace!.storagePrincipal, 'agent:fixture-agent');
    expect((await sessions.getSession(fixture.agentBSessionId))!.workspace!.storagePrincipal, 'agent:fixture-agent-b');
  });
}
