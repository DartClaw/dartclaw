import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

void main() {
  group('parseMemoryEntries', () {
    test('parses basic entries with timestamps', () {
      final entries = parseMemoryEntries('''
## general
- [2026-01-15 08:30] First entry
- [2026-01-16 09:00] Second entry
''');

      expect(entries, hasLength(2));
      expect(entries[0].rawText, 'First entry');
      expect(entries[0].category, 'general');
      expect(entries[0].timestamp, DateTime(2026, 1, 15, 8, 30));
      expect(entries[1].rawText, 'Second entry');
    });

    test('handles multiple categories', () {
      final entries = parseMemoryEntries('''
## general
- [2026-01-01 10:00] General note
## debugging
- [2026-01-02 10:00] Debug note
''');

      expect(entries, hasLength(2));
      expect(entries[0].category, 'general');
      expect(entries[1].category, 'debugging');
    });

    test('handles undated entries', () {
      final entries = parseMemoryEntries('''
## general
- [2026-01-01 10:00] Dated entry
- [some tag] Undated entry
''');

      expect(entries, hasLength(2));
      expect(entries[0].timestamp, isNotNull);
      expect(entries[1].timestamp, isNull);
    });

    test('handles continuation lines', () {
      final entries = parseMemoryEntries('''
## general
- [2026-01-01 10:00] Multi
  line entry
  with more
''');

      expect(entries, hasLength(1));
      expect(entries[0].rawText, contains('Multi'));
      expect(entries[0].rawText, contains('line entry'));
    });

    test('returns empty for empty/blank content', () {
      expect(parseMemoryEntries(''), isEmpty);
      expect(parseMemoryEntries('   '), isEmpty);
    });

    test('preserves rawBlock', () {
      final entries = parseMemoryEntries('''
## general
- [2026-01-01 10:00] Test entry
''');

      expect(entries, hasLength(1));
      expect(entries[0].rawBlock, startsWith('- [2026-01-01 10:00]'));
    });
  });

  group('memoryTimestampRe', () {
    test('matches valid timestamp lines', () {
      expect(memoryTimestampRe.hasMatch('- [2026-01-15 08:30] Text'), isTrue);
    });

    test('does not match non-timestamp lines', () {
      expect(memoryTimestampRe.hasMatch('- [some tag] Text'), isFalse);
    });
  });
}
