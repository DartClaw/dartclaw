import 'package:dartclaw_core/src/harness/harness_launch_options.dart';
import 'package:test/test.dart';

import 'harness_test_support.dart';

/// Spawn argv of `ClaudeCodeHarness`: the flags that carry policy, cap and
/// prompt to the process, and the handshake that carries none of them.
void main() {
  void addTeardownAsync(Future<void> Function() fn) => addTearDown(fn);

  group('ClaudeCodeHarness spawn args', () {
    test('spawn args include --append-system-prompt when configured', () async {
      List<String>? capturedArgs;

      final h = buildClaudeHarness(
        harnessConfig: const HarnessLaunchOptions(appendSystemPrompt: 'test behavior prompt'),
        processFactory: capturingInitFactory(
          onSpawn: (spawn) {
            capturedArgs = spawn.args;
          },
        ),
      );
      addTeardownAsync(() => h.dispose());

      await h.start();

      expect(capturedArgs, isNotNull);
      final idx = capturedArgs!.indexOf('--append-system-prompt');
      expect(idx, greaterThanOrEqualTo(0), reason: '--append-system-prompt flag should be present');
      expect(capturedArgs![idx + 1], 'test behavior prompt');
    });

    test('spawn args withhold tools in native spelling and cap turns; the handshake carries neither', () async {
      List<String>? capturedArgs;
      final fake = makeCapturingClaudeProcess();
      final h = buildClaudeHarness(
        harnessConfig: const HarnessLaunchOptions(disallowedTools: ['shell', 'file_edit', 'Computer'], maxTurns: 7),
        processFactory: capturingInitFactory(process: fake, onSpawn: (spawn) => capturedArgs = spawn.args),
      );
      addTeardownAsync(() => h.dispose());

      await h.start();

      final args = capturedArgs!;
      expect(args.sublist(args.indexOf('--max-turns')).take(2), ['--max-turns', '7']);
      final flag = args.indexOf('--disallowedTools');
      expect(args.sublist(flag + 1), ['Bash', 'Edit', 'NotebookEdit', 'Computer']);
      final initialize = fake.capturedStdinJson.firstWhere(
        (message) => (message['request'] as Map?)?['subtype'] == 'initialize',
      );
      expect((initialize['request'] as Map).keys, unorderedEquals(['subtype', 'hooks']));
    });

    test('spawn args omit --append-system-prompt when not configured', () async {
      List<String>? capturedArgs;

      final h = buildClaudeHarness(
        processFactory: capturingInitFactory(
          onSpawn: (spawn) {
            capturedArgs = spawn.args;
          },
        ),
      );
      addTeardownAsync(() => h.dispose());

      await h.start();

      expect(capturedArgs, isNotNull);
      expect(capturedArgs, isNot(contains('--append-system-prompt')));
    });
  });
}
