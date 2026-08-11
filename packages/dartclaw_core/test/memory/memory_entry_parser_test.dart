import 'package:dartclaw_core/dartclaw_core.dart' show parseMemoryEntries;
import 'package:dartclaw_core/src/memory/memory_entry_parser.dart' show memoryTimestampRe;
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

    test('preserves indentation beyond the continuation prefix', () {
      final entries = parseMemoryEntries(
        '## general\n'
        '- [2026-01-15 10:30] Nested structures\n'
        '  - child\n'
        '    - grandchild\n'
        '    code();\n',
      );

      expect(entries.single.rawText, 'Nested structures\n- child\n  - grandchild\n  code();');
    });

    test('returns empty for empty/blank content', () {
      expect(parseMemoryEntries(''), isEmpty);
      expect(parseMemoryEntries('   '), isEmpty);
    });

    test('preserves rawBlock', () {
      const content = '''
## general
- [2026-01-01 10:00] Test entry
  More detail
''';
      final entries = parseMemoryEntries(content);

      expect(entries, hasLength(1));
      expect(entries[0].rawBlock, startsWith('- [2026-01-01 10:00]'));
      expect(content.substring(entries[0].sourceStart!, entries[0].sourceEnd!), entries[0].rawBlock);
    });

    test('ignores timestamp-shaped examples inside fenced code blocks', () {
      final entries = parseMemoryEntries(
        '## examples\n'
        '```markdown\n'
        '- [2020-01-01 00:00] Example only\n'
        '```\n'
        '## general\n'
        '- [2026-01-01 10:00] Real entry\n',
      );

      expect(entries, hasLength(1));
      expect(entries.single.rawText, 'Real entry');
    });

    test('treats calendar-invalid timestamps as undated', () {
      for (final timestamp in ['2025-02-29 10:00', '2026-13-01 10:00', '2026-01-01 24:00', '2026-01-01 10:60']) {
        final entries = parseMemoryEntries('- [$timestamp] Preserve this entry\n');
        expect(entries.single.timestamp, isNull, reason: timestamp);
      }

      expect(parseMemoryEntries('- [2024-02-29 10:00] Valid leap day\n').single.timestamp, DateTime(2024, 2, 29, 10));
    });

    test('treats non-canonical timestamp suffixes as undated', () {
      for (final line in [
        '- [2020-01-01 00:00 UTC] Preserve this entry',
        '- [2020-01-01 00:00:30] Preserve this entry',
        '- [2020-01-01 00:00]] Preserve this entry',
      ]) {
        expect(parseMemoryEntries('$line\n').single.timestamp, isNull, reason: line);
      }
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
