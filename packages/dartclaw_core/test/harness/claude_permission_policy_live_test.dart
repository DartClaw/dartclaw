@Tags(['integration'])
library;

import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart'
    show ClaudeCodeHarness, ToolApprovalWaitEvent, ToolResultEvent, ToolUseEvent;
import 'package:dartclaw_kernel/dartclaw_kernel.dart' show GuardChain, GuardVerdict;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'harness_test_support.dart' show RecordingGuard;

void main() {
  test(
    'host dontAsk keeps scrub and guards through the real Claude CLI',
    () async {
      final root = await Directory('.agent_temp').absolute.create(recursive: true);
      final workDir = await root.createTemp('claude-permission-live-');
      addTearDown(() => workDir.delete(recursive: true));
      final environment = <String, String>{
        for (final key in ['HOME', 'PATH', 'USER', 'LOGNAME', 'SHELL', 'TMPDIR']) key: ?Platform.environment[key],
        'OPENAI_API_KEY': 'synthetic-presence-sentinel',
      };

      Future<
        ({
          List<ToolUseEvent> uses,
          List<ToolResultEvent> results,
          List<ToolApprovalWaitEvent> approvals,
          String? finalText,
          String? error,
        })
      >
      runTurn({
        required String prompt,
        required List<String> declaredTools,
        required RecordingGuard guard,
        bool askBashNatively = false,
      }) async {
        final uses = <ToolUseEvent>[];
        final results = <ToolResultEvent>[];
        final approvals = <ToolApprovalWaitEvent>[];
        final harness = ClaudeCodeHarness(
          cwd: Directory.current.path,
          environment: environment,
          providerOptions: {
            'permissionMode': 'dontAsk',
            'inherit_user_settings': false,
            if (askBashNatively)
              'permissions': {
                'ask': ['Bash'],
              },
          },
          declaredCanonicalTools: declaredTools,
          guardChain: GuardChain(guards: [guard]),
          turnTimeout: const Duration(seconds: 90),
          initializeTimeout: const Duration(seconds: 45),
        );
        final subscription = harness.events.listen((event) {
          if (event is ToolUseEvent) uses.add(event);
          if (event is ToolResultEvent) results.add(event);
          if (event is ToolApprovalWaitEvent && event.operatorActionable) approvals.add(event);
        });
        String? finalText;
        String? error;
        try {
          final result = await harness.turn(
            sessionId: 'permission-live-${DateTime.now().microsecondsSinceEpoch}',
            directory: workDir.path,
            model: 'haiku',
            maxTurns: 3,
            systemPrompt: 'Execute the requested Bash command exactly once. Do not use another tool.',
            messages: [
              {'role': 'user', 'content': prompt},
            ],
          );
          finalText = result.finalText;
          error = result.error;
        } finally {
          await subscription.cancel();
          await harness.dispose();
        }
        return (uses: uses, results: results, approvals: approvals, finalText: finalText, error: error);
      }

      final allowed = p.join(workDir.path, 'allowed.marker');
      final allowedGuard = RecordingGuard();
      final allowedRun = await runTurn(
        prompt: 'Run Bash command: touch "$allowed"',
        declaredTools: const ['shell'],
        guard: allowedGuard,
      );
      expect(
        File(allowed).existsSync(),
        isTrue,
        reason:
            'toolResults=${allowedRun.results.length}; guardCalls=${allowedGuard.contexts.length}; '
            'finalText=${allowedRun.finalText}; error=${allowedRun.error}',
      );
      expect(allowedGuard.contexts, isNotEmpty);
      expect(allowedRun.approvals, isEmpty);

      final sentinelGuard = RecordingGuard();
      final sentinelRun = await runTurn(
        prompt: r'Run Bash command: if [ -z "${OPENAI_API_KEY+x}" ]; then printf ABSENT; else printf PRESENT; fi',
        declaredTools: const ['shell'],
        guard: sentinelGuard,
      );
      expect(sentinelRun.results.any((result) => result.output.contains('ABSENT')), isTrue);
      expect(sentinelRun.results.any((result) => result.output.contains('PRESENT')), isFalse);
      expect(sentinelRun.approvals, isEmpty);

      final nativeDenied = p.join(workDir.path, 'native-denied.marker');
      final nativeGuard = RecordingGuard();
      final nativeRun = await runTurn(
        prompt: 'Run Bash command: touch "$nativeDenied"',
        declaredTools: const [],
        guard: nativeGuard,
        askBashNatively: true,
      );
      final nativeBashUses = nativeRun.uses
          .where((use) => use.toolName == 'Bash' && (use.input['command'] as String? ?? '').contains(nativeDenied))
          .toList();
      expect(
        File(nativeDenied).existsSync(),
        isFalse,
        reason:
            'toolUses=${nativeRun.uses.map((use) => (tool: use.toolName, exactCommand: use.input['command'] == 'touch "$nativeDenied"'))}; '
            'toolErrors=${nativeRun.results.map((result) => result.isError)}; '
            'guardCalls=${nativeGuard.contexts.length}; finalText=${nativeRun.finalText}; error=${nativeRun.error}',
      );
      expect(
        nativeBashUses,
        isNotEmpty,
        reason:
            'toolNames=${nativeRun.uses.map((use) => use.toolName)}; '
            'toolErrors=${nativeRun.results.map((result) => result.isError)}; '
            'finalText=${nativeRun.finalText}; error=${nativeRun.error}',
      );
      expect(
        nativeRun.results.any((result) => result.isError && nativeBashUses.any((use) => use.toolId == result.toolId)),
        isTrue,
      );
      expect(nativeRun.approvals, isEmpty);

      final guardDenied = p.join(workDir.path, 'guard-denied.marker');
      final blockingGuard = RecordingGuard(verdict: GuardVerdict.block('synthetic guard refusal'));
      final guardRun = await runTurn(
        prompt: 'Run Bash command: touch "$guardDenied"',
        declaredTools: const ['shell'],
        guard: blockingGuard,
      );
      expect(File(guardDenied).existsSync(), isFalse);
      expect(blockingGuard.contexts, isNotEmpty);
      expect(guardRun.approvals, isEmpty);
    },
    skip: 'requires an authenticated compatible Claude CLI',
    timeout: const Timeout(Duration(minutes: 8)),
  );
}
