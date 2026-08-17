import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' show MemoryOriginKind;
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:dartclaw_storage/dartclaw_storage.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' show FakeTurnManager, SessionService, TurnOutcome, TurnStatus;
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  late Directory workspace;
  late List<Map<String, dynamic>> saved;
  late List<MemoryCaptureContext> captureContexts;
  late KnowledgeInboxService service;
  late SessionService sessions;
  late FakeTurnManager turns;
  late Database kgDb;
  late TemporalKnowledgeGraphService kg;

  setUp(() {
    workspace = Directory.systemTemp.createTempSync('dartclaw_knowledge_inbox_service_test_');
    saved = <Map<String, dynamic>>[];
    captureContexts = <MemoryCaptureContext>[];
    sessions = SessionService(baseDir: p.join(workspace.path, 'sessions'));
    kgDb = sqlite3.openInMemory();
    kg = TemporalKnowledgeGraphService(kgDb);
    turns = _turnsReturning(_extractionPayload());
    File(p.join(workspace.path, 'USER.md')).writeAsStringSync('''
# User Context

## Not Relevant

- celebrity gossip
''');
    service = KnowledgeInboxService(
      workspaceDir: workspace.path,
      wiki: WikiPageStore(workspaceDir: workspace.path),
      turns: turns,
      sessions: sessions,
      kg: kg,
      maxBytes: 80,
      retryAttempts: 1,
      stabilityWindow: const Duration(milliseconds: 20),
      now: () => DateTime.utc(2026, 5),
      failureHook: (text) {
        if (text.contains('force-ingest-failure')) {
          throw StateError('forced ingestion failure');
        }
      },
      onMemoryObserve: (args, context) async {
        saved.add(args);
        captureContexts.add(context);
        return {
          'content': [
            {'type': 'text', 'text': 'saved'},
          ],
        };
      },
    );
  });

  tearDown(() {
    kgDb.close();
    if (workspace.existsSync()) workspace.deleteSync(recursive: true);
  });

  test('S01 stable file runs a cron extraction turn and becomes durable synthesized knowledge', () async {
    Directory(p.join(workspace.path, 'inbox')).createSync(recursive: true);
    File(p.join(workspace.path, 'inbox', 'dart-roadmap.md'))
        .writeAsStringSync('Dart roadmap notes. Verbatim source sentence that must not be stored.');

    final report = await service.runOnce(requireStable: false);

    expect(report.processed, ['dart-roadmap.md']);
    expect(turns.startTurnCallCount, 1);
    expect(turns.startedTurns.single.source, 'cron');
    expect(turns.startedTurns.single.agentName, 'cron:knowledge-inbox');
    expect(turns.startedTurns.single.effort, 'medium');
    expect(turns.startedTurns.single.maxTurns, 1);
    expect(turns.startedTurns.single.allowedTools, ['__knowledge_inbox_no_tools__']);
    expect(turns.startedTurns.single.readOnly, isTrue);
    expect(turns.taskToolFilterChanges, isEmpty);
    expect(turns.taskReadOnlyChanges, isEmpty);
    expect(saved.single['text'], contains('Synthesized inbox finding from inbox/dart-roadmap.md'));
    expect(saved.single['text'], contains('Dart roadmap now emphasizes package governance'));
    expect(saved.single['text'], isNot(contains('Verbatim source sentence that must not be stored')));
    expect(captureContexts.single.originKind, MemoryOriginKind.inbox);
    expect(captureContexts.single.sourceLocator, 'inbox/dart-roadmap.md');
    expect(captureContexts.first.sourceEvent, startsWith('sha256:'));
    expect(captureContexts.single.caller, 'knowledge-inbox');
    expect(captureContexts.single.sessionRef, 'knowledge-inbox');
    expect(File(p.join(workspace.path, 'processed', 'dart-roadmap.md')).existsSync(), isTrue);
    final wiki = File(p.join(workspace.path, 'wiki', 'dart-roadmap.md')).readAsStringSync();
    expect(wiki, contains('provenance: llm-authored'));
    expect(wiki, contains('sources:'));
    expect(wiki, contains('last_updated_by: "cron:knowledge-inbox"'));
    expect(kg.query(entity: 'Dart SDK', predicate: 'roadmap').single.source, 'inbox/dart-roadmap.md');
    expect(report.summary, contains('processed files: dart-roadmap.md'));
  });

  test('same inbox path with a later identical item receives a distinct source event', () async {
    service = KnowledgeInboxService(
      workspaceDir: workspace.path,
      wiki: WikiPageStore(workspaceDir: workspace.path),
      turns: turns,
      sessions: sessions,
      kg: kg,
      maxBytes: 4096,
      retryAttempts: 1,
      stabilityWindow: const Duration(milliseconds: 20),
      onMemoryObserve: (args, context) async {
        captureContexts.add(context);
        return const {};
      },
    );
    final inbox = Directory(p.join(workspace.path, 'inbox'))..createSync(recursive: true);
    final item = File(p.join(inbox.path, 'reused.md'))..writeAsStringSync('Same source body.');
    item.setLastModifiedSync(DateTime.utc(2026, 5, 1));

    await service.runOnce(requireStable: false);
    File(p.join(workspace.path, 'processed', 'reused.md')).deleteSync();
    item.writeAsStringSync('Same source body.');
    item.setLastModifiedSync(DateTime.utc(2026, 5, 2));
    await service.runOnce(requireStable: false);

    expect(captureContexts, hasLength(2));
    expect(captureContexts.map((context) => context.sourceLocator).toSet(), {'inbox/reused.md'});
    expect(captureContexts.map((context) => context.sourceEvent).toSet(), hasLength(2));
  });

  test('read-only list applies result, scan, and preview bounds before reading file bodies', () async {
    Directory(p.join(workspace.path, 'inbox')).createSync(recursive: true);
    File(p.join(workspace.path, 'inbox', 'match.md')).writeAsStringSync('roadmap ${'x' * 100}');
    File(p.join(workspace.path, 'inbox', 'later.md')).writeAsStringSync('roadmap second');
    File(p.join(workspace.path, 'inbox', 'unscanned.md')).writeAsStringSync('roadmap third');

    final items = await KnowledgeInboxReadService(
      workspaceDir: workspace.path,
      maxPreviewBytes: 12,
      maxScannedFiles: 2,
    ).list(query: 'roadmap', limit: 1);

    expect(items, hasLength(1));
    expect(items.single.snippet.length, lessThanOrEqualTo(12));
  });

  test('read-only source lookup reopens only supported regular inbox locators', () async {
    final inbox = Directory(p.join(workspace.path, 'inbox'))..createSync(recursive: true);
    File(p.join(inbox.path, 'note.md')).writeAsStringSync('Native inbox detail');
    File(p.join(inbox.path, 'secret.bin')).writeAsStringSync('not an inbox source');
    final reader = KnowledgeInboxReadService(workspaceDir: workspace.path);

    expect(await reader.read('inbox/note.md'), 'Native inbox detail');
    expect(await reader.read('inbox/missing.md'), isNull);
    expect(await reader.read('inbox/../note.md'), isNull);
    expect(await reader.read('inbox/secret.bin'), isNull);
  });

  test('inbox capture carries the content-addressed source identity', () async {
    Directory(p.join(workspace.path, 'inbox')).createSync(recursive: true);
    File(p.join(workspace.path, 'inbox', 'retry.md')).writeAsStringSync('Retryable source body.');

    final report = await service.runOnce(requireStable: false);

    expect(report.processed, ['retry.md']);
    expect(captureContexts.map((context) => context.originKind).toSet(), {MemoryOriginKind.inbox});
    expect(captureContexts.map((context) => context.sourceLocator).toSet(), {'inbox/retry.md'});
    expect(captureContexts.map((context) => context.sourceEvent).toSet(), hasLength(1));
    expect(captureContexts.first.sourceEvent, startsWith('sha256:'));
    expect(captureContexts.map((context) => context.caller).toSet(), {'knowledge-inbox'});
    expect(captureContexts.map((context) => context.sessionRef).toSet(), {'knowledge-inbox'});
  });

  // Everything after the extraction turn is durable. Replaying it is what left
  // three copies of one file's findings in memory and three in the KG while the
  // run reported the file as quarantined and nothing as processed.
  test('a failure during the durable commit is quarantined, not replayed', () async {
    var calls = 0;
    final failing = KnowledgeInboxService(
      workspaceDir: workspace.path,
      wiki: WikiPageStore(workspaceDir: workspace.path),
      turns: turns,
      sessions: sessions,
      kg: kg,
      maxBytes: 4096,
      retryAttempts: 2,
      stabilityWindow: const Duration(milliseconds: 20),
      now: () => DateTime.utc(2026, 5),
      onMemoryObserve: (args, context) async {
        calls++;
        throw StateError('injected durable-write failure');
      },
    );
    Directory(p.join(workspace.path, 'inbox')).createSync(recursive: true);
    File(p.join(workspace.path, 'inbox', 'commit.md')).writeAsStringSync('Committable source body.');

    final report = await failing.runOnce(requireStable: false);

    expect(calls, 1);
    expect(report.quarantined.single.file, 'commit.md');
    expect(report.processed, isEmpty);
    expect(kg.timeline(entity: 'Dart SDK'), isEmpty);
  });

  // The extraction turn is the one step that writes nothing, so it is the only
  // one worth retrying.
  test('a failing extraction turn is retried without duplicating anything durable', () async {
    Directory(p.join(workspace.path, 'inbox')).createSync(recursive: true);
    File(p.join(workspace.path, 'inbox', 'flaky.md')).writeAsStringSync('Flaky source body.');
    var turnCalls = 0;
    final flaky = FakeTurnManager(
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
      onWaitForOutcome: (sessionId, turnId) async {
        if (turnCalls++ == 0) throw StateError('injected extraction failure');
        return TurnOutcome(
          turnId: turnId,
          sessionId: sessionId,
          status: TurnStatus.completed,
          responseText: _extractionPayload(),
          completedAt: DateTime.utc(2026, 5),
        );
      },
    );

    final retrying = KnowledgeInboxService(
      workspaceDir: workspace.path,
      wiki: WikiPageStore(workspaceDir: workspace.path),
      turns: flaky,
      sessions: sessions,
      kg: kg,
      maxBytes: 4096,
      retryAttempts: 1,
      stabilityWindow: const Duration(milliseconds: 20),
      now: () => DateTime.utc(2026, 5),
      onMemoryObserve: (args, context) async {
        saved.add(args);
        return const {};
      },
    );

    final report = await retrying.runOnce(requireStable: false);

    expect(turnCalls, 2);
    expect(report.processed, ['flaky.md']);
    expect(saved, hasLength(1));
  });

  test('read-only list tolerates preview caps that split UTF-8 characters', () async {
    Directory(p.join(workspace.path, 'inbox')).createSync(recursive: true);
    File(p.join(workspace.path, 'inbox', 'utf8.md')).writeAsStringSync('€ roadmap');

    final items = await KnowledgeInboxReadService(workspaceDir: workspace.path, maxPreviewBytes: 1).list(limit: 1);

    expect(items, hasLength(1));
    expect(items.single.label, 'utf8.md');
  });

  test('read-only list keeps pagination stable when file timestamps tie', () async {
    for (final folder in KnowledgeInboxReadService.folders) {
      Directory(p.join(workspace.path, folder)).createSync(recursive: true);
    }
    final sameModified = DateTime.utc(2026, 5, 1, 12);
    final files = [
      File(p.join(workspace.path, 'processed', 'b.md'))..writeAsStringSync('roadmap processed b'),
      File(p.join(workspace.path, 'inbox', 'c.md'))..writeAsStringSync('roadmap inbox c'),
      File(p.join(workspace.path, 'inbox', 'a.md'))..writeAsStringSync('roadmap inbox a'),
    ];
    for (final file in files) {
      file.setLastModifiedSync(sameModified);
    }

    final items = await KnowledgeInboxReadService(workspaceDir: workspace.path).list(query: 'roadmap', limit: 3);

    expect(items.map((item) => item.locator), ['inbox/a.md', 'inbox/c.md', 'processed/b.md']);
  });

  test('each inbox file gets an isolated cron session key', () async {
    Directory(p.join(workspace.path, 'inbox')).createSync(recursive: true);
    File(p.join(workspace.path, 'inbox', 'first.md')).writeAsStringSync('First source body.');
    File(p.join(workspace.path, 'inbox', 'second.md')).writeAsStringSync('Second source body.');

    await service.runOnce(requireStable: false);

    expect(turns.startedTurns, hasLength(2));
    expect(turns.startedTurns.map((turn) => turn.sessionId).toSet(), hasLength(2));
  });

  test('same-basename sequential inbox attempts use isolated cron session keys', () async {
    Directory(p.join(workspace.path, 'inbox')).createSync(recursive: true);
    File(p.join(workspace.path, 'inbox', 'notes.md')).writeAsStringSync('First source body.');

    await service.runOnce(requireStable: false);
    File(p.join(workspace.path, 'inbox', 'notes.md')).writeAsStringSync('Second source body.');
    await service.runOnce(requireStable: false);

    expect(turns.startedTurns, hasLength(2));
    expect(turns.startedTurns.map((turn) => turn.sessionId).toSet(), hasLength(2));
    for (final turn in turns.startedTurns) {
      expect(turn.allowedTools, ['__knowledge_inbox_no_tools__']);
      expect(turn.readOnly, isTrue);
    }
    final cronKeys = (await sessions.listSessions(type: SessionType.cron))
        .map((session) => Uri.decodeComponent(SessionKey.parse(session.channelKey!).identifiers))
        .toList();
    expect(cronKeys, hasLength(2));
    expect(cronKeys.every((key) => key.contains('knowledge-inbox') && key.contains('notes.md')), isTrue);
    expect(cronKeys.toSet(), hasLength(2));
  });

  test('TI01 exposes inbox as scheduled callback job without a second scheduler', () async {
    final job = service.scheduledJob(intervalMinutes: 15);

    expect(job.id, 'knowledge-inbox');
    expect(job.scheduleType, ScheduleType.interval);
    expect(job.intervalMinutes, 15);
    expect(job.deliveryMode, DeliveryMode.announce);
    expect(job.onExecute, isNotNull);
  });

  test('S02 retry exhaustion quarantines file with error metadata', () async {
    Directory(p.join(workspace.path, 'inbox')).createSync(recursive: true);
    File(p.join(workspace.path, 'inbox', 'bad.md')).writeAsStringSync('force-ingest-failure');

    final report = await service.runOnce(requireStable: false);

    expect(report.quarantined.single.file, 'bad.md');
    expect(report.quarantined.single.attempts, 2);
    expect(File(p.join(workspace.path, 'quarantine', 'bad.md')).existsSync(), isTrue);
    expect(
      File(p.join(workspace.path, 'quarantine', 'bad.md.error.json')).readAsStringSync(),
      contains('forced ingestion failure'),
    );
    expect(report.summary, contains('quarantined files: bad.md: Bad state: forced ingestion failure'));
  });

  test('S03 relevance filtering excludes USER.md Not Relevant topics', () async {
    turns = _turnsReturning(
      _extractionPayload(
        memoryFinding: 'Dart package notes remain because celebrity gossip explains why it was deprioritized.',
      ),
    );
    service = KnowledgeInboxService(
      workspaceDir: workspace.path,
      wiki: WikiPageStore(workspaceDir: workspace.path),
      turns: turns,
      sessions: sessions,
      kg: kg,
      maxBytes: 80,
      retryAttempts: 1,
      stabilityWindow: const Duration(milliseconds: 20),
      now: () => DateTime.utc(2026, 5),
      onMemoryObserve: (args, context) async {
        saved.add(args);
        captureContexts.add(context);
        return const {};
      },
    );
    Directory(p.join(workspace.path, 'inbox')).createSync(recursive: true);
    File(p.join(workspace.path, 'inbox', 'mixed.md')).writeAsStringSync('''
Dart package notes should remain.

Celebrity gossip should be excluded.
''');

    await service.runOnce(requireStable: false);

    expect(saved.single['text'], contains('Dart package notes'));
    expect(
      (turns.startedTurns.single.messages.single['content'] as String),
      contains('USER.md Not Relevant topics: celebrity gossip'),
    );
    expect((saved.single['text'] as String), contains('celebrity gossip explains why it was deprioritized'));
    expect((saved.single['text'] as String), isNot(contains('Celebrity gossip should be excluded.')));
  });

  test('S04 unsupported and oversized files are skipped with explicit reasons', () async {
    Directory(p.join(workspace.path, 'inbox')).createSync(recursive: true);
    File(p.join(workspace.path, 'inbox', 'image.png')).writeAsStringSync('png');
    File(p.join(workspace.path, 'inbox', 'huge.md')).writeAsStringSync('x' * 120);

    final report = await service.runOnce(requireStable: false);

    expect(report.skipped.map((skip) => skip.file), containsAll(['image.png', 'huge.md']));
    expect(report.skipped.map((skip) => skip.reason).join('\n'), contains('unsupported file type'));
    expect(report.skipped.map((skip) => skip.reason).join('\n'), contains('file exceeds size limit'));
  });

  test('still-changing files remain in the inbox for a later run', () async {
    Directory(p.join(workspace.path, 'inbox')).createSync(recursive: true);
    final file = File(p.join(workspace.path, 'inbox', 'draft.md'))..writeAsStringSync('initial');
    service = KnowledgeInboxService(
      workspaceDir: workspace.path,
      wiki: WikiPageStore(workspaceDir: workspace.path),
      turns: turns,
      sessions: sessions,
      kg: kg,
      maxBytes: 80,
      stabilityWindow: const Duration(milliseconds: 20),
      now: () => DateTime.utc(2026, 5),
      onMemoryObserve: (args, context) async {
        saved.add(args);
        return const {};
      },
    );
    Future<void>.delayed(const Duration(milliseconds: 1), () => file.writeAsStringSync('changed content'));

    final report = await service.runOnce();

    expect(report.skipped.single.reason, 'file is still changing');
    expect(file.existsSync(), isTrue);
    expect(File(p.join(workspace.path, 'skipped', 'draft.md')).existsSync(), isFalse);
  });

  test('NDJSON is accepted and PDF is skipped when extraction is unavailable', () async {
    Directory(p.join(workspace.path, 'inbox')).createSync(recursive: true);
    File(p.join(workspace.path, 'inbox', 'events.ndjson')).writeAsStringSync('{"event":"release"}\n');
    File(p.join(workspace.path, 'inbox', 'brief.pdf')).writeAsBytesSync([37, 80, 68, 70]);

    final report = await service.runOnce(requireStable: false);

    expect(report.processed, ['events.ndjson']);
    expect(report.skipped.single.file, 'brief.pdf');
    expect(report.skipped.single.reason, contains('PDF text extraction is unavailable'));
    expect(saved.single['text'], isNot(contains('Text extraction is not available')));
    expect(File(p.join(workspace.path, 'processed', 'brief.pdf')).existsSync(), isFalse);
  });

  test('processed retention removes old files and keeps recent files', () async {
    final processedDir = Directory(p.join(workspace.path, 'processed'))..createSync(recursive: true);
    final oldFile = File(p.join(processedDir.path, 'old.md'))..writeAsStringSync('old');
    oldFile.setLastModifiedSync(DateTime.utc(2026, 3));
    final recentFile = File(p.join(processedDir.path, 'recent.md'))..writeAsStringSync('recent');
    recentFile.setLastModifiedSync(DateTime.utc(2026, 4, 20));

    await service.runOnce(requireStable: false);

    expect(oldFile.existsSync(), isFalse);
    expect(recentFile.existsSync(), isTrue);
  });

  KnowledgeInboxService serviceReturning(
    String responseText, {
    TemporalKnowledgeGraphService? graph,
    FakeTurnManager? turns,
  }) {
    return KnowledgeInboxService(
      workspaceDir: workspace.path,
      wiki: WikiPageStore(workspaceDir: workspace.path),
      turns: turns ?? _turnsReturning(responseText),
      sessions: sessions,
      kg: graph ?? kg,
      maxBytes: 4096,
      retryAttempts: 1,
      stabilityWindow: const Duration(milliseconds: 20),
      now: () => DateTime.utc(2026, 5),
      onMemoryObserve: (args, context) async {
        saved.add(args);
        return const {};
      },
    );
  }

  test('validation failure writes nothing durable and does not duplicate across retries', () async {
    // Memory finding is valid but the wiki body is missing — the whole payload
    // must be rejected before any write so no memory is persisted (and nothing
    // is duplicated across the retry).
    final response = '''
<workflow-context>{
  "memory_findings": [{"text": "A synthesized finding distinct from the source."}],
  "wiki_page": {"slug": "x", "title": "X", "body": "", "confidence": "medium"},
  "facts": []
}</workflow-context>
''';
    service = serviceReturning(response);
    Directory(p.join(workspace.path, 'inbox')).createSync(recursive: true);
    File(p.join(workspace.path, 'inbox', 'partial.md')).writeAsStringSync('Some source body.');

    final report = await service.runOnce(requireStable: false);

    expect(report.quarantined.single.file, 'partial.md');
    expect(saved, isEmpty, reason: 'no memory should be written when the payload is rejected');
    expect(File(p.join(workspace.path, 'wiki', 'partial.md')).existsSync(), isFalse);
  });

  test('verbatim source wrapped in a summary prefix is rejected before writes', () async {
    const source = 'Quarterly roadmap details that must not be copied verbatim into memory.';
    final response =
        '''
<workflow-context>{
  "memory_findings": [{"text": "Summary:\\n\\n$source"}],
  "wiki_page": {"slug": "r", "title": "R", "body": "Real synthesis.", "confidence": "medium"},
  "facts": []
}</workflow-context>
''';
    service = serviceReturning(response);
    Directory(p.join(workspace.path, 'inbox')).createSync(recursive: true);
    File(p.join(workspace.path, 'inbox', 'wrapped.md')).writeAsStringSync(source);

    final report = await service.runOnce(requireStable: false);

    expect(report.quarantined.single.file, 'wrapped.md');
    expect(saved, isEmpty);
  });

  test('a fact missing valid_from quarantines the file and writes no KG fact', () async {
    final response = '''
<workflow-context>{
  "memory_findings": [{"text": "Synthesized finding."}],
  "wiki_page": {"slug": "d", "title": "D", "body": "Synthesis body.", "confidence": "medium"},
  "facts": [{"entity": "Dart SDK", "predicate": "roadmap", "value": "governance", "valid_to": null}]
}</workflow-context>
''';
    service = serviceReturning(response);
    Directory(p.join(workspace.path, 'inbox')).createSync(recursive: true);
    File(p.join(workspace.path, 'inbox', 'undated.md')).writeAsStringSync('Roadmap notes.');

    final report = await service.runOnce(requireStable: false);

    expect(report.quarantined.single.file, 'undated.md');
    expect(saved, isEmpty);
    expect(kg.query(entity: 'Dart SDK', predicate: 'roadmap'), isEmpty);
  });

  test('a fact with an invalid timezone offset quarantines the file and writes no KG fact', () async {
    final response = '''
<workflow-context>{
  "memory_findings": [{"text": "Synthesized finding."}],
  "wiki_page": {"slug": "d", "title": "D", "body": "Synthesis body.", "confidence": "medium"},
  "facts": [{"entity": "Dart SDK", "predicate": "roadmap", "value": "governance", "valid_from": "2026-05-01T12:00:00+24:00", "valid_to": null}]
}</workflow-context>
''';
    service = serviceReturning(response);
    Directory(p.join(workspace.path, 'inbox')).createSync(recursive: true);
    File(p.join(workspace.path, 'inbox', 'bad-offset.md')).writeAsStringSync('Roadmap notes.');

    final report = await service.runOnce(requireStable: false);

    expect(report.quarantined.single.file, 'bad-offset.md');
    expect(saved, isEmpty);
    expect(kg.query(entity: 'Dart SDK', predicate: 'roadmap'), isEmpty);
  });

  test('a source with empty facts still ingests when the KG is wired', () async {
    final response = '''
<workflow-context>{
  "memory_findings": [{"text": "Style guidance synthesized from the source."}],
  "wiki_page": {"slug": "style", "title": "Style", "body": "Non-temporal style synthesis.", "confidence": "medium"},
  "facts": []
}</workflow-context>
''';
    service = serviceReturning(response);
    Directory(p.join(workspace.path, 'inbox')).createSync(recursive: true);
    File(p.join(workspace.path, 'inbox', 'style.md')).writeAsStringSync('Style guide content.');

    final report = await service.runOnce(requireStable: false);

    expect(report.processed, ['style.md']);
    expect(report.quarantined, isEmpty);
    expect(saved.single['text'], contains('Style guidance synthesized'));
  });

  test('extraction prompt embeds the source as a JSON-encoded string so markdown fences cannot escape it', () async {
    const source = 'Notes\n```\nfenced block\n```\nmore notes.';
    service = serviceReturning(_extractionPayload());
    Directory(p.join(workspace.path, 'inbox')).createSync(recursive: true);
    File(p.join(workspace.path, 'inbox', 'fenced.md')).writeAsStringSync(source);

    await service.runOnce(requireStable: false);

    final prompt = (service.turns as FakeTurnManager).startedTurns.single.messages.single['content'] as String;
    expect(prompt, contains(jsonEncode(source)));
    expect(prompt, isNot(contains('```\n$source')));
  });

  test('a contradicting fact is surfaced and not inserted', () async {
    kg.addFact(
      entity: 'Dart SDK',
      predicate: 'channel',
      value: 'stable',
      validFrom: '2026-04-01T00:00:00Z',
      source: 'wiki/dart.md',
    );
    final response = '''
<workflow-context>{
  "memory_findings": [{"text": "Synthesized channel note."}],
  "wiki_page": {"slug": "c", "title": "C", "body": "Channel synthesis.", "confidence": "medium"},
  "facts": [{"entity": "Dart SDK", "predicate": "channel", "value": "beta", "valid_from": "2026-05-01T00:00:00Z", "valid_to": null}]
}</workflow-context>
''';
    service = serviceReturning(response);
    Directory(p.join(workspace.path, 'inbox')).createSync(recursive: true);
    File(p.join(workspace.path, 'inbox', 'channel.md')).writeAsStringSync('Channel update.');

    final report = await service.runOnce(requireStable: false);

    expect(report.processed, ['channel.md']);
    expect(report.contradictions.single.file, 'channel.md');
    expect(report.contradictions.single.detail, contains('dart sdk.channel'));
    expect(report.summary, contains('contradictions: channel.md'));
    final channels = kg.query(entity: 'Dart SDK', predicate: 'channel').map((fact) => fact.value).toList();
    expect(channels, ['stable'], reason: 'the conflicting beta fact must not be inserted');
  });

  test('contradicting facts inside one extraction payload are surfaced and not inserted', () async {
    final response = '''
<workflow-context>{
  "memory_findings": [{"text": "Synthesized channel note."}],
  "wiki_page": {"slug": "c", "title": "C", "body": "Channel synthesis.", "confidence": "medium"},
  "facts": [
    {"entity": "Dart SDK", "predicate": "channel", "value": "stable", "valid_from": "2026-05-01T00:00:00Z", "valid_to": null},
    {"entity": "Dart SDK", "predicate": "channel", "value": "beta", "valid_from": "2026-05-01T00:00:00Z", "valid_to": null}
  ]
}</workflow-context>
''';
    service = serviceReturning(response);
    Directory(p.join(workspace.path, 'inbox')).createSync(recursive: true);
    File(p.join(workspace.path, 'inbox', 'channel.md')).writeAsStringSync('Channel update.');

    final report = await service.runOnce(requireStable: false);

    expect(report.processed, ['channel.md']);
    expect(report.contradictions.single.detail, contains('conflicting values in extraction payload'));
    expect(kg.query(entity: 'Dart SDK', predicate: 'channel'), isEmpty);
  });

  test('batch contradiction screening keeps non-overlapping clean facts for the same key', () async {
    final response = '''
<workflow-context>{
  "memory_findings": [{"text": "Synthesized channel history."}],
  "wiki_page": {"slug": "c", "title": "C", "body": "Channel history.", "confidence": "medium"},
  "facts": [
    {"entity": "Dart SDK", "predicate": "channel", "value": "dev", "valid_from": "2026-03-01T00:00:00Z", "valid_to": "2026-03-31T00:00:00Z"},
    {"entity": "Dart SDK", "predicate": "channel", "value": "stable", "valid_from": "2026-05-01T00:00:00Z", "valid_to": null},
    {"entity": "Dart SDK", "predicate": "channel", "value": "beta", "valid_from": "2026-05-01T00:00:00Z", "valid_to": null}
  ]
}</workflow-context>
''';
    service = serviceReturning(response);
    Directory(p.join(workspace.path, 'inbox')).createSync(recursive: true);
    File(p.join(workspace.path, 'inbox', 'channel.md')).writeAsStringSync('Raw channel notes.');

    final report = await service.runOnce(requireStable: false);

    expect(report.contradictions.single.detail, contains('conflicting values in extraction payload'));
    expect(kg.timeline(entity: 'Dart SDK').map((fact) => fact.value), ['dev']);
  });

  test('non-overlapping historical facts inside one extraction payload are inserted', () async {
    final response = '''
<workflow-context>{
  "memory_findings": [{"text": "Synthesized channel history."}],
  "wiki_page": {"slug": "c", "title": "C", "body": "Channel history.", "confidence": "medium"},
  "facts": [
    {"entity": "Dart SDK", "predicate": "channel", "value": "beta", "valid_from": "2026-04-01T00:00:00Z", "valid_to": "2026-04-30T00:00:00Z"},
    {"entity": "Dart SDK", "predicate": "channel", "value": "stable", "valid_from": "2026-05-01T00:00:00Z", "valid_to": null}
  ]
}</workflow-context>
''';
    service = serviceReturning(response);
    Directory(p.join(workspace.path, 'inbox')).createSync(recursive: true);
    File(p.join(workspace.path, 'inbox', 'channel.md')).writeAsStringSync('Raw channel notes.');

    final report = await service.runOnce(requireStable: false);

    expect(report.contradictions, isEmpty);
    expect(kg.timeline(entity: 'Dart SDK'), hasLength(2));
  });

  test('a file that disappears during the stability window is skipped without aborting the run', () async {
    service = serviceReturning(_extractionPayload());
    Directory(p.join(workspace.path, 'inbox')).createSync(recursive: true);
    final vanishing = File(p.join(workspace.path, 'inbox', 'vanishing.md'))..writeAsStringSync('temp');
    File(p.join(workspace.path, 'inbox', 'survivor.md')).writeAsStringSync('Survivor source body.');
    Future<void>.delayed(const Duration(milliseconds: 1), () => vanishing.deleteSync());

    final report = await service.runOnce();

    expect(report.skipped.map((skip) => skip.file), contains('vanishing.md'));
    expect(
      report.skipped.firstWhere((skip) => skip.file == 'vanishing.md').reason,
      'file disappeared before processing',
    );
    expect(report.processed, contains('survivor.md'));
  });

  test('a later batch on a stored slug keeps prior content, prior sources, and reports the merge', () async {
    final inbox = Directory(p.join(workspace.path, 'inbox'))..createSync(recursive: true);
    File(p.join(inbox.path, 'first.md')).writeAsStringSync('First batch source.');
    await serviceReturning(_extractionPayload()).runOnce(requireStable: false);
    File(p.join(inbox.path, 'second.md')).writeAsStringSync('Supplement batch source.');

    final report = await serviceReturning(
      _extractionPayload(wikiBody: 'Follow-up governance detail carried by the supplement batch.'),
    ).runOnce(requireStable: false);

    final page = File(p.join(workspace.path, 'wiki', 'dart-roadmap.md')).readAsStringSync();
    expect(page, contains('Dart roadmap synthesis with source-backed package governance notes.'));
    expect(page, contains('Follow-up governance detail carried by the supplement batch.'));
    expect(page, contains('sources:\n  - "inbox/first.md"\n  - "inbox/second.md"'));
    expect(RegExp(r'^# ', multiLine: true).allMatches(page), hasLength(1));
    expect(report.wikiMerges.single.file, 'second.md');
    expect(report.wikiMerges.single.slug, 'dart-roadmap');
    expect(report.wikiMerges.single.outcome, WikiPageOutcome.supplemented);
    expect(report.summary, contains('wiki merges: second.md -> wiki/dart-roadmap.md (supplement 1)'));
  });

  // A collision that added nothing has to read differently from no collision at
  // all, or the operator cannot tell a duplicate batch from a fresh one.
  test('a batch whose synthesis the page already carries is reported as a refresh, not as a merge', () async {
    final inbox = Directory(p.join(workspace.path, 'inbox'))..createSync(recursive: true);
    File(p.join(inbox.path, 'first.md')).writeAsStringSync('First batch source.');
    await serviceReturning(_extractionPayload()).runOnce(requireStable: false);
    final page = File(p.join(workspace.path, 'wiki', 'dart-roadmap.md'));
    final before = page.readAsStringSync();
    File(p.join(inbox.path, 'second.md')).writeAsStringSync('Duplicate batch source.');

    final report = await serviceReturning(_extractionPayload()).runOnce(requireStable: false);

    expect(report.wikiMerges.single.outcome, WikiPageOutcome.refreshed);
    expect(report.summary, contains('wiki merges: second.md -> wiki/dart-roadmap.md (refresh, no new content)'));
    final after = page.readAsStringSync();
    // No content and no authorship moved; only the source that contributed it is
    // now accounted for in the provenance chain.
    expect(after, isNot(contains('## Supplement')));
    expect(after, contains(r'last_updated: "2026-05-01T00:00:00.000Z"'));
    expect(after, contains('sources:\n  - "inbox/first.md"\n  - "inbox/second.md"'));
    expect(_body(after), _body(before));
  });

  // A durable write already landed, so re-running the file would re-extract with
  // a reworded body and append a second supplement section for one source.
  // A source left in the inbox is re-ingested on the next scheduled run, and a
  // fresh extraction rewords the body, so the page grows a supplement per run
  // forever while every report says the file was processed.
  test('a source that cannot leave the inbox is quarantined so the next run cannot ingest it again', () async {
    final inbox = Directory(p.join(workspace.path, 'inbox'))..createSync(recursive: true);
    File(p.join(inbox.path, 'first.md')).writeAsStringSync('First batch source.');
    await serviceReturning(_extractionPayload()).runOnce(requireStable: false);
    File(p.join(inbox.path, 'batch.md')).writeAsStringSync('Supplement batch source.');
    // Renaming onto a non-empty directory fails, so the move throws after the
    // durable writes have all landed.
    final blocker = Directory(p.join(workspace.path, 'processed', 'batch.md'))..createSync(recursive: true);
    File(p.join(blocker.path, 'occupied')).writeAsStringSync('x');
    final varying = _turnsCycling([
      _extractionPayload(wikiBody: 'Follow-up governance detail carried by the supplement batch.'),
      _extractionPayload(wikiBody: 'Follow-up governance detail, carried by the supplement batch.'),
    ]);

    final first = await serviceReturning(_extractionPayload(), turns: varying).runOnce(requireStable: false);
    final second = await serviceReturning(_extractionPayload(), turns: varying).runOnce(requireStable: false);

    // Reported once, as a quarantine, so the count matches what is on disk. It
    // was ingested, so it stays in `processed` too – but it is never also
    // reported as skipped, which would read as two terminal outcomes.
    expect(first.processed, ['batch.md']);
    expect(first.skipped, isEmpty);
    expect(first.quarantined.single.file, 'batch.md');
    expect(first.quarantined.single.error, startsWith('ingested but could not leave the inbox'));
    expect(first.summary, contains('quarantined=1'));
    expect(File(p.join(inbox.path, 'batch.md')).existsSync(), isFalse);
    expect(File(p.join(workspace.path, 'quarantine', 'batch.md')).existsSync(), isTrue);
    expect(second.processed, isEmpty);
    expect(varying.startedTurns, hasLength(1));
    final page = File(p.join(workspace.path, 'wiki', 'dart-roadmap.md')).readAsStringSync();
    expect('## Supplement'.allMatches(page), hasLength(1));
  });

  // Validating the model-controlled confidence inside the store would reject it
  // only after the memory findings were already stored.
  test('an unsupported wiki confidence is rejected before anything durable is written', () async {
    Directory(p.join(workspace.path, 'inbox')).createSync(recursive: true);
    File(p.join(workspace.path, 'inbox', 'bad.md')).writeAsStringSync('Curated batch source.');

    final report = await serviceReturning(
      _extractionPayload().replaceFirst('"confidence": "medium"', '"confidence": "very high"'),
    ).runOnce(requireStable: false);

    expect(report.quarantined.single.file, 'bad.md');
    expect(saved, isEmpty);
    expect(kg.timeline(entity: 'Dart SDK'), isEmpty);
  });

  // The wiki page must be the last durable write, so that a `wiki-merges=0`
  // report is always true: a KG failure must mean the page was never touched.
  // The failure has to come from the insert itself – a malformed fact date is
  // rejected while the extraction is still being parsed, before either write,
  // so it cannot tell the two orderings apart.
  test('a KG insert failure leaves no wiki page behind', () async {
    Directory(p.join(workspace.path, 'inbox')).createSync(recursive: true);
    File(p.join(workspace.path, 'inbox', 'rejected.md')).writeAsStringSync('Curated batch source.');
    final rejectingDb = sqlite3.openInMemory();
    addTearDown(rejectingDb.close);

    final report = await serviceReturning(
      _extractionPayload(),
      graph: _RejectingKnowledgeGraph(rejectingDb),
    ).runOnce(requireStable: false);

    expect(report.quarantined.single.file, 'rejected.md');
    expect(report.wikiMerges, isEmpty);
    expect(File(p.join(workspace.path, 'wiki', 'dart-roadmap.md')).existsSync(), isFalse);
  });

  // A quarantined file must never leave a mutated page behind: the collision
  // would be invisible in the run report exactly when something went wrong.
  test('a stored page the store cannot read quarantines the source and is left untouched', () async {
    Directory(p.join(workspace.path, 'inbox')).createSync(recursive: true);
    File(p.join(workspace.path, 'inbox', 'batch.md')).writeAsStringSync('Batch source.');
    final wiki = WikiPageStore(workspaceDir: workspace.path)..bootstrap();
    final page = File(p.join(wiki.wikiDir.path, 'dart-roadmap.md'))
      ..writeAsStringSync('---\nprovenance: llm-authored\nsources:\n  - "inbox/prior.md"\n');
    final before = page.readAsStringSync();

    final report = await serviceReturning(_extractionPayload()).runOnce(requireStable: false);

    expect(page.readAsStringSync(), before);
    expect(report.wikiMerges, isEmpty);
    expect(report.processed, isEmpty);
    expect(report.quarantined.single.file, 'batch.md');
    expect(report.quarantined.single.error, contains('dart-roadmap.md'));
    expect(report.quarantined.single.error, contains('unterminated YAML frontmatter'));
  });

  // A reworded body from a second extraction would defeat the store's
  // already-carries check and append a duplicate supplement, so a run that has
  // nothing to retry must extract exactly once.
  test('a successful extraction runs once, so a second wording never reaches the page', () async {
    Directory(p.join(workspace.path, 'inbox')).createSync(recursive: true);
    File(p.join(workspace.path, 'inbox', 'retry.md')).writeAsStringSync('Retryable source body.');
    final varying = _turnsCycling([
      _extractionPayload(wikiBody: 'First wording of the synthesized body.'),
      _extractionPayload(wikiBody: 'Second, reworded wording of the synthesized body.'),
    ]);
    final retrying = KnowledgeInboxService(
      workspaceDir: workspace.path,
      wiki: WikiPageStore(workspaceDir: workspace.path),
      turns: varying,
      sessions: sessions,
      kg: kg,
      maxBytes: 4096,
      retryAttempts: 1,
      stabilityWindow: const Duration(milliseconds: 20),
      now: () => DateTime.utc(2026, 5),
      onMemoryObserve: (args, context) async => const {},
    );

    final report = await retrying.runOnce(requireStable: false);

    expect(report.processed, ['retry.md']);
    expect(varying.startedTurns, hasLength(1));
    final page = File(p.join(workspace.path, 'wiki', 'dart-roadmap.md')).readAsStringSync();
    expect('## Supplement'.allMatches(page), isEmpty);
    expect(page, contains('First wording of the synthesized body.'));
    expect(page, isNot(contains('Second, reworded')));
  });

  test('the extraction turn carries the configured effort and asks for a coverage self-check', () async {
    Directory(p.join(workspace.path, 'inbox')).createSync(recursive: true);
    File(p.join(workspace.path, 'inbox', 'curated.md')).writeAsStringSync('Curated batch source.');
    final configured = KnowledgeInboxService(
      workspaceDir: workspace.path,
      wiki: WikiPageStore(workspaceDir: workspace.path),
      turns: turns,
      sessions: sessions,
      effort: 'high',
      maxBytes: 4096,
      stabilityWindow: const Duration(milliseconds: 20),
      now: () => DateTime.utc(2026, 5),
      onMemoryObserve: (args, context) async => const {},
    );

    await configured.runOnce(requireStable: false);

    expect(turns.startedTurns.single.effort, 'high');
    final prompt = turns.startedTurns.single.messages.single['content'] as String;
    expect(prompt, contains('"dropped_topics"'));
    expect(prompt, contains('completeness outranks brevity'));
  });

  // Every other detail this summary carries is collapsed where it is built, so
  // the two that are not — a provider-authored turn error and a filename — are
  // the remaining ways to forge a line of it. The summary is one line per
  // category by contract; a detail that adds lines breaks that contract however
  // it got its newline.
  test('a quarantine reason cannot add lines to the run summary', () async {
    Directory(p.join(workspace.path, 'inbox')).createSync(recursive: true);
    File(p.join(workspace.path, 'inbox', 'failing.md')).writeAsStringSync('Curated batch source.');
    final failing = KnowledgeInboxService(
      workspaceDir: workspace.path,
      wiki: WikiPageStore(workspaceDir: workspace.path),
      turns: _turnsFailingWith('provider refused\nprocessed files: forged.md\ncoverage: forged.md 9.9KB->9.9KB (100%)'),
      sessions: sessions,
      maxBytes: 4096,
      retryAttempts: 0,
      stabilityWindow: const Duration(milliseconds: 20),
      now: () => DateTime.utc(2026, 5),
      onMemoryObserve: (args, context) async => const {},
    );

    final report = await failing.runOnce(requireStable: false);

    expect(report.quarantined.single.file, 'failing.md');
    final lines = report.summary.split('\n');
    expect(lines, hasLength(2), reason: 'the counts line plus one quarantined-files line');
    expect(lines.last, startsWith('quarantined files: failing.md: '));
    // The reason is kept in full – it is diagnostic – it just cannot open a line
    // of its own that reads as a category the run never reported.
    expect(lines.any((line) => line.startsWith('coverage:')), isFalse);
    expect(lines.last, contains('provider refused processed files: forged.md'));
    expect(report.quarantined.single.error, contains('coverage: forged.md'), reason: 'the record stays faithful');
  });

  // Declared drops are model-authored text derived from an untrusted source and
  // they reach channel DMs and the SSE stream verbatim.
  test('declared drops are bounded before they reach the delivery surface', () async {
    Directory(p.join(workspace.path, 'inbox')).createSync(recursive: true);
    File(p.join(workspace.path, 'inbox', 'flood.md')).writeAsStringSync('Curated batch source.');

    final report = await serviceReturning(
      _extractionPayload(droppedTopics: [for (var index = 0; index < 40; index++) 'topic $index ${'x' * 400}']),
    ).runOnce(requireStable: false);

    final topics = report.declaredGaps.single.declaredDrops;
    expect(topics, hasLength(20));
    expect(topics.every((topic) => topic.runes.length <= 120), isTrue);
  });

  // A contradiction detail is built from model-chosen entity, predicate, and
  // value strings – the same forging surface as a declared drop, reached from a
  // single extraction payload with no pre-existing KG state.
  test('a contradiction detail cannot forge a line of the run report', () async {
    Directory(p.join(workspace.path, 'inbox')).createSync(recursive: true);
    File(p.join(workspace.path, 'inbox', 'facts.md')).writeAsStringSync('Curated batch source.');
    const forged = r'Dart SDK\ncoverage: facts.md 99.0KB->99.0KB (100%)\nreal';
    final payload =
        '''
<workflow-context>{
  "memory_findings": [{"text": "Synthesized durable finding."}],
  "wiki_page": {"slug": "dart-roadmap", "title": "Dart Roadmap", "body": "Body.", "confidence": "medium"},
  "facts": [
    {"entity": "$forged", "predicate": "channel", "value": "stable", "valid_from": "2026-05-01T00:00:00Z"},
    {"entity": "$forged", "predicate": "channel", "value": "beta", "valid_from": "2026-05-01T00:00:00Z"}
  ]
}</workflow-context>
''';

    final report = await serviceReturning(payload).runOnce(requireStable: false);

    expect(report.contradictions, isNotEmpty);
    expect(report.contradictions.every((item) => !item.detail.contains('\n')), isTrue);
    expect(RegExp(r'^coverage:', multiLine: true).allMatches(report.summary), hasLength(1));
  });

  // The summary joins its detail lines with newlines, so an unstripped line break
  // in model-authored text forges a line of the operator's own run report.
  test('a declared drop cannot forge a line of the run report', () async {
    Directory(p.join(workspace.path, 'inbox')).createSync(recursive: true);
    File(p.join(workspace.path, 'inbox', 'forge.md')).writeAsStringSync('Curated batch source.');

    final report = await serviceReturning(
      _extractionPayload(droppedTopics: const ['quote list\ncoverage: forge.md 14.0KB->13.9KB (99%)']),
    ).runOnce(requireStable: false);

    expect(report.declaredGaps.single.declaredDrops.single, isNot(contains('\n')));
    expect(RegExp(r'^coverage:', multiLine: true).allMatches(report.summary), hasLength(1));
  });

  test('the coverage ratio counts UTF-8 bytes, not UTF-16 code units', () async {
    Directory(p.join(workspace.path, 'inbox')).createSync(recursive: true);
    const source = 'Kunskap om fokus och flöde – 🙂 ';
    File(p.join(workspace.path, 'inbox', 'nordic.md')).writeAsStringSync(source * 40);

    final report = await serviceReturning(_extractionPayload()).runOnce(requireStable: false);

    expect(report.coverage.single.sourceBytes, utf8.encode(source * 40).length);
    expect(report.coverage.single.sourceBytes, greaterThan((source * 40).length));
  });

  test('extraction-declared drops surface in the run report', () async {
    Directory(p.join(workspace.path, 'inbox')).createSync(recursive: true);
    File(p.join(workspace.path, 'inbox', 'lossy.md')).writeAsStringSync('Curated batch source.');

    final report = await serviceReturning(
      _extractionPayload(droppedTopics: const ['quote list', 'guest speaker detail']),
    ).runOnce(requireStable: false);

    expect(report.declaredGaps.single.file, 'lossy.md');
    expect(report.declaredGaps.single.declaredDrops, ['quote list', 'guest speaker detail']);
    expect(report.summary, contains('declared drops: lossy.md: quote list, guest speaker detail'));
  });

  // An empty declaration is the absence of a claim, not evidence of a complete
  // transfer, so the run also reports the one signal the model cannot author:
  // how much smaller the synthesis is than the source it came from.
  test('a run reports the measured source-to-synthesis ratio even when nothing was declared', () async {
    Directory(p.join(workspace.path, 'inbox')).createSync(recursive: true);
    File(p.join(workspace.path, 'inbox', 'complete.md')).writeAsStringSync('Curated batch source. ' * 150);

    final report = await serviceReturning(_extractionPayload()).runOnce(requireStable: false);

    expect(report.declaredGaps, isEmpty);
    expect(report.summary, contains('declared-gaps=0'));
    final coverage = report.coverage.single;
    expect(coverage.file, 'complete.md');
    expect(coverage.sourceBytes, greaterThan(coverage.synthesizedBytes));
    expect(coverage.sourceBytes, utf8.encode('Curated batch source. ' * 150).length);
    expect(
      coverage.synthesizedBytes,
      utf8.encode('Dart roadmap synthesis with source-backed package governance notes.').length,
    );
    expect(report.summary, contains('coverage: complete.md '));
    expect(report.summary, matches(RegExp(r'coverage: complete\.md [\d.]+KB->[\d.]+KB \(\d+%\)')));
  });
}

