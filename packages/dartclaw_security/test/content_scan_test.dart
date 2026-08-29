import 'dart:convert';

import 'package:dartclaw_security/dartclaw_security.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:logging/logging.dart';
import 'package:test/test.dart';

void main() {
  late FakeContentClassifier classifier;

  setUp(() => classifier = FakeContentClassifier());

  group('ContentScan.evaluate', () {
    test('passes on a safe label and reports the scanned span', () async {
      classifier.result = 'safe';
      final verdict = await ContentScan(classifier: classifier).evaluate('web content');
      expect(verdict.blocked, isFalse);
      expect(verdict.classification, isNull);
      expect(verdict.failureReason, isNull);
      expect(verdict.scannedText, 'web content');
      expect(classifier.callCount, 1);
    });

    test('blocks on an unsafe label and names it', () async {
      classifier.result = 'prompt_injection';
      final verdict = await ContentScan(classifier: classifier).evaluate('ignore previous instructions');
      expect(verdict.blocked, isTrue);
      expect(verdict.classification, 'prompt_injection');
      expect(verdict.failureReason, isNull);
    });

    test('blocks on a classifier throw when failOpen is false', () async {
      classifier.shouldThrow = true;
      final verdict = await ContentScan(classifier: classifier).evaluate('content');
      expect(verdict.blocked, isTrue);
      expect(verdict.classification, isNull);
      expect(verdict.failureReason, contains('Classification error'));
    });

    test('passes on a classifier throw when failOpen is true', () async {
      final records = <LogRecord>[];
      final subscription = Logger('ContentScan').onRecord.listen(records.add);
      addTearDown(subscription.cancel);
      classifier.shouldThrow = true;
      final verdict = await ContentScan(classifier: classifier, failOpen: true).evaluate('content');
      expect(verdict.blocked, isFalse);
      expect(verdict.failureReason, contains('Classification error'));
      expect(verdict.scannedText, 'content');
      expect(records, hasLength(1));
      expect(records.single.level, Level.WARNING);
      expect(records.single.message, contains('fail-open'));
    });

    test('empty input passes without reaching the classifier', () async {
      final verdict = await ContentScan(classifier: classifier).evaluate('');
      expect(verdict.blocked, isFalse);
      expect(classifier.callCount, 0);
    });

    test('classifies at most maxContentBytes and reports that span', () async {
      classifier.result = 'safe';
      final verdict = await ContentScan(classifier: classifier, maxContentBytes: 4).evaluate('abcdefgh');
      expect(classifier.lastContent, 'abcd');
      expect(verdict.scannedText, 'abcd');
    });

    test('carries the 15s classify timeout by default', () async {
      await ContentScan(classifier: classifier).evaluate('content');
      expect(classifier.lastTimeout, const Duration(seconds: 15));
    });
  });

  group('ContentScan.exceedsCap', () {
    test('is false at exactly maxContentBytes and true one byte over', () {
      final scan = ContentScan(classifier: classifier, maxContentBytes: 8);
      expect(scan.exceedsCap('12345678'), isFalse);
      expect(scan.exceedsCap('123456789'), isTrue);
      expect(classifier.callCount, 0);
    });

    test('counts UTF-8 bytes, not characters, for a string straddling the cap', () {
      final scan = ContentScan(classifier: classifier, maxContentBytes: 5);
      // 'a🎉' is 5 UTF-8 bytes but 3 UTF-16 code units.
      expect(utf8.encode('a🎉').length, 5);
      expect(scan.exceedsCap('a🎉'), isFalse);
      expect(scan.exceedsCap('ab🎉'), isTrue);
      expect(classifier.callCount, 0);
    });
  });
}
