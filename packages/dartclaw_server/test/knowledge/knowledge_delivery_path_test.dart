import 'dart:io';

import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' show FakeTurnManager, SessionService;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../delivery_test_support.dart';

/// TI11: the scheduled delivery path must carry per-file/per-page detail
/// (quarantined files with reasons, wiki-lint findings) through the existing
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
      onMemorySave: (args) async => const {},
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
      onExecute: () async => wiki.lint().summary(),
    );
    await schedule.executeJobForTesting(lintJob);

    final delivered = delivery.calls.single;
    expect(delivered.result, contains('broken.md'));
    expect(delivered.result, contains('missing-link'));
  });
}
