import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

void main() {
  group('ToolPolicyCascade', () {
    test('global deny blocks tool regardless of agent allow', () {
      final cascade = ToolPolicyCascade(
        globalDeny: {'Bash'},
        agentAllow: {
          'search': {'Bash', 'WebSearch'},
        },
      );
      expect(cascade.isAllowed('search', 'Bash'), isFalse);
    });

    test('agent deny blocks tool for that agent only', () {
      final cascade = ToolPolicyCascade(
        agentDeny: {
          'search': {'FileRead'},
        },
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
        agentAllow: {
          'search': {'WebSearch', 'WebFetch'},
        },
      );
      expect(cascade.isAllowed('search', 'WebSearch'), isTrue);
      expect(cascade.isAllowed('search', 'WebFetch'), isTrue);
    });

    test('sandbox allow: tool NOT in set is denied', () {
      final cascade = ToolPolicyCascade(
        agentAllow: {
          'search': {'WebSearch', 'WebFetch'},
        },
      );
      expect(cascade.isAllowed('search', 'Bash'), isFalse);
      expect(cascade.isAllowed('search', 'FileRead'), isFalse);
    });

    test('no sandbox for agent allows all tools', () {
      final cascade = ToolPolicyCascade(
        agentAllow: {
          'search': {'WebSearch'},
        },
      );
      // 'main' has no sandbox defined
      expect(cascade.isAllowed('main', 'Bash'), isTrue);
      expect(cascade.isAllowed('main', 'FileRead'), isTrue);
    });

    test('empty sandbox allowlist allows all tools', () {
      final cascade = ToolPolicyCascade(agentAllow: {'worker': {}});

      expect(cascade.isAllowed('worker', 'shell'), isTrue);
    });

    test('cascade: most restrictive wins', () {
      final cascade = ToolPolicyCascade(
        globalDeny: {'DangerousTool'},
        agentDeny: {
          'search': {'SemiDangerous'},
        },
        agentAllow: {
          'search': {'WebSearch', 'DangerousTool', 'SemiDangerous'},
        },
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
        agentAllow: {
          'search': {'WebSearch'},
        },
      );
      expect(cascade.isAllowed('search', 'WebSearch'), isTrue);
    });
  });

  group('ToolPolicyGuard', () {
    test('passes when no active agent', () async {
      final guard = ToolPolicyGuard(
        cascade: ToolPolicyCascade(
          agentAllow: {
            'search': {'WebSearch'},
          },
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
          agentAllow: {
            'search': {'WebSearch'},
          },
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

    test('prefers raw provider tool name over canonical tool name', () async {
      final guard = ToolPolicyGuard(
        cascade: ToolPolicyCascade(
          agentAllow: {
            'search': {'Bash'},
          },
        ),
      );
      final context = GuardContext(
        hookPoint: 'beforeToolCall',
        toolName: 'shell',
        rawProviderToolName: 'Bash',
        toolInput: {},
        agentId: 'search',
        timestamp: DateTime.now(),
      );
      final verdict = await guard.evaluate(context);
      expect(verdict.isPass, isTrue);
    });

    test('allows tool in agent sandbox', () async {
      final guard = ToolPolicyGuard(
        cascade: ToolPolicyCascade(
          agentAllow: {
            'search': {'WebSearch'},
          },
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
          agentAllow: {
            'search': {'WebSearch'},
          },
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

    test('canonical allowlist admits Claude WebSearch', () async {
      final guard = ToolPolicyGuard(
        cascade: ToolPolicyCascade(
          agentAllow: {
            'search': {'web_search', 'web_fetch'},
          },
        ),
      );
      final verdict = await guard.evaluate(
        GuardContext(
          hookPoint: 'beforeToolCall',
          toolName: 'web_search',
          rawProviderToolName: 'WebSearch',
          toolInput: const {},
          agentId: 'search',
          timestamp: DateTime.now(),
        ),
      );
      expect(verdict.isPass, isTrue);
    });

    test('canonical allowlist blocks Bash and reports the raw name', () async {
      final guard = ToolPolicyGuard(
        cascade: ToolPolicyCascade(
          agentAllow: {
            'search': {'web_search', 'web_fetch'},
          },
        ),
      );
      final verdict = await guard.evaluate(
        GuardContext(
          hookPoint: 'beforeToolCall',
          toolName: 'shell',
          rawProviderToolName: 'Bash',
          toolInput: const {},
          agentId: 'search',
          timestamp: DateTime.now(),
        ),
      );
      expect(verdict.message, 'Tool "Bash" not allowed for agent "search"');
    });

    test('Claude adapter keeps session tools outside the search allowlist', () async {
      final adapter = ClaudeProtocolAdapter();
      final guard = ToolPolicyGuard(
        cascade: ToolPolicyCascade(
          agentAllow: {
            'search': {'web_search', 'web_fetch'},
          },
        ),
      );

      for (final tool in ['sessions_spawn', 'sessions_send']) {
        final rawToolName = 'mcp__dartclaw__$tool';
        final canonicalToolName = adapter.mapToolName(rawToolName)!.stableName;
        final verdict = await guard.evaluate(
          GuardContext(
            hookPoint: 'beforeToolCall',
            toolName: canonicalToolName,
            rawProviderToolName: rawToolName,
            toolInput: const {},
            agentId: 'search',
            timestamp: DateTime.now(),
          ),
        );

        expect(canonicalToolName, 'mcp_call', reason: tool);
        expect(verdict.isBlock, isTrue, reason: tool);
        expect(verdict.message, 'Tool "$rawToolName" not allowed for agent "search"');
      }
    });
  });

  group('raw and canonical policy matching', () {
    test('raw provider entries admit semantically equivalent MCP tools', () {
      final cascade = ToolPolicyCascade(
        agentAllow: {
          'search': {'WebSearch'},
        },
      );

      expect(cascade.isAllowed('search', 'web_search', rawProviderToolName: 'WebSearch'), isTrue);
      expect(cascade.isAllowed('search', 'web_search', rawProviderToolName: 'mcp__dartclaw__brave_search'), isTrue);
    });

    test('known raw deny entries normalize while exact MCP entries stay literal', () {
      final normalizedDeny = ToolPolicyCascade(globalDeny: {'WebFetch'});
      expect(normalizedDeny.isAllowed('search', 'web_fetch', rawProviderToolName: 'mcp__dartclaw__web_fetch'), isFalse);

      final exactAllow = ToolPolicyCascade(
        agentAllow: {
          'search': {'mcp__dartclaw__web_fetch'},
        },
      );
      expect(exactAllow.isAllowed('search', 'web_fetch', rawProviderToolName: 'mcp__dartclaw__web_fetch'), isTrue);
      expect(exactAllow.isAllowed('search', 'web_search', rawProviderToolName: 'mcp__dartclaw__brave_search'), isFalse);
    });

    test('deny mcp_call covers semantic own tools but allow mcp_call does not grant them', () {
      final denied = ToolPolicyCascade(globalDeny: {'mcp_call'});
      expect(denied.isAllowed('search', 'web_fetch', rawProviderToolName: 'mcp__dartclaw__web_fetch'), isFalse);

      final allowed = ToolPolicyCascade(
        agentAllow: {
          'search': {'mcp_call'},
        },
      );
      expect(allowed.isAllowed('search', 'web_fetch', rawProviderToolName: 'mcp__dartclaw__web_fetch'), isFalse);
    });

    test('Claude discovery can load an allowlisted tool without granting other tools', () {
      final cascade = ToolPolicyCascade(
        agentAllow: {
          'search': {'web_search'},
        },
      );

      expect(cascade.isAllowed('search', 'claude:ToolSearch', rawProviderToolName: 'ToolSearch'), isTrue);
      expect(cascade.isAllowed('search', 'web_search', rawProviderToolName: 'WebSearch'), isTrue);
      expect(cascade.isAllowed('search', 'web_fetch', rawProviderToolName: 'WebFetch'), isFalse);
    });

    test('explicit denies still block Claude discovery', () {
      final globallyDenied = ToolPolicyCascade(
        globalDeny: {'ToolSearch'},
        agentAllow: {
          'search': {'web_search'},
        },
      );
      final agentDenied = ToolPolicyCascade(
        agentDeny: {
          'search': {'claude:ToolSearch'},
        },
        agentAllow: {
          'search': {'web_search'},
        },
      );

      expect(globallyDenied.isAllowed('search', 'claude:ToolSearch', rawProviderToolName: 'ToolSearch'), isFalse);
      expect(agentDenied.isAllowed('search', 'claude:ToolSearch', rawProviderToolName: 'ToolSearch'), isFalse);
    });

    test('identified agent without a sandbox remains fail-open except for global denies', () {
      final cascade = ToolPolicyCascade(globalDeny: {'shell'});
      expect(cascade.isAllowed('cron:x', 'web_fetch'), isTrue);
      expect(cascade.isAllowed('cron:x', 'shell', rawProviderToolName: 'Bash'), isFalse);
    });
  });
}
