import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late AuditLogReader reader;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('audit_reader_test_');
    reader = AuditLogReader(dataDir: tempDir.path);
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  AuditEntry makeEntry({
    String guard = 'InputSanitizer',
    String hook = 'pre_inbound',
    String verdict = 'pass',
    String? reason,
    String? sessionId,
    String? channel,
  }) {
    return AuditEntry(
      timestamp: DateTime.utc(2026, 3, 1, 12),
      guard: guard,
      hook: hook,
      verdict: verdict,
      reason: reason,
      sessionId: sessionId,
      channel: channel,
    );
  }

  void writeEntries(List<AuditEntry> entries) {
    final file = File('${tempDir.path}/audit.ndjson');
    final lines = entries.map((e) => jsonEncode(e.toJson())).join('\n');
    file.writeAsStringSync(lines);
  }

  group('AuditLogReader', () {
    test('returns empty page when file does not exist', () async {
      final page = await reader.read();
      expect(page.entries, isEmpty);
      expect(page.totalEntries, 0);
      expect(page.totalPages, 0);
      expect(page.currentPage, 1);
    });

    test('returns empty page for empty file', () async {
      File('${tempDir.path}/audit.ndjson').writeAsStringSync('');
      final page = await reader.read();
      expect(page.entries, isEmpty);
      expect(page.totalEntries, 0);
    });

    test('parses entries and returns newest first', () async {
      final entries = [
        AuditEntry(timestamp: DateTime.utc(2026, 3, 1, 10), guard: 'GuardA', hook: 'pre_inbound', verdict: 'pass'),
        AuditEntry(
          timestamp: DateTime.utc(2026, 3, 1, 11),
          guard: 'GuardB',
          hook: 'pre_inbound',
          verdict: 'block',
          reason: 'blocked',
        ),
        AuditEntry(timestamp: DateTime.utc(2026, 3, 1, 12), guard: 'GuardC', hook: 'post_outbound', verdict: 'warn'),
      ];
      writeEntries(entries);

      final page = await reader.read();
      expect(page.totalEntries, 3);
      expect(page.entries.length, 3);
      // Newest first (reversed order).
      expect(page.entries[0].guard, 'GuardC');
      expect(page.entries[1].guard, 'GuardB');
      expect(page.entries[2].guard, 'GuardA');
    });

    test('skips malformed lines gracefully', () async {
      final file = File('${tempDir.path}/audit.ndjson');
      final valid = jsonEncode(makeEntry().toJson());
      file.writeAsStringSync('$valid\nnot-json\n$valid\n');

      final page = await reader.read();
      expect(page.totalEntries, 2);
    });

    test('skips blank lines', () async {
      final file = File('${tempDir.path}/audit.ndjson');
      final valid = jsonEncode(makeEntry().toJson());
      file.writeAsStringSync('$valid\n\n  \n$valid\n');

      final page = await reader.read();
      expect(page.totalEntries, 2);
    });

    group('filtering', () {
      setUp(() {
        writeEntries([
          makeEntry(guard: 'InputSanitizer', verdict: 'pass'),
          makeEntry(guard: 'ContentClassifier', verdict: 'block', reason: 'toxic'),
          makeEntry(guard: 'InputSanitizer', verdict: 'warn', reason: 'suspicious'),
          makeEntry(guard: 'ContentClassifier', verdict: 'pass'),
          makeEntry(guard: 'MessageRedactor', verdict: 'warn', reason: 'pii'),
        ]);
      });

      test('filters by verdict', () async {
        final page = await reader.read(verdictFilter: 'pass');
        expect(page.totalEntries, 2);
        expect(page.entries.every((e) => e.verdict == 'pass'), isTrue);
      });

      test('filters by guard (case-insensitive substring)', () async {
        final page = await reader.read(guardFilter: 'content');
        expect(page.totalEntries, 2);
        expect(page.entries.every((e) => e.guard == 'ContentClassifier'), isTrue);
      });

      test('combines verdict and guard filters (AND)', () async {
        final page = await reader.read(verdictFilter: 'pass', guardFilter: 'content');
        expect(page.totalEntries, 1);
        expect(page.entries.first.guard, 'ContentClassifier');
        expect(page.entries.first.verdict, 'pass');
      });

      test('returns empty when no entries match filter', () async {
        final page = await reader.read(verdictFilter: 'block', guardFilter: 'Redactor');
        expect(page.totalEntries, 0);
        expect(page.entries, isEmpty);
      });
    });

    group('pagination', () {
      setUp(() {
        // Write 7 entries.
        writeEntries(List.generate(7, (i) => makeEntry(guard: 'Guard$i')));
      });

      test('returns first page with correct metadata', () async {
        final page = await reader.read(pageSize: 3);
        expect(page.entries.length, 3);
        expect(page.totalEntries, 7);
        expect(page.totalPages, 3);
        expect(page.currentPage, 1);
        expect(page.pageSize, 3);
      });

      test('returns middle page', () async {
        final page = await reader.read(page: 2, pageSize: 3);
        expect(page.entries.length, 3);
        expect(page.currentPage, 2);
      });

      test('returns partial last page', () async {
        final page = await reader.read(page: 3, pageSize: 3);
        expect(page.entries.length, 1);
        expect(page.currentPage, 3);
      });

      test('clamps page to valid range', () async {
        final page = await reader.read(page: 100, pageSize: 3);
        expect(page.currentPage, 3); // clamped to last page
        expect(page.entries.length, 1);
      });

      test('page 0 is clamped to 1', () async {
        final page = await reader.read(page: 0, pageSize: 3);
        expect(page.currentPage, 1);
        expect(page.entries.length, 3);
      });

      test('all entries fit in one page', () async {
        final page = await reader.read(pageSize: 25);
        expect(page.entries.length, 7);
        expect(page.totalPages, 1);
        expect(page.currentPage, 1);
      });
    });

    group('AuditPage.empty', () {
      test('has expected defaults', () {
        expect(AuditPage.empty.entries, isEmpty);
        expect(AuditPage.empty.totalEntries, 0);
        expect(AuditPage.empty.currentPage, 1);
        expect(AuditPage.empty.totalPages, 0);
        expect(AuditPage.empty.pageSize, 25);
      });
    });
  });
}
