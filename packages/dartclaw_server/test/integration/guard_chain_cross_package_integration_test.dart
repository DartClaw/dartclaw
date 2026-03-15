import 'package:dartclaw_core/dartclaw_core.dart' as core;
import 'package:dartclaw_security/dartclaw_security.dart' as security;
import 'package:test/test.dart';

security.GuardChain _buildGuardChain() {
  return security.GuardChain(
    guards: [
      security.InputSanitizer(
        config: security.InputSanitizerConfig(
          enabled: true,
          channelsOnly: false,
          patterns: security.InputSanitizerConfig.defaults().patterns,
        ),
      ),
      security.CommandGuard(),
    ],
  );
}

void main() {
  group('GuardChain cross-package integration', () {
    test('safe channel input and Bash command pass across core/security boundary', () async {
      final guardChain = _buildGuardChain();

      final messageVerdict = await guardChain.evaluateMessageReceived(
        'Please summarize the open tasks for today.',
        source: 'channel',
        sessionId: 'session-safe',
        peerId: 'peer-safe',
      );
      expect(messageVerdict, isA<security.GuardPass>());

      final commandVerdict = await security.CommandGuard().evaluate(
        core.GuardContext(
          hookPoint: 'beforeToolCall',
          toolName: 'Bash',
          toolInput: {'command': 'git status'},
          sessionId: 'session-safe',
          timestamp: DateTime.utc(2026, 3, 13),
        ),
      );
      expect(commandVerdict, isA<security.GuardPass>());
    });

    test('destructive Bash command is blocked by security package guard chain', () async {
      final guardChain = _buildGuardChain();

      final verdict = await guardChain.evaluateBeforeToolCall('Bash', {
        'command': 'rm -rf /tmp/dartclaw-test',
      }, sessionId: 'session-block');

      expect(verdict, isA<security.GuardBlock>());
      expect(verdict.message, contains('destructive command'));
    });
  });
}
