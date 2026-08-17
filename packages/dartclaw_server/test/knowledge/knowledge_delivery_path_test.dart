import 'dart:io';

import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' show FakeTurnManager, SessionService, TurnOutcome, TurnStatus;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../delivery_test_support.dart';

/// TI11: the scheduled delivery path must carry per-file/per-page detail
/// (quarantined files with reasons, wiki-lint findings, wiki collisions, and
/// what the extraction left out) through the existing
/// event/delivery pipeline — not just a count-only summary. These tests assert
/// the payload captured at the `DeliveryService` boundary, so a regression that
/// dropped per-item detail during delivery would fail here even while
/// `runOnce().summary` still carried it.
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

  // A collision and a lossy synthesis are the two things the operator has to
  // learn from the run's own output, and `announce` is where they actually read
  // it – not `runOnce().summary`.
  test('scheduled inbox run delivers the collided page and what the extraction left out', () async {
    Directory(p.join(workspace.path, 'inbox')).createSync(recursive: true);
    File(p.join(workspace.path, 'inbox', 'first.md')).writeAsStringSync('First batch source.');
    final delivery = RecordingDeliveryService(sessions: sessions);
    final schedule = ScheduleService(turns: turns, sessions: sessions, jobs: [], delivery: delivery);
    schedule.start();
    addTearDown(schedule.stop);

    await _inbox(workspace, sessions, _payload(body: 'First synthesis body.')).runOnce(requireStable: false);
    File(p.join(workspace.path, 'inbox', 'second.md')).writeAsStringSync('Supplement batch source.');
    await schedule.executeJobForTesting(
      _inbox(
        workspace,
        sessions,
        _payload(body: 'Follow-up synthesis body.', droppedTopics: const ['quote list']),
      ).scheduledJob(),
    );

    final delivered = delivery.calls.single;
    expect(delivered.mode, DeliveryMode.announce);
    expect(delivered.result, contains('wiki merges: second.md -> wiki/dart-roadmap.md (supplement 1)'));
    expect(delivered.result, contains('declared drops: second.md: quote list'));
    expect(delivered.result, contains('coverage: second.md '));
  });
}

KnowledgeInboxService _inbox(Directory workspace, SessionService sessions, String response) => KnowledgeInboxService(
  workspaceDir: workspace.path,
  wiki: WikiPageStore(workspaceDir: workspace.path),
  turns: FakeTurnManager(
    onStartTurn: (
      sessionId,
      messages, {
      source,
      agentName = 'main',
      model,
      effort,
      systemPromptOverride,
      maxTurns,
      taskId,
      isHumanInput = false,
      allowedTools,
      readOnly = false,
      promptScope,
    }) async => 'extract-turn',
    onWaitForOutcome: (sessionId, turnId) async => TurnOutcome(
      turnId: turnId,
      sessionId: sessionId,
      status: TurnStatus.completed,
      responseText: response,
      completedAt: DateTime.utc(2026, 5),
    ),
  ),
  sessions: sessions,
  maxBytes: 4096,
  retryAttempts: 1,
  stabilityWindow: const Duration(milliseconds: 20),
  now: () => DateTime.utc(2026, 5),
  onMemoryObserve: (args, context) async => const {},
);

String _payload({required String body, List<String> droppedTopics = const []}) =>
    '''
<workflow-context>{
  "memory_findings": [{"text": "Synthesized durable finding."}],
  "dropped_topics": ${droppedTopics.map((topic) => '"$topic"').toList()},
  "wiki_page": {"slug": "dart-roadmap", "title": "Dart Roadmap", "body": "$body", "confidence": "medium"},
  "facts": []
}</workflow-context>
''';
