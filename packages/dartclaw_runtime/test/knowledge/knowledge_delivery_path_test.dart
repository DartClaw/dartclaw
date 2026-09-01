import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_runtime/dartclaw_runtime.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' show FakeTurnManager, SessionService, TurnOutcome, TurnStatus;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../delivery_test_support.dart';

/// The scheduled delivery path must carry per-file/per-page detail (quarantined
/// files with reasons, wiki-lint findings, wiki merges with what they removed,
/// and the measured coverage ratio) through the existing event/delivery pipeline
/// — not just a count-only summary. These tests assert the payload captured at
/// the `DeliveryService` boundary, so a regression that dropped per-item detail
/// during delivery would fail here even while `runOnce().summary` still carried
/// it.
void main() {
  late Directory workspace;
  late SessionService sessions;
  late FakeTurnManager turns;

  setUp(() {
    workspace = Directory.systemTemp.createTempSync('dartclaw_knowledge_delivery_test_');
    sessions = SessionService(baseDir: p.join(workspace.path, 'sessions'));
    turns = FakeTurnManager();
  });

  tearDown(() {
    if (workspace.existsSync()) workspace.deleteSync(recursive: true);
  });

  test('scheduled inbox run delivers the quarantined file name and error reason', () async {
    Directory(p.join(workspace.path, 'inbox')).createSync(recursive: true);
    File(p.join(workspace.path, 'inbox', 'bad.md')).writeAsStringSync('force-ingest-failure');
    final inbox = KnowledgeInboxService(
      workspaceDir: workspace.path,
      wiki: WikiPageStore(workspaceDir: workspace.path),
      turns: turns,
      sessions: sessions,
      maxBytes: 4096,
      retryAttempts: 1,
      stabilityWindow: const Duration(milliseconds: 20),
      now: () => DateTime.utc(2026, 5),
      failureHook: (text) {
        if (text.contains('force-ingest-failure')) throw StateError('forced ingestion failure');
      },
      onMemoryObserve: (args, context) async => const {},
    );
    final delivery = RecordingDeliveryService(sessions: sessions);
    final schedule = ScheduleService(turns: turns, sessions: sessions, jobs: [], delivery: delivery);
    schedule.start();
    addTearDown(schedule.stop);

    await schedule.executeJobForTesting(inbox.scheduledJob());

    final delivered = delivery.calls.single;
    expect(delivered.mode, DeliveryMode.announce);
    expect(delivered.result, contains('quarantined files: bad.md'));
    expect(delivered.result, contains('forced ingestion failure'));
  });

  test('scheduled wiki-lint run delivers the offending page name and finding category', () async {
    WikiPageStore(workspaceDir: workspace.path).bootstrap();
    File(p.join(workspace.path, 'wiki', 'broken.md')).writeAsStringSync('# Broken\n\n[Missing](missing.md)\n');
    final wiki = WikiPageStore(workspaceDir: workspace.path);
    final delivery = RecordingDeliveryService(sessions: sessions);
    final schedule = ScheduleService(turns: turns, sessions: sessions, jobs: [], delivery: delivery);
    schedule.start();
    addTearDown(schedule.stop);

    final lintJob = ScheduledJob(
      id: 'knowledge-wiki-lint',
      scheduleType: ScheduleType.interval,
      intervalMinutes: 60,
      deliveryMode: DeliveryMode.announce,
      onExecute: () async => (await lintWikiPages(wiki)).summary(),
    );
    await schedule.executeJobForTesting(lintJob);

    final delivered = delivery.calls.single;
    expect(delivered.result, contains('broken.md'));
    expect(delivered.result, contains('missing-link'));
  });

  // A merge onto a page the wiki already holds and the measured coverage ratio
  // are what the operator has to learn from the run's own output, and `announce`
  // is where they actually read it – not `runOnce().summary`.
  test('scheduled inbox run delivers the merged page and what the merge removed', () async {
    Directory(p.join(workspace.path, 'inbox')).createSync(recursive: true);
    File(p.join(workspace.path, 'inbox', 'first.md')).writeAsStringSync('First batch source.');
    final delivery = RecordingDeliveryService(sessions: sessions);
    final schedule = ScheduleService(turns: turns, sessions: sessions, jobs: [], delivery: delivery);
    schedule.start();
    addTearDown(schedule.stop);

    await _inbox(
      workspace,
      sessions,
      extractions: [_payload(body: 'First synthesis body.')],
    ).runOnce(requireStable: false);
    File(p.join(workspace.path, 'inbox', 'second.md')).writeAsStringSync('Follow-up batch source.');
    await schedule.executeJobForTesting(
      _inbox(
        workspace,
        sessions,
        extractions: [_payload(body: 'Follow-up synthesis body.')],
        merges: [
          _mergePayload(body: 'First synthesis body. Follow-up synthesis body.', removed: ['a stale caveat']),
        ],
      ).scheduledJob(),
    );

    final delivered = delivery.calls.single;
    expect(delivered.mode, DeliveryMode.announce);
    expect(
      delivered.result,
      contains('wiki merges: second.md -> wiki/dart-roadmap.md (integrated, removed: a stale caveat)'),
    );
    expect(delivered.result, contains('coverage: second.md '));
  });
}

/// An inbox whose extraction and merge turns answer from separate scripts, so a
/// merge reply can never be mistaken for an extraction reply.
KnowledgeInboxService _inbox(
  Directory workspace,
  SessionService sessions, {
  required List<String> extractions,
  List<String> merges = const [],
}) {
  var extraction = 0;
  var merge = 0;
  late final FakeTurnManager manager;
  manager = FakeTurnManager(
    onWaitForOutcome: (sessionId, turnId) async {
      final prompt = manager.startedTurns.last.messages.single['content'] as String;
      final isMerge = prompt.startsWith('Merge new synthesized knowledge');
      return TurnOutcome(
        turnId: turnId,
        sessionId: sessionId,
        status: TurnStatus.completed,
        responseText: isMerge ? merges[merge++ % merges.length] : extractions[extraction++ % extractions.length],
        completedAt: DateTime.utc(2026, 5),
      );
    },
  );
  return KnowledgeInboxService(
    workspaceDir: workspace.path,
    wiki: WikiPageStore(workspaceDir: workspace.path),
    turns: manager,
    sessions: sessions,
    maxBytes: 4096,
    retryAttempts: 1,
    stabilityWindow: const Duration(milliseconds: 20),
    now: () => DateTime.utc(2026, 5),
    onMemoryObserve: (args, context) async => const {},
  );
}

String _payload({required String body}) =>
    '''
<workflow-context>{
  "memory_findings": [{"text": "Synthesized durable finding."}],
  "wiki_page": {"slug": "dart-roadmap", "title": "Dart Roadmap", "body": "$body", "confidence": "medium"},
  "facts": []
}</workflow-context>
''';

String _mergePayload({required String body, List<String> removed = const []}) =>
    '''
<workflow-context>{
  "merge": "integrated",
  "integrated_from": "dart-roadmap",
  "removed_content": ${jsonEncode(removed)},
  "body": ${jsonEncode(body)}
}</workflow-context>
''';
