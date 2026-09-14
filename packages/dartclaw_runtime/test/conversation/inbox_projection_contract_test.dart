import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/src/conversation/inbox_service.dart';
import 'package:test/test.dart';

import 'inbox_test_fixture.dart';

void main() {
  test('bounded projections keep complete totals and stable cursors before clipping', () async {
    final fixture = await InboxTestFixture.create(count: 200);
    addTearDown(fixture.dispose);
    final draftId = fixture.sessionIds[50];
    final sourceId = fixture.sessionIds[0];
    final destinationId = fixture.sessionIds[1];
    final sourceState = (await fixture.sessions.getConversationState(sourceId)).putBranch(
      ConversationBranchLink(
        mutationId: 'fixture-lineage',
        kind: ConversationBranchKind.fork,
        sourceSessionId: sourceId,
        sourceMessageId: 'source-message',
        destinationSessionId: destinationId,
        destinationMessageId: 'destination-message',
        createdAt: InboxTestFixture.now,
      ),
    );
    await fixture.sessions.updateConversationState(sourceId, sourceState);

    final first = await fixture.inbox.inbox(limit: 25, localDraftSessionIds: {draftId});
    expect(first.total, 200);
    expect(first.entries, hasLength(25));
    expect(first.nextCursor, isNotNull);
    final second = await fixture.inbox.inbox(limit: 25, cursor: first.nextCursor);
    expect(second.entries.map((entry) => entry.session.id), isNot(contains(first.entries.last.session.id)));
    final drafts = await fixture.inbox.inbox(limit: 25, filter: InboxFilter.drafts, localDraftSessionIds: {draftId});
    expect(drafts.filteredTotal, 1);
    expect(drafts.entries.single.session.id, draftId);
    final all = await fixture.inbox.inbox(limit: 200);
    expect(all.entries.singleWhere((entry) => entry.session.id == destinationId).parentSessionId, sourceId);

    const scopedId = '00000000-0000-4000-9000-000000000001';
    await fixture.sessions.createSessionWithIdentity(
      id: scopedId,
      workspace: AgentWorkspace.pinned(agentId: 'agent-fixture', directory: '/workspace/fixture'),
    );
    final scoped = await fixture.inbox.inbox(principal: 'agent:agent-fixture', limit: 25);
    expect(scoped.entries.map((entry) => entry.session.id), [scopedId]);
  });

  test('active and settled keyset cursors survive boundary moves, ties and newer insertions', () async {
    final activeFixture = await InboxTestFixture.create(count: 8);
    addTearDown(activeFixture.dispose);
    final tiedAt = DateTime.utc(2026, 9, 1);
    for (final id in activeFixture.sessionIds) {
      await _setCreatedAt(activeFixture, id, tiedAt);
    }
    final activeFirst = await activeFixture.inbox.inbox(limit: 3);
    expect(activeFirst.entries.map((entry) => entry.session.id), activeFixture.sessionIds.take(3));
    final activeBoundary = activeFirst.entries.last.session.id;
    await activeFixture.sessions.updateSessionType(activeBoundary, SessionType.archive);
    await activeFixture.sessions.createSessionWithIdentity(
      id: '00000000-0000-4000-8000-000000000999',
      provider: 'fixture',
    );
    final activeSecond = await activeFixture.inbox.inbox(limit: 3, cursor: activeFirst.nextCursor);
    expect(activeSecond.entries.map((entry) => entry.session.id), activeFixture.sessionIds.skip(3).take(3));
    await expectLater(
      activeFixture.inbox.inbox(limit: 3, cursor: 'not-an-opaque-cursor'),
      throwsA(isA<InboxMutationException>().having((error) => error.code, 'code', 'INVALID_INBOX_CURSOR')),
    );

    final settledFixture = await InboxTestFixture.create(count: 6);
    addTearDown(settledFixture.dispose);
    for (final id in settledFixture.sessionIds) {
      final revision = await settledFixture.makeEligible(id);
      expect(
        (await settledFixture.inbox.settleMany([(sessionId: id, expectedRevision: revision)])).single.accepted,
        isTrue,
      );
    }
    final settledFirst = await settledFixture.inbox.inbox(settled: true, limit: 2);
    final settledBoundary = settledFirst.entries.last;
    expect((await settledFixture.inbox.restore(settledBoundary.session.id, settledBoundary.revision)).accepted, isTrue);
    final settledSecond = await settledFixture.inbox.inbox(settled: true, limit: 2, cursor: settledFirst.nextCursor);
    expect(settledSecond.entries.map((entry) => entry.session.id), settledFixture.sessionIds.skip(2).take(2));
  });
}

Future<void> _setCreatedAt(InboxTestFixture fixture, String id, DateTime value) async {
  final file = File('${fixture.root.path}/$id/meta.json');
  final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
  json['createdAt'] = value.toIso8601String();
  await file.writeAsString(jsonEncode(json));
}
