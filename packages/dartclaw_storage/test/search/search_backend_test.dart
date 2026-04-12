import 'dart:io';

import 'package:dartclaw_storage/dartclaw_storage.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'search_backend_contract.dart';

// ---------------------------------------------------------------------------
// MockQmdManager — in-memory content store with substring matching
// ---------------------------------------------------------------------------

class MockQmdManager extends QmdManager {
  final _content = <Map<String, dynamic>>[];
  bool fakeRunning = true;

  MockQmdManager()
    : super(
        commandRunner: (exe, args, {workingDirectory}) async {
          return ProcessResult(0, 0, '', '');
        },
      );

  void addContent(String text, String source) {
    _content.add({'text': text, 'source': source, 'score': 1.0});
  }

  @override
  bool get isRunning => fakeRunning;

  @override
  Future<List<Map<String, dynamic>>> query(String queryText, {String depth = 'standard', int limit = 10}) async {
    if (queryText.isEmpty) return [];
    final lower = queryText.toLowerCase();
    return _content.where((c) => (c['text'] as String).toLowerCase().contains(lower)).take(limit).toList();
  }

  @override
  Future<void> triggerIndex() async {}
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('Fts5SearchBackend', () {
    late Database db;
    late MemoryService memoryService;

    setUp(() {
      db = sqlite3.openInMemory();
      memoryService = MemoryService(db);
    });

    tearDown(() {
      db.close();
    });

    searchBackendContractTests(
      name: 'FTS5',
      createBackend: () => Fts5SearchBackend(memoryService: memoryService),
      indexContent: (text, source) async {
        memoryService.insertChunk(text: text, source: source);
      },
    );
  });

  group('QmdSearchBackend', () {
    late Database db;
    late MemoryService memoryService;
    late MockQmdManager mockQmd;

    setUp(() {
      db = sqlite3.openInMemory();
      memoryService = MemoryService(db);
      mockQmd = MockQmdManager();
    });

    tearDown(() {
      db.close();
    });

    searchBackendContractTests(
      name: 'QMD',
      createBackend: () => QmdSearchBackend(
        manager: mockQmd,
        fallback: Fts5SearchBackend(memoryService: memoryService),
      ),
      indexContent: (text, source) async {
        mockQmd.addContent(text, source);
        memoryService.insertChunk(text: text, source: source);
      },
    );
  });
}
