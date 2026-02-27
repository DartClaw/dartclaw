import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

void main() {
  group('ToolPolicyCascade', () {
    test('global deny blocks tool regardless of agent allow', () {
      final cascade = ToolPolicyCascade(
        globalDeny: {'Bash'},
        agentAllow: {'search': {'Bash', 'WebSearch'}},
      );
      expect(cascade.isAllowed('search', 'Bash'), isFalse);
    });

    test('agent deny blocks tool for that agent only', () {
      final cascade = ToolPolicyCascade(
        agentDeny: {'search': {'FileRead'}},
        agentAllow: {
          'search': {'WebSearch', 'FileRead'},
          'main': {'FileRead', 'WebSearch'},
        },
      );
      expect(cascade.isAllowed('search', 'FileRead'), isFalse);
      expect(cascade.isAllowed('main', 'FileRead'), isTrue);
    });

    test('sandbox allow: tool in set passes', () {
      final cascade = ToolPolicyCascade(
        agentAllow: {'search': {'WebSearch', 'WebFetch'}},
      );
      expect(cascade.isAllowed('search', 'WebSearch'), isTrue);
      expect(cascade.isAllowed('search', 'WebFetch'), isTrue);
    });

    test('sandbox allow: tool NOT in set is denied', () {
      final cascade = ToolPolicyCascade(
        agentAllow: {'search': {'WebSearch', 'WebFetch'}},
      );
      expect(cascade.isAllowed('search', 'Bash'), isFalse);
      expect(cascade.isAllowed('search', 'FileRead'), isFalse);
    });

    test('no sandbox for agent allows all tools', () {
      final cascade = ToolPolicyCascade(
        agentAllow: {'search': {'WebSearch'}},
      );
      // 'main' has no sandbox defined
      expect(cascade.isAllowed('main', 'Bash'), isTrue);
      expect(cascade.isAllowed('main', 'FileRead'), isTrue);
    });

    test('cascade: most restrictive wins', () {
      final cascade = ToolPolicyCascade(
        globalDeny: {'DangerousTool'},
        agentDeny: {'search': {'SemiDangerous'}},
        agentAllow: {'search': {'WebSearch', 'DangerousTool', 'SemiDangerous'}},
      );
      // DangerousTool: in allow set but globally denied
      expect(cascade.isAllowed('search', 'DangerousTool'), isFalse);
      // SemiDangerous: in allow set but agent-denied
      expect(cascade.isAllowed('search', 'SemiDangerous'), isFalse);
      // WebSearch: in allow set, not denied
      expect(cascade.isAllowed('search', 'WebSearch'), isTrue);
    });

    test('empty global deny + empty agent deny + tool in allow passes', () {
      final cascade = ToolPolicyCascade(
        agentAllow: {'search': {'WebSearch'}},
      );
      expect(cascade.isAllowed('search', 'WebSearch'), isTrue);
    });
  });

  group('ToolPolicyGuard', () {
    test('passes when no active agent', () async {
      final guard = ToolPolicyGuard(
        cascade: ToolPolicyCascade(
          agentAllow: {'search': {'WebSearch'}},
        ),
      );
      final context = GuardContext(
        hookPoint: 'beforeToolCall',
        toolName: 'Bash',
        toolInput: {},
        timestamp: DateTime.now(),
      );
      final verdict = await guard.evaluate(context);
      expect(verdict.isPass, isTrue);
    });

    test('blocks tool not in agent sandbox', () async {
      final guard = ToolPolicyGuard(
        cascade: ToolPolicyCascade(
          agentAllow: {'search': {'WebSearch'}},
        ),
      );
      final context = GuardContext(
        hookPoint: 'beforeToolCall',
        toolName: 'Bash',
        toolInput: {},
        agentId: 'search',
        timestamp: DateTime.now(),
      );
      final verdict = await guard.evaluate(context);
      expect(verdict.isBlock, isTrue);
    });

    test('allows tool in agent sandbox', () async {
      final guard = ToolPolicyGuard(
        cascade: ToolPolicyCascade(
          agentAllow: {'search': {'WebSearch'}},
        ),
      );
      final context = GuardContext(
        hookPoint: 'beforeToolCall',
        toolName: 'WebSearch',
        toolInput: {},
        agentId: 'search',
        timestamp: DateTime.now(),
      );
      final verdict = await guard.evaluate(context);
      expect(verdict.isPass, isTrue);
    });

    test('passes non-beforeToolCall hooks', () async {
      final guard = ToolPolicyGuard(
        cascade: ToolPolicyCascade(
          agentAllow: {'search': {'WebSearch'}},
        ),
      );
      final context = GuardContext(
        hookPoint: 'messageReceived',
        messageContent: 'test',
        agentId: 'search',
        timestamp: DateTime.now(),
      );
      final verdict = await guard.evaluate(context);
      expect(verdict.isPass, isTrue);
    });
  });
}
