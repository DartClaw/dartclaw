import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_storage/dartclaw_storage.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'search_test_support.dart';

/// Fake search backend that records calls and returns canned results.
class FakeFts5Backend implements SearchBackend {
  final List<String> searchCalls = [];
  List<MemorySearchResult> nextResults = [];

  @override
  Future<List<MemorySearchResult>> search(String query, {int limit = 10, String userId = 'owner'}) async {
    searchCalls.add(query);
    return nextResults;
  }

  @override
  Future<void> indexAfterWrite() async {}
}

void main() {
  group('QmdSearchBackend', () {
    test('delegates to QMD when running', () async {
      final fts5 = FakeFts5Backend();
      final qmd = FakeQmdManager();
      qmd.nextQueryResult = [
        {'text': 'Result from QMD', 'source': 'memory.md', 'score': 0.95},
      ];

      final backend = QmdSearchBackend(manager: qmd, fallback: fts5);
      final results = await backend.search('dart async');

      expect(results, hasLength(1));
      expect(results.first.text, 'Result from QMD');
      expect(fts5.searchCalls, isEmpty);
    });

    test('falls back to FTS5 when QMD not running', () async {
      final fts5 = FakeFts5Backend();
      fts5.nextResults = [const MemorySearchResult(text: 'FTS5 result', source: 'memory', score: -1.0)];
      final qmd = FakeQmdManager(fakeRunning: false);

      final backend = QmdSearchBackend(manager: qmd, fallback: fts5);
      final results = await backend.search('test query');

      expect(results, hasLength(1));
      expect(results.first.text, 'FTS5 result');
      expect(fts5.searchCalls, contains('test query'));
    });

    test('falls back to FTS5 on QMD error', () async {
      final fts5 = FakeFts5Backend();
      fts5.nextResults = [const MemorySearchResult(text: 'Fallback', source: 'memory', score: -0.5)];
      final qmd = FakeQmdManager();
      qmd.shouldThrow = true;

      final backend = QmdSearchBackend(manager: qmd, fallback: fts5);
      final results = await backend.search('test');

      expect(results, hasLength(1));
      expect(results.first.text, 'Fallback');
    });

    test('indexAfterWrite delegates to QMD manager', () async {
      final fts5 = FakeFts5Backend();
      final qmd = FakeQmdManager();
      final backend = QmdSearchBackend(manager: qmd, fallback: fts5);

      // Should not throw
      await backend.indexAfterWrite();
    });

    test('wiki outranks raw QMD rows and higher-relevance raw rows sort first', () async {
      final workspace = Directory.systemTemp.createTempSync('dartclaw_qmd_wiki_rank_');
      addTearDown(() => workspace.deleteSync(recursive: true));
      Directory(p.join(workspace.path, 'wiki')).createSync(recursive: true);
      File(p.join(workspace.path, 'wiki', 'dart-async.md')).writeAsStringSync('''
---
provenance: llm-authored
sources:
  - "inbox/dart.md"
confidence: medium
last_updated: 2026-05-01T00:00:00.000Z
last_updated_by: "test"
contradicts: []
related: []
---
# Dart Async

Dart async programming synthesized from source.
''');

      final fts5 = FakeFts5Backend();
      final qmd = FakeQmdManager();
      // QMD relevance is higher-is-better; the more relevant row must rank first.
      qmd.nextQueryResult = [
        {'text': 'Less relevant raw', 'source': 'm-low.md', 'score': 0.5},
        {'text': 'More relevant raw', 'source': 'm-high.md', 'score': 0.9},
      ];

      final backend = QmdSearchBackend(
        manager: qmd,
        fallback: fts5,
        wikiSearch: WikiSearchSource(workspaceDir: workspace.path),
      );
      final results = await backend.search('dart async');

      expect(results.map((r) => r.text).toList(), [
        contains('Dart async programming synthesized'),
        'More relevant raw',
        'Less relevant raw',
      ]);
    });

    test('search depth options', () {
      expect(SearchDepth.fromString('fast'), SearchDepth.fast);
      expect(SearchDepth.fromString('standard'), SearchDepth.standard);
      expect(SearchDepth.fromString('deep'), SearchDepth.deep);
      expect(SearchDepth.fromString('unknown'), SearchDepth.standard);
    });
  });
}
