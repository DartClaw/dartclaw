import 'package:dartclaw_core/src/harness/claude_protocol.dart' show claudeOauthTokenEnvVar;
import 'package:dartclaw_core/src/worker/worker_state.dart';
import 'package:test/test.dart';

import 'harness_test_support.dart';

void main() {
  group('ClaudeCodeHarness host authentication precondition', () {
    test('starts on an injected setup-token without consulting the interactive login', () async {
      // The CLI authenticates itself on the injected token. Probing anyway
      // would answer from the operator's own `claude auth status` session and
      // let a broken injected token start green on someone else's login.
      final probedArgs = <List<String>>[];
      final harness = buildClaudeHarness(
        environment: const {claudeOauthTokenEnvVar: 'sk-ant-oat01-injected'},
        commandProbe: (exe, args) async {
          probedArgs.add(args);
          return processResult(exitCode: 0, stdout: '2.1.0');
        },
      );
      addTearDown(harness.dispose);

      await harness.start();

      expect(harness.state, WorkerState.idle);
      expect(probedArgs, [
        ['--version'],
      ]);
    });

    test('a blank injected token does not stand in for authentication', () async {
      var authStatusProbes = 0;
      final harness = buildClaudeHarness(
        environment: const {claudeOauthTokenEnvVar: '   '},
        commandProbe: (exe, args) async {
          if (args.contains('--version')) return processResult(exitCode: 0, stdout: '2.1.0');
          authStatusProbes++;
          return processResult(exitCode: 1);
        },
      );
      addTearDown(harness.dispose);

      await expectLater(
        harness.start(),
        throwsA(isA<StateError>().having((e) => e.message, 'message', contains('No authentication configured'))),
      );
      expect(authStatusProbes, 1, reason: 'the nothing-configured fallback probe is deliberately preserved');
    });
  });
}
