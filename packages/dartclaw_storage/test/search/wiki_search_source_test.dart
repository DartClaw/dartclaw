import 'dart:io';

import 'package:dartclaw_storage/dartclaw_storage.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

class _FakeQmdManager extends QmdManager {
  List<Map<String, dynamic>> nextQueryResult = [];

  _FakeQmdManager() : super(commandRunner: (exe, args, {workingDirectory}) async => ProcessResult(0, 0, '', ''));

  @override
  bool get isRunning => true;

  @override
  Future<List<Map<String, dynamic>>> query(String queryText, {String depth = 'standard', int limit = 10}) async {
    return nextQueryResult;
  }

  @override
  Future<void> triggerIndex() async {}
}

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
    memory.insertChunk(text: 'Dart macros and pattern matching raw note.', source: 'MEMORY.md', category: 'general');
  });

  tearDown(() {
    db.close();
    if (workspace.existsSync()) workspace.deleteSync(recursive: true);
  });

  test('S05 FTS5 wiki result outranks raw memory and is labeled synthesized knowledge', () async {
    final backend = Fts5SearchBackend(
      memoryService: memory,
      wikiSearch: WikiSearchSource(workspaceDir: workspace.path),
    );

    final results = await backend.search('Dart macros', limit: 5);

    expect(results, hasLength(2));
    expect(results.first.source, 'wiki/dart.md');
    expect(results.first.category, 'synthesized knowledge');
  });

  test('S05 QMD wiki result outranks raw memory while backend stays selected', () async {
    final qmd = _FakeQmdManager();
    qmd.nextQueryResult = [
      {'text': 'Dart macros and pattern matching raw qmd note.', 'source': 'MEMORY.md', 'score': 0.95},
    ];
    final backend = QmdSearchBackend(
      manager: qmd,
      fallback: Fts5SearchBackend(memoryService: memory),
      wikiSearch: WikiSearchSource(workspaceDir: workspace.path),
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
    final backend = Fts5SearchBackend(
      memoryService: memory,
      wikiSearch: WikiSearchSource(workspaceDir: workspace.path),
    );

    final results = await backend.search('Dart macros', limit: 5);

    expect(results.first.source, 'wiki/dart.md');
    expect(results.first.category, 'untrusted synthesized knowledge');
  });
}
