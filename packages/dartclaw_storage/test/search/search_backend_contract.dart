import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

/// Shared behavioral tests for any [SearchBackend] implementation.
/// [name] is the backend name for test group labels.
/// [createBackend] factory creates a fresh backend instance.
/// [indexContent] inserts searchable content into the backend's storage.
void searchBackendContractTests({
  required String name,
  required SearchBackend Function() createBackend,
  required Future<void> Function(String text, String source) indexContent,
}) {
  late SearchBackend backend;

  setUp(() {
    backend = createBackend();
  });

  group('$name contract', () {
    test('index then search finds content', () async {
      await indexContent('Dart is a client-optimized language', 'doc1.md');
      await backend.indexAfterWrite();
      final results = await backend.search('Dart');
      expect(results, isNotEmpty);
      expect(results.first.text, contains('Dart'));
    });

    test('search returns empty for no match', () async {
      await indexContent('Dart programming language', 'doc1.md');
      await backend.indexAfterWrite();
      final results = await backend.search('xyznonexistent');
      expect(results, isEmpty);
    });

    test('empty query returns empty or throws gracefully', () async {
      await indexContent('Some content', 'doc1.md');
      await backend.indexAfterWrite();
      // FTS5 MATCH throws on empty string; QMD mock returns [].
      // Either behavior is acceptable — the backend must not crash unexpectedly.
      try {
        final results = await backend.search('');
        expect(results, isEmpty);
      } on Exception {
        // Acceptable — FTS5 throws SqliteException for empty MATCH
      }
    });

    test('multiple results returned with scores', () async {
      await indexContent('Dart async programming guide', 'guide.md');
      await indexContent('Dart streams and futures', 'streams.md');
      await indexContent('Python web development', 'python.md');
      await backend.indexAfterWrite();
      final results = await backend.search('Dart');
      expect(results.length, greaterThanOrEqualTo(2));
      for (final r in results) {
        expect(r.text, contains('Dart'));
        expect(r.source, isNotEmpty);
      }
    });

    test('limit parameter respected', () async {
      for (var i = 0; i < 5; i++) {
        await indexContent('Dart content number $i', 'doc$i.md');
      }
      await backend.indexAfterWrite();
      final results = await backend.search('Dart', limit: 2);
      expect(results.length, lessThanOrEqualTo(2));
    });

    test('special characters in query do not crash', () async {
      await indexContent('Test content', 'doc.md');
      await backend.indexAfterWrite();
      // FTS5 MATCH has special syntax — may throw on invalid queries.
      // The contract requires no unhandled crash; throwing is acceptable.
      try {
        final results = await backend.search('test & "special" <chars>');
        expect(results, isA<List<MemorySearchResult>>());
      } on Exception {
        // Acceptable — backend-specific syntax errors
      }
    });

    test('indexAfterWrite completes without error', () async {
      await backend.indexAfterWrite();
    });
  });
}
