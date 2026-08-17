import 'dart:io';

import 'package:dartclaw_storage/dartclaw_storage.dart';
import 'package:dartclaw_core/dartclaw_core.dart' show MemoryResourceLimits, MemorySearchDegradation;
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'search_test_support.dart';

void main() {
  late Directory workspace;
  late Database db;
  late MemoryService memory;

  setUp(() {
    workspace = Directory.systemTemp.createTempSync('dartclaw_wiki_search_test_');
    db = sqlite3.openInMemory();
    memory = MemoryService(db);
    Directory(p.join(workspace.path, 'wiki')).createSync(recursive: true);
    File(p.join(workspace.path, 'wiki', 'dart.md')).writeAsStringSync('''
---
provenance: hybrid
sources:
  - "inbox/dart.md"
confidence: high
last_updated: 2026-05-01T00:00:00Z
last_updated_by: "cron:knowledge-inbox"
contradicts: []
related: []
---
# Dart

Dart macros and pattern matching roadmap synthesis.
''');
    db.execute('INSERT INTO memory_chunks (text, source, category, created_at, locator) VALUES (?, ?, ?, ?, ?)', [
      'Dart macros and pattern matching raw note.',
      'MEMORY.md',
      'general',
      DateTime(2026).toIso8601String(),
      'MEMORY.md',
    ]);
  });

  tearDown(() {
    db.close();
    if (workspace.existsSync()) workspace.deleteSync(recursive: true);
  });

  test('S05 FTS5 wiki result outranks raw memory and is labeled synthesized knowledge', () async {
    final backend = ComposedSearchBackend(
      personal: Fts5SearchBackend(memoryService: memory),
      wiki: WikiSearchSource(workspaceDir: workspace.path),
    );

    final results = await backend.search('Dart macros', limit: 5);

    expect(results, hasLength(2));
    expect(results.first.source, 'wiki/dart.md');
    expect(results.first.category, 'synthesized knowledge');
  });

  test('S05 QMD wiki result outranks raw memory while backend stays selected', () async {
    final qmd = FakeQmdManager();
    qmd.nextQueryResult = [
      {'text': 'Dart macros and pattern matching raw qmd note.', 'source': 'MEMORY.md', 'score': 0.95},
    ];
    final backend = ComposedSearchBackend(
      personal: QmdSearchBackend(
        manager: qmd,
        fallback: Fts5SearchBackend(memoryService: memory),
      ),
      wiki: WikiSearchSource(workspaceDir: workspace.path),
    );

    final results = await backend.search('Dart macros', limit: 5);

    expect(results.first.source, 'wiki/dart.md');
    expect(results.first.category, 'synthesized knowledge');
  });

  test('source-backed llm-authored wiki result is labeled untrusted but still outranks raw memory', () async {
    File(p.join(workspace.path, 'wiki', 'dart.md')).writeAsStringSync('''
---
provenance: llm-authored
sources:
  - "inbox/dart.md"
confidence: medium
last_updated: 2026-05-01T00:00:00Z
last_updated_by: "cron:knowledge-inbox"
contradicts: []
related: []
---
# Dart

Dart macros and pattern matching roadmap synthesis.
''');
    final backend = ComposedSearchBackend(
      personal: Fts5SearchBackend(memoryService: memory),
      wiki: WikiSearchSource(workspaceDir: workspace.path),
    );

    final results = await backend.search('Dart macros', limit: 5);

    expect(results.first.source, 'wiki/dart.md');
    expect(results.first.category, 'untrusted synthesized knowledge');
  });

  // The knowledge-inbox writer reads these page shapes correctly, so a reader
  // that binds to `---\n` and block-style `sources` demotes exactly the pages
  // the writer just declared healthy.
  test('a CRLF page is ranked on its frontmatter, not treated as having none', () async {
    File(p.join(workspace.path, 'wiki', 'dart.md')).writeAsStringSync(_page().replaceAll('\n', '\r\n'));
    final backend = ComposedSearchBackend(
      personal: Fts5SearchBackend(memoryService: memory),
      wiki: WikiSearchSource(workspaceDir: workspace.path),
    );

    final results = await backend.search('Dart macros', limit: 5);

    expect(results.first.source, 'wiki/dart.md');
    expect(results.first.provenance, 'human-authored');
    expect(results.first.category, 'synthesized knowledge');
    expect(results.first.text, isNot(contains('provenance:')));
  });

  test('a flow-style sources list still counts as source-backed', () async {
    File(p.join(workspace.path, 'wiki', 'dart.md'))
        .writeAsStringSync(_page(provenance: 'llm-authored', sources: 'sources: ["inbox/dart.md","inbox/more.md"]'));
    final backend = ComposedSearchBackend(
      personal: Fts5SearchBackend(memoryService: memory),
      wiki: WikiSearchSource(workspaceDir: workspace.path),
    );

    final results = await backend.search('Dart macros', limit: 5);

    expect(results.first.source, 'wiki/dart.md');
    expect(results.first.category, 'untrusted synthesized knowledge');
    expect(results.first.score, lessThan(0));
  });

  // Ranking a page source-backed on the strength of not understanding its
  // `sources` value is the reader-side form of trust laundering.
  for (final (label, sources) in const [
    ('a flow list of empty strings', 'sources: ["", ""]'),
    ('an explicitly null value', 'sources: null'),
    ('an empty list with a trailing comment', 'sources: [] # TODO'),
    ('a comment-only value', 'sources: # nothing yet'),
  ]) {
    test('$label is not treated as source-backed', () async {
      File(p.join(workspace.path, 'wiki', 'dart.md'))
          .writeAsStringSync(_page(provenance: 'llm-authored', sources: sources));
      final backend = ComposedSearchBackend(
        personal: Fts5SearchBackend(memoryService: memory),
        wiki: WikiSearchSource(workspaceDir: workspace.path),
      );

      final results = await backend.search('Dart macros', limit: 5);

      expect(results.singleWhere((item) => item.source == 'wiki/dart.md').score, greaterThan(0));
    });
  }

  test('an empty sources list is not treated as source-backed', () async {
    File(p.join(workspace.path, 'wiki', 'dart.md'))
        .writeAsStringSync(_page(provenance: 'llm-authored', sources: 'sources: []'));
    final backend = ComposedSearchBackend(
      personal: Fts5SearchBackend(memoryService: memory),
      wiki: WikiSearchSource(workspaceDir: workspace.path),
    );

    final results = await backend.search('Dart macros', limit: 5);

    expect(results.singleWhere((item) => item.source == 'wiki/dart.md').score, greaterThan(0));
  });

  test('wiki locator resolution rejects a symlinked parent directory', () async {
    final outside = Directory.systemTemp.createTempSync('dartclaw_wiki_outside_');
    addTearDown(() => outside.deleteSync(recursive: true));
    File(p.join(outside.path, 'secret.md')).writeAsStringSync('not workspace knowledge');
    Link(p.join(workspace.path, 'wiki', 'linked')).createSync(outside.path);

    final result = await WikiSearchSource(workspaceDir: workspace.path).resolve('wiki/linked/secret.md');

    expect(result, isNull);
  });

  test('wiki snippets truncate at Unicode scalar boundaries', () async {
    File(p.join(workspace.path, 'wiki', 'dart.md')).writeAsStringSync('${'x' * 239}🦀 trailing text');

    final result = (await WikiSearchSource(workspaceDir: workspace.path).list()).single;

    expect(result.text.runes, hasLength(240));
    expect(result.text, endsWith('🦀'));
  });

  // The snippet anchored a single 240-rune window at the first match, so on a
  // page that grows by appended supplements the oldest section won every query
  // and nothing appended since was visible from search.
  test('snippet shows the newest matching supplement as well as the oldest section', () async {
    final page = StringBuffer('# Falcon\n\nFalcon original synthesis about kestrel airframes.\n');
    for (var index = 1; index <= 40; index++) {
      page
        ..write('\n## Supplement from batch-$index.md (2026-06-01)\n\n')
        ..write('Falcon supplement number $index with enough filler to spread the sections apart.\n');
    }
    File(p.join(workspace.path, 'wiki', 'dart.md')).writeAsStringSync(page.toString());

    final result = (await WikiSearchSource(workspaceDir: workspace.path).searchScan('falcon')).results.single;

    expect(result.text, contains('original synthesis'));
    expect(result.text, contains('supplement number 40'));
    expect(result.text.runes.length, lessThanOrEqualTo(240));
  });

  test('a page whose matches sit inside one window keeps a single contiguous snippet', () async {
    final filler = 'word ' * 120;
    File(p.join(workspace.path, 'wiki', 'dart.md')).writeAsStringSync('${filler}falcon nest falcon $filler');

    final result = (await WikiSearchSource(workspaceDir: workspace.path).searchScan('falcon')).results.single;

    expect(result.text, contains('falcon nest falcon'));
    expect(result.text, isNot(contains('…')));
    expect(result.text.runes, hasLength(240));
  });

  test('wiki scan stops at the fixed file ceiling and reports degraded coverage', () async {
    File(p.join(workspace.path, 'wiki', 'dart.md')).deleteSync();
    for (var index = MemoryResourceLimits.recursiveFiles; index >= 0; index--) {
      File(p.join(workspace.path, 'wiki', '${index.toString().padLeft(4, '0')}.md')).writeAsStringSync('Falcon $index');
    }

    final scan = await WikiSearchSource(workspaceDir: workspace.path).searchScan('Falcon');

    expect(scan.processedFiles, MemoryResourceLimits.recursiveFiles);
    expect(scan.results, hasLength(MemoryResourceLimits.recursiveFiles));
    expect(scan.degraded, isTrue);
    expect(
      scan.degradations.single,
      isA<MemorySearchDegradation>()
          .having((item) => item.reason, 'reason', 'fileLimit')
          .having((item) => item.locator, 'locator', 'wiki/1000.md')
          .having((item) => item.observed, 'observed', MemoryResourceLimits.recursiveFiles + 1)
          .having((item) => item.limit, 'limit', MemoryResourceLimits.recursiveFiles)
          .having((item) => item.omittedCount, 'omittedCount', 1),
    );
  });

  test('malformed bodies consume the aggregate budget and preserve known failure context', () async {
    File(p.join(workspace.path, 'wiki', 'dart.md')).deleteSync();
    const partitionBytes = MemoryResourceLimits.recursiveBodyBytes ~/ 8;
    for (var index = 0; index < 8; index++) {
      final handle = File(p.join(workspace.path, 'wiki', '${index.toString().padLeft(4, '0')}.md'))
          .openSync(mode: FileMode.write);
      handle.writeByteSync(0xff);
      handle.truncateSync(partitionBytes);
      handle.closeSync();
    }
    File(p.join(workspace.path, 'wiki', '0008.md')).writeAsStringSync('Falcon after exhausted budget');

    final scan = await WikiSearchSource(workspaceDir: workspace.path).searchScan('Falcon');

    expect(scan.processedBytes, MemoryResourceLimits.recursiveBodyBytes);
    expect(scan.results, isEmpty);
    expect(scan.degradations.where((item) => item.reason == 'readFailure'), hasLength(8));
    expect(
      scan.degradations.first,
      isA<MemorySearchDegradation>()
          .having((item) => item.locator, 'locator', 'wiki/0000.md')
          .having((item) => item.observed, 'observed', partitionBytes)
          .having((item) => item.limit, 'limit', MemoryResourceLimits.recursiveBodyBytes),
    );
    expect(scan.degradations.last.reason, 'bodyBytes');
    expect(scan.degradations.last.locator, 'wiki/0008.md');
  });

  test('wiki list charges a malformed body before reporting its read failure', () async {
    File(p.join(workspace.path, 'wiki', 'dart.md')).writeAsBytesSync([0xff]);

    final scan = await WikiSearchSource(workspaceDir: workspace.path).listScan();

    expect(scan.processedBytes, 1);
    expect(scan.degradations.single.reason, 'readFailure');
    expect(scan.degradations.single.observed, 1);
    expect(scan.degradations.single.limit, MemoryResourceLimits.recursiveBodyBytes);
  });
}

String _page({String provenance = 'human-authored', String sources = 'sources:\n  - "inbox/dart.md"'}) =>
    '''
---
provenance: $provenance
$sources
confidence: high
last_updated: 2026-05-01T00:00:00Z
last_updated_by: "cron:knowledge-inbox"
contradicts: []
related: []
---
# Dart

Dart macros and pattern matching roadmap synthesis.
''';
