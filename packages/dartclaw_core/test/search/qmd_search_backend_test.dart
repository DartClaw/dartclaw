import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

/// Fake search backend that records calls and returns canned results.
class FakeFts5Backend implements SearchBackend {
  final List<String> searchCalls = [];
  List<MemorySearchResult> nextResults = [];

  @override
  Future<List<MemorySearchResult>> search(
    String query, {
    int limit = 10,
    String userId = 'owner',
  }) async {
    searchCalls.add(query);
    return nextResults;
  }

  @override
  Future<void> indexAfterWrite() async {}
}

/// Fake QMD manager that simulates running/not-running states.
class FakeQmdManager extends QmdManager {
  bool fakeRunning;
  List<Map<String, dynamic>>? nextQueryResult;
  bool shouldThrow = false;

  FakeQmdManager({this.fakeRunning = true})
      : super(commandRunner: (exe, args, {workingDirectory}) async {
          return ProcessResult(0, 0, '', '');
        });

  @override
  bool get isRunning => fakeRunning;

  @override
  Future<List<Map<String, dynamic>>> query(
    String queryText, {
    String depth = 'standard',
    int limit = 10,
  }) async {
    if (shouldThrow) throw Exception('QMD unreachable');
    return nextQueryResult ?? [];
  }

  @override
  Future<void> triggerIndex() async {
    if (shouldThrow) throw Exception('Index failed');
  }
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
      fts5.nextResults = [
        const MemorySearchResult(text: 'FTS5 result', source: 'memory', score: -1.0),
      ];
      final qmd = FakeQmdManager(fakeRunning: false);

      final backend = QmdSearchBackend(manager: qmd, fallback: fts5);
      final results = await backend.search('test query');

      expect(results, hasLength(1));
      expect(results.first.text, 'FTS5 result');
      expect(fts5.searchCalls, contains('test query'));
    });

    test('falls back to FTS5 on QMD error', () async {
      final fts5 = FakeFts5Backend();
      fts5.nextResults = [
        const MemorySearchResult(text: 'Fallback', source: 'memory', score: -0.5),
      ];
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

    test('search depth options', () {
      expect(SearchDepth.fromString('fast'), SearchDepth.fast);
      expect(SearchDepth.fromString('standard'), SearchDepth.standard);
      expect(SearchDepth.fromString('deep'), SearchDepth.deep);
      expect(SearchDepth.fromString('unknown'), SearchDepth.standard);
    });
  });
}