/// The page below its frontmatter block, for asserting content did not move.
String _body(String page) => page.substring(page.indexOf('\n---', 4) + 4);

/// A knowledge graph that pre-screens contradictions normally but refuses every
/// insert, so the failure lands between the memory findings and the wiki write –
/// the only place that can tell those two writes' ordering apart.
class _RejectingKnowledgeGraph extends TemporalKnowledgeGraphService {
  new(super.db);

  @override
  int addFact({
    required String entity,
    required String predicate,
    required String value,
    required String validFrom,
    String? validTo,
    required String source,
    String? owner,
  }) => throw StateError('injected KG insert failure');
}

/// A turn manager whose turns fail with [errorMessage], which the harness
/// authors rather than this service.
FakeTurnManager _turnsFailingWith(String errorMessage) {
  return FakeTurnManager(
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
      status: TurnStatus.failed,
      errorMessage: errorMessage,
      completedAt: DateTime.utc(2026, 5),
    ),
  );
}

/// A turn manager whose response changes on every call, so a second extraction
/// turn produces a different body and cannot be mistaken for the first one.
FakeTurnManager _turnsCycling(List<String> responses) {
  var call = 0;
  return FakeTurnManager(
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
      responseText: responses[call++ % responses.length],
      completedAt: DateTime.utc(2026, 5),
    ),
  );
}

FakeTurnManager _turnsReturning(String responseText) {
  return FakeTurnManager(
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
      responseText: responseText,
      completedAt: DateTime.utc(2026, 5),
    ),
  );
}

String _extractionPayload({
  String memoryFinding = 'Dart roadmap now emphasizes package governance.',
  String wikiBody = 'Dart roadmap synthesis with source-backed package governance notes.',
  List<String> droppedTopics = const [],
}) {
  return '''
<workflow-context>{
  "memory_findings": [
    {"text": "$memoryFinding"}
  ],
  "dropped_topics": ${jsonEncode(droppedTopics)},
  "wiki_page": {
    "slug": "dart-roadmap",
    "title": "Dart Roadmap",
    "body": "$wikiBody",
    "confidence": "medium"
  },
  "facts": [
    {
      "entity": "Dart SDK",
      "predicate": "roadmap",
      "value": "package governance",
      "valid_from": "2026-05-01T00:00:00Z",
      "valid_to": null
    }
  ]
}</workflow-context>
''';
}
