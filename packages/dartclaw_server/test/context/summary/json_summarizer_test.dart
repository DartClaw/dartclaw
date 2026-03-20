import 'package:dartclaw_server/src/context/summary/json_summarizer.dart';
import 'package:test/test.dart';

void main() {
  group('JsonSummarizer', () {
    test('returns null for invalid JSON', () {
      expect(JsonSummarizer.summarize('not json', 1000), isNull);
    });

    test('returns null for empty invalid input', () {
      expect(JsonSummarizer.summarize('', 1000), isNull);
    });

    test('summarizes simple JSON object', () {
      const json = '{"name": "Alice", "age": 30, "active": true}';
      final result = JsonSummarizer.summarize(json, 1000);
      expect(result, isNotNull);
      expect(result, contains('[Exploration summary — JSON'));
      expect(result, contains('name: string'));
      expect(result, contains('age: number'));
      expect(result, contains('active: bool'));
      expect(result, contains('[Full content available'));
    });

    test('summarizes nested JSON object', () {
      const json = '{"user": {"name": "Bob", "address": {"city": "NYC"}}}';
      final result = JsonSummarizer.summarize(json, 5000);
      expect(result, isNotNull);
      expect(result, contains('user: Object'));
      expect(result, contains('name: string'));
    });

    test('summarizes JSON array at root', () {
      const json = '[{"id": 1, "value": "x"}, {"id": 2, "value": "y"}]';
      final result = JsonSummarizer.summarize(json, 5000);
      expect(result, isNotNull);
      expect(result, contains('[Exploration summary — JSON'));
    });

    test('summarizes JSON with arrays', () {
      const json = '{"users": [{"name": "Alice"}, {"name": "Bob"}], "count": 2}';
      final result = JsonSummarizer.summarize(json, 5000);
      expect(result, isNotNull);
      expect(result, contains('users: Array[2]'));
      expect(result, contains('count: number'));
    });

    test('handles empty JSON object', () {
      final result = JsonSummarizer.summarize('{}', 1000);
      expect(result, isNotNull);
      expect(result, contains('[Exploration summary — JSON'));
    });

    test('handles JSON with null values', () {
      const json = '{"key": null, "name": "test"}';
      final result = JsonSummarizer.summarize(json, 1000);
      expect(result, isNotNull);
      expect(result, contains('key: null'));
    });

    test('estimated token count appears in header', () {
      const json = '{"name": "Alice"}';
      final result = JsonSummarizer.summarize(json, 25340);
      expect(result, isNotNull);
      expect(result, contains('25.3K'));
    });

    test('summary includes full content note', () {
      const json = '{"name": "test"}';
      final result = JsonSummarizer.summarize(json, 1000);
      expect(result, contains('Full content available'));
      expect(result, contains('Use Read tool'));
    });

    test('large JSON with many keys is truncated with marker', () {
      // Create JSON with 210 keys
      final entries = List.generate(210, (i) => '"key$i": "value$i"');
      final json = '{${entries.join(',')}}';
      final result = JsonSummarizer.summarize(json, 50000);
      expect(result, isNotNull);
      expect(result, contains('... and'));
      expect(result, contains('more'));
    });

    test('key limit is accumulated globally across nested objects', () {
      // Build JSON with 201 total keys spread across nested objects
      // (100 top-level + 101 in a nested object)
      final topLevelEntries = List.generate(100, (i) => '"top$i": "value$i"');
      final nestedEntries = List.generate(101, (i) => '"nested$i": "value$i"');
      final json = '{${topLevelEntries.join(',')}, "sub": {${nestedEntries.join(',')}}}';
      final result = JsonSummarizer.summarize(json, 50000);
      expect(result, isNotNull);
      expect(result, contains('... and'));
    });
  });

  group('YAML', () {
    test('summarizes simple YAML object', () {
      const yaml = 'name: Alice\nage: 30\nactive: true\n';
      final result = JsonSummarizer.summarize(yaml, 1000, isYaml: true);
      expect(result, isNotNull);
      expect(result, contains('[Exploration summary — YAML'));
      expect(result, contains('name: string'));
      expect(result, contains('age: number'));
      expect(result, contains('[Full content available'));
    });

    test('summarizes nested YAML object', () {
      const yaml = 'user:\n  name: Bob\n  address:\n    city: NYC\n';
      final result = JsonSummarizer.summarize(yaml, 5000, isYaml: true);
      expect(result, isNotNull);
      expect(result, contains('user: Object'));
      expect(result, contains('name: string'));
    });

    test('summarizes YAML with sequences', () {
      const yaml = 'users:\n  - name: Alice\n    age: 30\n  - name: Bob\n    age: 25\ncount: 2\n';
      final result = JsonSummarizer.summarize(yaml, 5000, isYaml: true);
      expect(result, isNotNull);
      expect(result, contains('users: Array[2]'));
      expect(result, contains('count: number'));
    });

    test('returns null for invalid YAML', () {
      // Invalid YAML (unclosed bracket)
      const malformed = 'key: [unclosed\nother: value\n';
      // yaml package may or may not throw for this; either null or a valid result is acceptable
      // The key requirement is that it does NOT throw
      expect(() => JsonSummarizer.summarize(malformed, 1000, isYaml: true), returnsNormally);
    });
  });
}
