import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:test/test.dart';

void main() {
  group('FakeContentClassifier', () {
    test('returns configured result', () async {
      final classifier = FakeContentClassifier(result: 'prompt_injection');
      expect(await classifier.classify('x'), 'prompt_injection');
    });

    test('defaults to safe', () async {
      expect(await FakeContentClassifier().classify('x'), 'safe');
    });

    test('throws when shouldThrow is set', () {
      final classifier = FakeContentClassifier()..shouldThrow = true;
      expect(() => classifier.classify('x'), throwsException);
    });
  });
}
