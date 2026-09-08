import 'dart:async';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/src/behavior/behavior_file_service.dart';
import 'package:dartclaw_runtime/src/turn_runner.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' show FakeAgentHarness;
import 'package:test/test.dart';

import 'turn_runner_test_support.dart';

void main() {
  test('strict workflow filter distinguishes omitted, empty, and nonempty turn policies', () async {
    final guard = TaskToolFilterGuard(denyEmptyAllowlist: true);
    final worker = FakeAgentHarness(supportsStructuredOutput: true);
    addTearDown(worker.dispose);
    final runner = TurnRunner(
      turnLimits: const TurnLimitsConfig.defaults(),
      harness: worker,
      messages: NoOpMessages(),
      behavior: BehaviorFileService(workspaceDir: '/tmp/dartclaw-turn-runner-tool-policy-test'),
      sessions: NoOpSessions(),
      taskToolFilterGuard: guard,
    );
    const sessionId = 'workflow-session';

    Future<List<GuardVerdict>> runWithPolicy(
      List<String>? allowedTools,
      List<String> probes, {
      Map<String, dynamic>? outputSchema,
    }) async {
      final observed = Completer<List<GuardVerdict>>();
      unawaited(() async {
        await worker.turnInvoked;
        observed.complete([
          for (final tool in probes)
            await guard.evaluate(
              GuardContext(
                hookPoint: 'beforeToolCall',
                toolName: tool,
                rawProviderToolName: switch (tool) {
                  'claude:ToolSearch' => 'ToolSearch',
                  'claude:StructuredOutput' => 'StructuredOutput',
                  'claude:Skill' => 'Skill',
                  _ => null,
                },
                sessionId: sessionId,
                timestamp: DateTime.now(),
              ),
            ),
        ]);
        worker.completeSuccess(turnResult());
      }());
      final turnId = await runner.reserveTurn(sessionId, allowedTools: allowedTools, outputSchema: outputSchema);
      runner.executeTurn(sessionId, turnId, const [
        {'role': 'user', 'content': 'probe policy'},
      ]);
      await runner.waitForOutcome(sessionId, turnId);
      return observed.future;
    }

    final omitted = await runWithPolicy(null, const ['claude:Skill']);
    final empty = await runWithPolicy(const [], const ['file_read', 'claude:ToolSearch', 'claude:Skill']);
    final declared = await runWithPolicy(const ['file_read'], const ['file_read', 'claude:Skill', 'shell']);
    final structuredFinalizer = await runWithPolicy(
      const [],
      const ['claude:StructuredOutput', 'file_read'],
      outputSchema: const {'type': 'object'},
    );

    expect(omitted.single.isPass, isTrue);
    expect(empty.every((verdict) => verdict.isBlock), isTrue);
    expect(declared.first.isPass, isTrue);
    expect(declared[1].isPass, isTrue);
    expect(declared.last.isBlock, isTrue);
    expect(structuredFinalizer.first.isPass, isTrue);
    expect(structuredFinalizer.last.isBlock, isTrue);
  });
}
