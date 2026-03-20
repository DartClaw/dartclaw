import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:test/test.dart';

void main() {
  group('FakeGuard', () {
    test('returns fixed verdicts and tracks evaluations', () async {
      final guard = FakeGuard.warn('careful', name: 'warner', category: 'security');
      final context = GuardContext(hookPoint: 'beforeToolCall', timestamp: DateTime(2026));

      final verdict = await guard.evaluate(context);

      expect(verdict.isWarn, isTrue);
      expect(verdict.message, 'careful');
      expect(guard.name, 'warner');
      expect(guard.category, 'security');
      expect(guard.evaluationCount, 1);
      expect(guard.lastContext, same(context));
    });

    test('supports dynamic evaluator callbacks', () async {
      final guard = FakeGuard(
        evaluator: (context) {
          return context.messageContent == 'block-me' ? GuardVerdict.block('blocked') : GuardVerdict.pass();
        },
      );

      final passVerdict = await guard.evaluate(
        GuardContext(hookPoint: 'messageReceived', messageContent: 'safe', timestamp: DateTime(2026)),
      );
      final blockVerdict = await guard.evaluate(
        GuardContext(hookPoint: 'messageReceived', messageContent: 'block-me', timestamp: DateTime(2026)),
      );

      expect(passVerdict.isPass, isTrue);
      expect(blockVerdict.isBlock, isTrue);
      expect(blockVerdict.message, 'blocked');
      expect(guard.evaluationCount, 2);
      expect(guard.evaluatedContexts, hasLength(2));
    });
  });
}
