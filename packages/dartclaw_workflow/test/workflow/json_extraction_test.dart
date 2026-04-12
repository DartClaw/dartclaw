import 'package:dartclaw_workflow/dartclaw_workflow.dart';
import 'package:test/test.dart';

void main() {
  group('extractJson', () {
    group('Strategy 1: raw parse', () {
      test('parses raw JSON object', () {
        final result = extractJson('{"pass": true}');
        expect(result, isA<Map<String, dynamic>>());
        expect((result as Map<String, dynamic>)['pass'], true);
      });

      test('parses raw JSON array', () {
        final result = extractJson('[{"id": "s01"}]');
        expect(result, isA<List<dynamic>>());
        expect((result as List<dynamic>).length, 1);
      });

      test('parses raw JSON with surrounding whitespace', () {
        final result = extractJson('  {"key": "value"}  ');
        expect((result as Map)['key'], 'value');
      });

      test('rejects scalar JSON (number)', () {
        // A bare number is valid JSON but not Map or List — should fall through
        // to next strategies and ultimately fail.
        expect(() => extractJson('42'), throwsA(isA<FormatException>()));
      });

      test('rejects scalar JSON (string)', () {
        expect(() => extractJson('"just a string"'), throwsA(isA<FormatException>()));
      });
    });

    group('Strategy 2: json-fenced blocks', () {
      test('extracts json-fenced block', () {
        const raw = 'Some text\n```json\n{"pass": true}\n```\nMore text';
        final result = extractJson(raw);
        expect(result, isA<Map<String, dynamic>>());
        expect((result as Map<String, dynamic>)['pass'], true);
      });

      test('extracts json-fenced array', () {
        const raw = '```json\n[1, 2, 3]\n```';
        final result = extractJson(raw);
        expect(result, isA<List<dynamic>>());
        expect((result as List<dynamic>), [1, 2, 3]);
      });

      test('handles json fence with extra whitespace', () {
        const raw = '```json\n  {"key": "value"}  \n```';
        final result = extractJson(raw);
        expect((result as Map)['key'], 'value');
      });
    });

    group('Strategy 3: bare-fenced blocks', () {
      test('extracts bare-fenced JSON object', () {
        const raw = '```\n{"pass": true}\n```';
        final result = extractJson(raw);
        expect(result, isA<Map<String, dynamic>>());
        expect((result as Map<String, dynamic>)['pass'], true);
      });

      test('extracts bare-fenced JSON array', () {
        const raw = '```\n[1, 2, 3]\n```';
        final result = extractJson(raw);
        expect(result, isA<List<dynamic>>());
      });

      test('json fence takes priority over bare fence', () {
        // When both exist, json-fenced is tried first.
        const raw = '```\n{"bare": true}\n```\n```json\n{"json": true}\n```';
        final result = extractJson(raw);
        // Strategy 2 (json-fenced) succeeds first.
        expect((result as Map<String, dynamic>)['json'], true);
      });
    });

    group('Strategy 4: pattern scan', () {
      test('extracts JSON object embedded in prose', () {
        const raw = 'Analysis:\n\nThe result is {"pass": true, "count": 3}\n\nDone.';
        final result = extractJson(raw);
        expect(result, isA<Map<String, dynamic>>());
        expect((result as Map<String, dynamic>)['pass'], true);
        expect(result['count'], 3);
      });

      test('extracts JSON array embedded in prose', () {
        const raw = 'Here are the items: [{"id": "s01"}, {"id": "s02"}] done.';
        final result = extractJson(raw);
        expect(result, isA<List<dynamic>>());
        expect((result as List<dynamic>).length, 2);
      });

      test('handles nested balanced braces in strings', () {
        const raw = 'Result: {"nested": {"key": "value with } brace"}}';
        final result = extractJson(raw);
        expect(result, isA<Map<String, dynamic>>());
        final nested = (result as Map<String, dynamic>)['nested'] as Map<String, dynamic>;
        expect(nested['key'], 'value with } brace');
      });

      test('takes longest balanced match', () {
        // Two valid JSON objects — should pick the longer one.
        const raw = '{"a": 1} some text {"b": 2, "c": 3, "d": 4}';
        final result = extractJson(raw);
        expect(result, isA<Map<String, dynamic>>());
        // The longer object has b, c, d keys.
        expect((result as Map<String, dynamic>).containsKey('b'), true);
      });
    });

    group('failure cases', () {
      test('throws FormatException with preview on complete failure', () {
        expect(
          () => extractJson('no json here at all'),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('JSON extraction failed after all strategies'),
            ),
          ),
        );
      });

      test('includes first 500 chars of raw output in error', () {
        final raw = 'x' * 600;
        expect(
          () => extractJson(raw),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('${'x' * 497}...'), // truncated preview
            ),
          ),
        );
      });

      test('throws on empty input', () {
        expect(() => extractJson(''), throwsA(isA<FormatException>()));
      });

      test('throws when all strategies produce invalid JSON', () {
        const raw = '```json\nnot valid json\n```';
        expect(() => extractJson(raw), throwsA(isA<FormatException>()));
      });
    });
  });

  group('extractLines', () {
    test('splits on newlines', () {
      const raw = 'line1\nline2\nline3';
      expect(extractLines(raw), ['line1', 'line2', 'line3']);
    });

    test('trims whitespace from each line', () {
      const raw = '  line1  \n  line2  ';
      expect(extractLines(raw), ['line1', 'line2']);
    });

    test('filters empty lines', () {
      const raw = 'line1\n\nline2\n\n\nline3';
      expect(extractLines(raw), ['line1', 'line2', 'line3']);
    });

    test('filters whitespace-only lines', () {
      const raw = 'line1\n   \nline2';
      expect(extractLines(raw), ['line1', 'line2']);
    });

    test('returns empty list for empty input', () {
      expect(extractLines(''), isEmpty);
    });

    test('returns empty list for whitespace-only input', () {
      expect(extractLines('   \n   \n   '), isEmpty);
    });

    test('handles single line', () {
      expect(extractLines('just one line'), ['just one line']);
    });
  });
}
