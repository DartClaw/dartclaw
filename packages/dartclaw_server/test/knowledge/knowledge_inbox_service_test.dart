import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:dartclaw_storage/dartclaw_storage.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' show FakeTurnManager, SessionService, TurnOutcome, TurnStatus;
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  late Directory workspace;
  late List<Map<String, dynamic>> saved;
  late KnowledgeInboxService service;
  late SessionService sessions;
  late FakeTurnManager turns;
  late Database kgDb;
  late TemporalKnowledgeGraphService kg;

  setUp(() {
    workspace = Directory.systemTemp.createTempSync('dartclaw_knowledge_inbox_service_test_');
    saved = <Map<String, dynamic>>[];
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
      onMemorySave: (args) async {
        saved.add(args);
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
    File(
      p.join(workspace.path, 'inbox', 'dart-roadmap.md'),
    ).writeAsStringSync('Dart roadmap notes. Verbatim source sentence that must not be stored.');

    final report = await service.runOnce(requireStable: false);

    expect(report.processed, ['dart-roadmap.md']);
    expect(turns.startTurnCallCount, 1);
    expect(turns.startedTurns.single.source, 'cron');
    expect(turns.startedTurns.single.agentName, 'cron:knowledge-inbox');
    expect(turns.startedTurns.single.effort, 'low');
    expect(turns.startedTurns.single.maxTurns, 1);
    expect(turns.startedTurns.single.allowedTools, ['__knowledge_inbox_no_tools__']);
    expect(turns.startedTurns.single.readOnly, isTrue);
    expect(turns.taskToolFilterChanges, isEmpty);
    expect(turns.taskReadOnlyChanges, isEmpty);
    expect(saved.single['text'], contains('Synthesized inbox finding from inbox/dart-roadmap.md'));
    expect(saved.single['text'], contains('Dart roadmap now emphasizes package governance'));
    expect(saved.single['text'], isNot(contains('Verbatim source sentence that must not be stored')));
    expect(File(p.join(workspace.path, 'processed', 'dart-roadmap.md')).existsSync(), isTrue);
    final wiki = File(p.join(workspace.path, 'wiki', 'dart-roadmap.md')).readAsStringSync();
    expect(wiki, contains('provenance: llm-authored'));
    expect(wiki, contains('sources:'));
    expect(wiki, contains('last_updated_by: "cron:knowledge-inbox"'));
    expect(kg.query(entity: 'Dart SDK', predicate: 'roadmap').single.source, 'inbox/dart-roadmap.md');
    expect(report.summary, contains('processed files: dart-roadmap.md'));
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
    final cronKeys = (await sessions.listSessions(
      type: SessionType.cron,
    )).map((session) => Uri.decodeComponent(SessionKey.parse(session.channelKey!).identifiers)).toList();
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
      onMemorySave: (args) async {
        saved.add(args);
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
      onMemorySave: (args) async {
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

  test('S07 wiki lint reports categorized provenance and link findings without mutating pages', () {
    final wiki = WikiPageStore(workspaceDir: workspace.path)..bootstrap();
    final page = File(p.join(workspace.path, 'wiki', 'broken.md'))
      ..writeAsStringSync('# Broken\n\n[Missing](missing.md)\n');
    final before = page.readAsStringSync();

    final report = wiki.lint();

    expect(report.provenanceInconsistencies.join('\n'), contains('broken.md: missing YAML frontmatter'));
    expect(report.summary(), contains('provenance-inconsistency=1 [broken.md: missing YAML frontmatter]'));
    expect(page.readAsStringSync(), before);
  });

  test('wiki writes constrain model-controlled slug and confidence frontmatter', () async {
    final wiki = WikiPageStore(workspaceDir: workspace.path);

    await wiki.writePage(
      slug: '../USER',
      title: 'Escaped',
      body: 'Safe body.',
      sources: const ['inbox/escaped.md'],
      lastUpdatedBy: 'test',
      now: DateTime.utc(2026, 5),
    );

    expect(File(p.join(workspace.path, 'USER.md')).readAsStringSync(), contains('Not Relevant'));
    expect(File(p.join(workspace.path, 'wiki', 'user.md')).existsSync(), isTrue);
    await expectLater(
      () => wiki.writePage(
        slug: 'bad-confidence',
        title: 'Bad Confidence',
        body: 'Body.',
        sources: const ['inbox/bad.md'],
        lastUpdatedBy: 'test',
        now: DateTime.utc(2026, 5),
        confidence: 'certain\nlast_updated_by: attacker',
      ),
      throwsArgumentError,
    );

    File(p.join(workspace.path, 'wiki', 'invalid-confidence.md')).writeAsStringSync('''
---
provenance: llm-authored
sources:
  - "inbox/source.md"
confidence: certain
last_updated: 2026-05-01T00:00:00.000Z
last_updated_by: "test"
contradicts: []
related: []
---
# Invalid
''');

    expect(wiki.lint().provenanceInconsistencies, contains('invalid-confidence.md: invalid confidence'));
  });

  test('S06 wiki bootstrap emits provenance frontmatter', () {
    final wiki = WikiPageStore(workspaceDir: workspace.path)..bootstrap();

    final readme = File(p.join(wiki.wikiDir.path, 'README.md')).readAsStringSync();

    expect(readme, startsWith('---\nprovenance: human-authored'));
    expect(readme, contains('sources:\n  - "workspace-bootstrap"'));
    expect(wiki.lint().provenanceInconsistencies, isEmpty);
  });

  test('S07 wiki lint includes KG contradiction pre-screen category', () {
    final db = sqlite3.openInMemory();
    addTearDown(db.close);
    final kg = TemporalKnowledgeGraphService(db);
    kg.addFact(
      entity: 'Dart SDK',
      predicate: 'channel',
      value: 'stable',
      validFrom: '2026-05-01T00:00:00Z',
      source: 'wiki/dart.md',
    );
    kg.addFact(
      entity: 'Dart SDK',
      predicate: 'channel',
      value: 'beta',
      validFrom: '2026-05-02T00:00:00Z',
      source: 'inbox/dart.md',
    );

    final report = WikiPageStore(workspaceDir: workspace.path).lint(kg: kg);

    expect(report.contradictions.single, contains('dart sdk.channel'));
  });

  KnowledgeInboxService serviceReturning(String responseText, {TemporalKnowledgeGraphService? graph}) {
    return KnowledgeInboxService(
      workspaceDir: workspace.path,
      wiki: WikiPageStore(workspaceDir: workspace.path),
      turns: _turnsReturning(responseText),
      sessions: sessions,
      kg: graph ?? kg,
      maxBytes: 4096,
      retryAttempts: 1,
      stabilityWindow: const Duration(milliseconds: 20),
      now: () => DateTime.utc(2026, 5),
      onMemorySave: (args) async {
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

  test('S07 wiki lint reports stale pages from last_updated frontmatter', () async {
    final wiki = WikiPageStore(workspaceDir: workspace.path);
    await wiki.writePage(
      slug: 'old',
      title: 'Old',
      body: 'Old knowledge.',
      sources: const ['inbox/old.md'],
      lastUpdatedBy: 'test',
      now: DateTime.utc(2026, 3),
    );

    final report = wiki.lint(now: DateTime.utc(2026, 5), staleAfterDays: 30);

    expect(report.stalePages, contains('old.md'));
  });
}

FakeTurnManager _turnsReturning(String responseText) {
  return FakeTurnManager(
    onStartTurn:
        (
          sessionId,
          messages, {
          source,
          agentName = 'main',
          model,
          effort,
          maxTurns,
          taskId,
          isHumanInput = false,
          allowedTools,
          readOnly = false,
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

String _extractionPayload({String memoryFinding = 'Dart roadmap now emphasizes package governance.'}) {
  return '''
<workflow-context>{
  "memory_findings": [
    {"text": "$memoryFinding"}
  ],
  "wiki_page": {
    "slug": "dart-roadmap",
    "title": "Dart Roadmap",
    "body": "Dart roadmap synthesis with source-backed package governance notes.",
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
