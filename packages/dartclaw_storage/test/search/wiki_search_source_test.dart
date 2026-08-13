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
