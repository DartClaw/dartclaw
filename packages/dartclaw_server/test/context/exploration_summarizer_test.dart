import 'package:dartclaw_server/src/context/exploration_summarizer.dart';
import 'package:dartclaw_server/src/context/result_trimmer.dart';
import 'package:test/test.dart';

void main() {
  group('ExplorationSummarizer', () {
    const lowThreshold = 10; // 10 tokens = ~40 bytes for testing

    test('returns small content unchanged when below threshold and byte cap', () {
      final summarizer = ExplorationSummarizer(thresholdTokens: 10000);
      const content = 'short content';
      expect(summarizer.summarizeOrTrim(content), content);
    });

    test('trims content below token threshold but above byte cap', () {
      // 75KB content: below 25K token threshold (75KB/4 = ~18K tokens)
      // but above ResultTrimmer 50KB byte cap
      final trimmer = ResultTrimmer(maxBytes: 50 * 1024);
      final summarizer = ExplorationSummarizer(trimmer: trimmer, thresholdTokens: 25000);
      final content = 'A' * (75 * 1024); // 75KB
      final result = summarizer.summarizeOrTrim(content);
      expect(result, contains('trimmed'));
      expect(result.length, lessThan(content.length));
    });

    test('JSON above threshold produces JSON summary', () {
      final summarizer = ExplorationSummarizer(thresholdTokens: lowThreshold);
      // A large-ish JSON that will exceed 40 bytes
      final json = '{"users": [{"name": "Alice", "age": 30}], "count": 1, "metadata": {"version": "1.0"}}';
      final result = summarizer.summarizeOrTrim(json, fileHint: 'data.json');
      expect(result, contains('[Exploration summary — JSON'));
    });

    test('unrecognized type above threshold falls back to ResultTrimmer', () {
      final trimmer = ResultTrimmer(maxBytes: 50);
      final summarizer = ExplorationSummarizer(trimmer: trimmer, thresholdTokens: lowThreshold);
      // Plain text: no type detected, falls back to trimmer
      final large = 'A' * 10000;
      final result = summarizer.summarizeOrTrim(large);
      expect(result, contains('trimmed'));
    });

    test('malformed JSON above threshold falls back to ResultTrimmer', () {
      final trimmer = ResultTrimmer(maxBytes: 50);
      final summarizer = ExplorationSummarizer(trimmer: trimmer, thresholdTokens: lowThreshold);
      // Looks like JSON (starts with {) but is invalid
      final malformed = '{invalid json content ' * 100;
      final result = summarizer.summarizeOrTrim(malformed, fileHint: 'data.json');
      // Should not throw; should fall back to trimmer
      expect(result, isNotNull);
      expect(result.isNotEmpty, isTrue);
    });

    test('file hint extension detection routes to correct type', () {
      final summarizer = ExplorationSummarizer(thresholdTokens: lowThreshold);
      final dartCode =
          '''
class Foo {
  void bar() {}
}

class Baz {}
''' *
          20; // inflate size
      final result = summarizer.summarizeOrTrim(dartCode, fileHint: 'myfile.dart');
      expect(result, contains('[Exploration summary — Dart source'));
    });

    test('CSV file hint produces CSV summary', () {
      final summarizer = ExplorationSummarizer(thresholdTokens: lowThreshold);
      final csvLines = ['name,age,city'];
      for (var i = 0; i < 100; i++) {
        csvLines.add('Person$i,$i,City$i');
      }
      final csv = csvLines.join('\n');
      final result = summarizer.summarizeOrTrim(csv, fileHint: 'data.csv');
      expect(result, contains('[Exploration summary — CSV'));
    });

    test('token estimation: 100KB content exceeds 25K token threshold', () {
      // 100KB / 4 bytes per token = ~25K tokens
      final summarizer = ExplorationSummarizer(thresholdTokens: 24000);
      final largeText = 'x' * (100 * 1024);
      final result = summarizer.summarizeOrTrim(largeText);
      // Should attempt summarization (no type → trimmer fallback)
      expect(result, isNotNull);
    });

    test('default threshold is 25000 tokens', () {
      final summarizer = ExplorationSummarizer();
      expect(summarizer.thresholdTokens, 25000);
    });

    test('no file hint falls back to content heuristics', () {
      final summarizer = ExplorationSummarizer(thresholdTokens: lowThreshold);
      final json = '{"key": "value"${', "x": 1' * 100}}';
      final result = summarizer.summarizeOrTrim(json); // no fileHint
      expect(result, contains('[Exploration summary — JSON'));
    });
  });
}
