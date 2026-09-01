import 'dart:async';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';

typedef _CapturedVerdict = ({
  String guardName,
  String guardCategory,
  String verdict,
  String? message,
  GuardContext context,
});
typedef _ChainEvaluation = Future<GuardVerdict> Function(GuardChain chain);

class ThrowingGuard extends Guard {
  @override
  final String name = 'thrower';

  @override
  final String category = 'test';

  @override
  Future<GuardVerdict> evaluate(GuardContext context) {
    throw StateError('guard error');
  }
}

class _BudgetedGuard extends Guard {
  new({required this.delay, required this.evaluationBudget, this.timeoutVerdict, this.throwOnTimeout = false});

  final Duration delay;
  @override
  final Duration evaluationBudget;
  final GuardVerdict? timeoutVerdict;
  final bool throwOnTimeout;

  @override
  String get name => 'budgeted';

  @override
  String get category => 'test';

  @override
  Future<GuardVerdict> evaluate(GuardContext context) async {
    await Future<void>.delayed(delay);
    return GuardVerdict.pass();
  }

  @override
  GuardVerdict? onEvaluationTimeout(GuardContext context) {
    if (throwOnTimeout) throw StateError('timeout policy failed');
    return timeoutVerdict;
  }
}

void main() {
  late List<_CapturedVerdict> verdicts;

  GuardChain buildChain(List<Guard> guards, {bool failOpen = false}) {
    return GuardChain(
      guards: guards,
      failOpen: failOpen,
      onVerdict: (guardName, guardCategory, verdict, message, context) {
        verdicts.add((
          guardName: guardName,
          guardCategory: guardCategory,
          verdict: verdict,
          message: message,
          context: context,
        ));
      },
    );
  }

  setUp(() {
    verdicts = [];
  });

  group('GuardChain', () {
    test('empty chain returns pass', () async {
      final chain = buildChain([]);
      final verdict = await chain.evaluateBeforeToolCall('shell', {});
      expect(verdict.isPass, isTrue);
      expect(verdicts, isEmpty);
    });

    test('slow guard resolves via its own budget and timeout policy', () {
      fakeAsync((async) {
        final withinBudget = buildChain([
          _BudgetedGuard(delay: const Duration(seconds: 10), evaluationBudget: const Duration(seconds: 50)),
        ]);
        GuardVerdict? withinBudgetVerdict;
        withinBudget.evaluateBeforeAgentSend('content').then((value) => withinBudgetVerdict = value);
        async.elapse(const Duration(seconds: 10));
        async.flushMicrotasks();
        expect(withinBudgetVerdict?.isPass, isTrue);

        final ownPolicy = buildChain([
          _BudgetedGuard(
            delay: const Duration(seconds: 50),
            evaluationBudget: const Duration(seconds: 5),
            timeoutVerdict: GuardVerdict.pass(),
          ),
        ]);
        GuardVerdict? ownPolicyVerdict;
        ownPolicy.evaluateBeforeAgentSend('content').then((value) => ownPolicyVerdict = value);
        async.elapse(const Duration(seconds: 5));
        async.flushMicrotasks();
        expect(ownPolicyVerdict?.isPass, isTrue);
      });
    });

    test('throwing timeout policy resolves through the chain exception policy', () {
      fakeAsync((async) {
        for (final failOpen in [false, true]) {
          final chain = buildChain([
            _BudgetedGuard(
              delay: const Duration(seconds: 10),
              evaluationBudget: const Duration(seconds: 1),
              throwOnTimeout: true,
            ),
          ], failOpen: failOpen);
          GuardVerdict? verdict;
          chain.evaluateBeforeAgentSend('content').then((value) => verdict = value);
          async.elapse(const Duration(seconds: 1));
          async.flushMicrotasks();

          expect(verdict?.isBlock, !failOpen);
          expect(verdict?.isWarn, failOpen);
          expect(verdict?.message, contains('timeout policy failed'));
        }
      });
    });

    test('all guards pass returns pass', () async {
      final chain = buildChain([
        FakeGuard(verdict: GuardVerdict.pass()),
        FakeGuard(name: 'g2', verdict: GuardVerdict.pass()),
      ]);
      final verdict = await chain.evaluateBeforeToolCall('shell', {});
      expect(verdict.isPass, isTrue);
      expect(verdicts, isEmpty);
    });

    test('addGuard appends a guard that participates in evaluation', () async {
      final chain = buildChain([FakeGuard(name: 'g1', verdict: GuardVerdict.pass())]);
      chain.addGuard(FakeGuard(name: 'added', verdict: GuardVerdict.block('added guard blocked')));

      final verdict = await chain.evaluateBeforeToolCall('shell', {});

      expect(verdict.isBlock, isTrue);
      expect(verdict.message, 'added guard blocked');
      expect(verdicts, hasLength(1));
      expect(verdicts.single.guardName, 'added');
    });

    test('addGuard evaluates after constructor-supplied guards', () async {
      final evaluationOrder = <String>[];
      final chain = buildChain([
        FakeGuard(
          name: 'initial',
          evaluator: (context) {
            evaluationOrder.add('initial');
            return GuardVerdict.pass();
          },
        ),
      ]);
      chain.addGuard(
        FakeGuard(
          name: 'added',
          evaluator: (context) {
            evaluationOrder.add('added');
            return GuardVerdict.pass();
          },
        ),
      );

      final verdict = await chain.evaluateBeforeToolCall('shell', {});

      expect(verdict.isPass, isTrue);
      expect(evaluationOrder, equals(['initial', 'added']));
    });

    test('first block wins', () async {
      final chain = buildChain([
        FakeGuard(name: 'g1', verdict: GuardVerdict.pass()),
        FakeGuard(name: 'blocker', verdict: GuardVerdict.block('nope')),
        FakeGuard(name: 'g3', verdict: GuardVerdict.pass()),
      ]);
      final verdict = await chain.evaluateBeforeToolCall('shell', {});
      expect(verdict.isBlock, isTrue);
      expect(verdict.message, 'nope');
      expect(verdicts, hasLength(1));
      expect(verdicts[0].guardName, 'blocker');
      expect(verdicts[0].verdict, 'block');
    });

    test('exception from guard treated as block (fail-closed)', () async {
      final chain = buildChain([ThrowingGuard()]);
      final verdict = await chain.evaluateMessageReceived('hello');
      expect(verdict.isBlock, isTrue);
      expect(verdict.message, contains('Guard error'));
      expect(verdicts, hasLength(1));
      expect(verdicts[0].guardName, 'thrower');
      expect(verdicts[0].verdict, 'block');
    });

    test('warn verdict returned when no blocks', () async {
      final chain = buildChain([FakeGuard(name: 'warner', verdict: GuardVerdict.warn('careful'))]);
      final verdict = await chain.evaluateBeforeAgentSend('response text');
      expect(verdict.isWarn, isTrue);
      expect(verdict.message, 'careful');
    });

    test('multiple warns returns first warn message', () async {
      final chain = buildChain([
        FakeGuard(name: 'w1', verdict: GuardVerdict.warn('first')),
        FakeGuard(name: 'w2', verdict: GuardVerdict.warn('second')),
      ]);
      final verdict = await chain.evaluateBeforeToolCall('file_read', {});
      expect(verdict.isWarn, isTrue);
      expect(verdict.message, 'first');
      expect(verdicts, hasLength(2));
      expect(verdicts[0].guardName, 'w1');
      expect(verdicts[1].guardName, 'w2');
    });

    test('block and warn verdicts trigger the verdict callback', () async {
      final chain = buildChain([
        FakeGuard(name: 'g1', verdict: GuardVerdict.pass()),
        FakeGuard(name: 'g2', verdict: GuardVerdict.warn('w')),
      ]);
      await chain.evaluateBeforeToolCall('shell', {});
      expect(verdicts, hasLength(1));
      expect(verdicts[0].guardName, 'g2');
      expect(verdicts[0].verdict, 'warn');
      expect(verdicts[0].message, 'w');
    });

    group('context', () {
      final cases = <({String name, _ChainEvaluation evaluate, String hookPoint, String? source})>[
        (
          name: 'message received',
          evaluate: (chain) => chain.evaluateMessageReceived('test', source: 'channel'),
          hookPoint: 'messageReceived',
          source: 'channel',
        ),
        (
          name: 'before agent send',
          evaluate: (chain) => chain.evaluateBeforeAgentSend('response'),
          hookPoint: 'beforeAgentSend',
          source: null,
        ),
      ];

      for (final testCase in cases) {
        test('${testCase.name} context', () async {
          GuardContext? capturedContext;
          final chain = buildChain([
            FakeGuard(
              evaluator: (context) {
                capturedContext = context;
                return GuardVerdict.pass();
              },
            ),
          ]);

          await testCase.evaluate(chain);

          expect(capturedContext!.hookPoint, testCase.hookPoint);
          expect(capturedContext!.source, testCase.source);
        });
      }
    });

    group('guard exceptions', () {
      final cases = [
        (name: 'failOpen true warns', failOpen: true, isBlock: false, isWarn: true, callbackVerdict: 'warn'),
        (name: 'failOpen false blocks', failOpen: false, isBlock: true, isWarn: false, callbackVerdict: 'block'),
      ];

      for (final testCase in cases) {
        test(testCase.name, () async {
          final chain = buildChain([ThrowingGuard()], failOpen: testCase.failOpen);
          final verdict = await chain.evaluateBeforeToolCall('shell', {});

          expect(verdict.isBlock, testCase.isBlock);
          expect(verdict.isWarn, testCase.isWarn);
          expect(verdicts, hasLength(1));
          expect(verdicts[0].verdict, testCase.callbackVerdict);
        });
      }
    });

    test('a blocking guard short-circuits the guards after it', () async {
      final evaluationOrder = <String>[];
      final chain = buildChain([
        FakeGuard(name: 'blocker', evaluator: (context) => GuardVerdict.block('blocked at the boundary')),
        FakeGuard(
          name: 'after-blocker',
          evaluator: (context) {
            evaluationOrder.add('after-blocker');
            return GuardVerdict.pass();
          },
        ),
      ]);

      final verdict = await chain.evaluateMessageReceived('any inbound content');
      expect(verdict.isBlock, isTrue);
      expect(verdict.message, contains('blocked at the boundary'));
      expect(evaluationOrder, isEmpty);
      expect(verdicts, hasLength(1));
      expect(verdicts[0].guardName, 'blocker');
    });

    test('evaluateBeforeToolCall propagates tool and agent identity into GuardContext', () async {
      GuardContext? capturedContext;
      final chain = buildChain([
        FakeGuard(
          evaluator: (context) {
            capturedContext = context;
            return GuardVerdict.pass();
          },
        ),
      ]);

      await chain.evaluateBeforeToolCall('shell', {}, rawProviderToolName: 'Bash', agentId: 'search');

      expect(capturedContext, isNotNull);
      expect(capturedContext!.toolName, 'shell');
      expect(capturedContext!.rawProviderToolName, 'Bash');
      expect(capturedContext!.agentId, 'search');

      await chain.evaluateBeforeToolCall('shell', {});
      expect(capturedContext!.agentId, isNull);
    });

    group('replaceGuards', () {
      test('subsequent evaluations use the new guard list', () async {
        final chain = buildChain([FakeGuard(name: 'original', verdict: GuardVerdict.pass())]);

        final verdict1 = await chain.evaluateBeforeToolCall('shell', {});
        expect(verdict1.isPass, isTrue);

        chain.replaceGuards([FakeGuard(name: 'replacement', verdict: GuardVerdict.block('blocked by replacement'))]);

        final verdict2 = await chain.evaluateBeforeToolCall('shell', {});
        expect(verdict2.isBlock, isTrue);
        expect(verdict2.message, 'blocked by replacement');
      });

      test('guards getter returns unmodifiable list — throws on mutation', () {
        final chain = buildChain([FakeGuard()]);
        expect(() => chain.guards.add(FakeGuard(name: 'extra')), throwsUnsupportedError);
      });

      test('addGuard still works after replaceGuards', () async {
        final chain = buildChain([FakeGuard(name: 'g1', verdict: GuardVerdict.pass())]);
        chain.replaceGuards([FakeGuard(name: 'g2', verdict: GuardVerdict.pass())]);
        chain.addGuard(FakeGuard(name: 'g3', verdict: GuardVerdict.block('g3 blocked')));

        final verdict = await chain.evaluateBeforeToolCall('shell', {});
        expect(verdict.isBlock, isTrue);
        expect(verdict.message, 'g3 blocked');
        expect(chain.guards, hasLength(2)); // g2 + g3
      });

      test('replace with empty list — subsequent evaluation passes', () async {
        final chain = buildChain([FakeGuard(verdict: GuardVerdict.block('blocked'))]);
        chain.replaceGuards([]);

        final verdict = await chain.evaluateBeforeToolCall('shell', {});
        expect(verdict.isPass, isTrue);
      });
    });

    group('layered', () {
      test('evaluates base guards before layer guards', () async {
        final baseGuard = FakeGuard(name: 'base');
        final layerGuard = FakeGuard(name: 'layer', verdict: GuardVerdict.block('layer blocked'));
        final base = buildChain([baseGuard]);
        final layered = GuardChain.layered(base: base, guards: [layerGuard]);

        final verdict = await layered.evaluateBeforeToolCall('shell', {});

        expect(verdict.isBlock, isTrue);
        expect(verdict.message, 'layer blocked');
        expect(baseGuard.evaluationCount, 1);
        expect(layerGuard.evaluationCount, 1);
      });

      test('base block short-circuits before layer guards run', () async {
        final layerGuard = FakeGuard(name: 'layer');
        final base = buildChain([FakeGuard.block('base blocked', name: 'base')]);
        final layered = GuardChain.layered(base: base, guards: [layerGuard]);

        final verdict = await layered.evaluateBeforeToolCall('shell', {});

        expect(verdict.isBlock, isTrue);
        expect(verdict.message, 'base blocked');
        expect(layerGuard.evaluationCount, 0);
      });

      test('replaceGuards on base is picked up live and layer guards survive', () async {
        final layerGuard = FakeGuard(name: 'layer');
        final base = buildChain([FakeGuard(name: 'original')]);
        final layered = GuardChain.layered(base: base, guards: [layerGuard]);

        expect((await layered.evaluateBeforeToolCall('shell', {})).isPass, isTrue);

        base.replaceGuards([FakeGuard.block('rebuilt blocked', name: 'rebuilt')]);

        final verdict = await layered.evaluateBeforeToolCall('shell', {});
        expect(verdict.isBlock, isTrue);
        expect(verdict.message, 'rebuilt blocked');
        expect(layered.guards.map((g) => g.name), ['rebuilt', 'layer']);

        base.replaceGuards([]);
        layerGuard.evaluationCount = 0;
        await layered.evaluateBeforeToolCall('shell', {});
        expect(layerGuard.evaluationCount, 1);
      });

      test('null base evaluates only layer guards, fail-closed', () async {
        final layered = GuardChain.layered(base: null, guards: [ThrowingGuard()]);

        final verdict = await layered.evaluateBeforeToolCall('shell', {});

        expect(verdict.isBlock, isTrue);
        expect(layered.failOpen, isFalse);
      });

      test('inherits onVerdict and failOpen from base', () async {
        final base = buildChain([], failOpen: true);
        final layered = GuardChain.layered(
          base: base,
          guards: [FakeGuard.block('layer blocked', name: 'layer')],
        );

        await layered.evaluateBeforeToolCall('shell', {});

        expect(layered.failOpen, isTrue);
        expect(verdicts, hasLength(1));
        expect(verdicts.single.guardName, 'layer');
        expect(verdicts.single.verdict, 'block');
      });
    });

    group('GuardBuildResult', () {
      test('GuardBuildSuccess can be constructed and pattern-matched', () {
        final guards = [FakeGuard()];
        final GuardBuildResult result = GuardBuildSuccess(guards: guards);

        expect(result, isA<GuardBuildSuccess>());
        switch (result) {
          case GuardBuildSuccess(:final guards):
            expect(guards, hasLength(1));
          case GuardBuildFailure():
            fail('expected success');
        }
      });

      test('GuardBuildFailure can be constructed and pattern-matched', () {
        final GuardBuildResult result = GuardBuildFailure(errors: ['bad regex: [invalid']);

        expect(result, isA<GuardBuildFailure>());
        switch (result) {
          case GuardBuildSuccess():
            fail('expected failure');
          case GuardBuildFailure(:final errors):
            expect(errors, hasLength(1));
            expect(errors.single, contains('bad regex'));
        }
      });
    });
  });
}
