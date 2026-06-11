import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/src/mcp/brave_search_tool.dart';
import 'package:dartclaw_server/src/mcp/kg_tools.dart';
import 'package:dartclaw_server/src/mcp/memory_tools.dart';
import 'package:dartclaw_server/src/mcp/onboarding_complete_tool.dart';
import 'package:dartclaw_server/src/mcp/search_provider.dart';
import 'package:dartclaw_server/src/mcp/sessions_send_tool.dart';
import 'package:dartclaw_server/src/mcp/tavily_search_tool.dart';
import 'package:dartclaw_server/src/mcp/web_fetch_tool.dart';
import 'package:dartclaw_storage/dartclaw_storage.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

/// Minimal [SearchProvider] stub for tool instantiation.
class _StubSearchProvider implements SearchProvider {
  @override
  Future<List<SearchResult>> search(String query, {int count = 5}) async => [];
}

SessionDelegate _stubDelegate() => SessionDelegate(
  dispatch: ({required sessionId, required message, required agentId}) async => '',
  limits: SubagentLimits(maxConcurrent: 2, maxSpawnDepth: 1, maxChildrenPerAgent: 2),
  agents: {'search': AgentDefinition.searchAgent()},
);

void main() {
  group('MCP tool schema compliance — additionalProperties: false', () {
    final kgDb = sqlite3.openInMemory();
    final kg = TemporalKnowledgeGraphService(kgDb);

    /// Verifies that an object-type tool inputSchema has additionalProperties: false.
    void expectCompliant(McpTool tool) {
      final schema = tool.inputSchema;
      expect(
        schema['additionalProperties'],
        false,
        reason:
            '${tool.name}.inputSchema must include additionalProperties: false '
            '(required by Anthropic API v1.4.2+ for object-type tool inputs)',
      );
    }

    test('MemorySaveTool', () => expectCompliant(MemorySaveTool(handler: (args) async => {})));

    test('MemorySearchTool', () => expectCompliant(MemorySearchTool(handler: (args) async => {})));

    test('MemoryReadTool', () => expectCompliant(MemoryReadTool(handler: (args) async => {})));

    test('OnboardingCompleteTool', () => expectCompliant(OnboardingCompleteTool(workspaceDir: '/tmp')));

    test('WebFetchTool', () => expectCompliant(WebFetchTool()));

    test('BraveSearchTool', () => expectCompliant(BraveSearchTool(provider: _StubSearchProvider())));

    test('TavilySearchTool', () => expectCompliant(TavilySearchTool(provider: _StubSearchProvider())));

    test('SessionsSendTool', () => expectCompliant(SessionsSendTool(delegate: _stubDelegate())));

    test('KG tools', () {
      expectCompliant(KgAddTool(kg: kg));
      expectCompliant(KgQueryTool(kg: kg));
      expectCompliant(KgTimelineTool(kg: kg));
      expectCompliant(KgInvalidateTool(kg: kg));
      expectCompliant(KgContradictionsTool(kg: kg));
    });

    test('all registered object-type tools have additionalProperties: false (regression guard)', () {
      final tools = <McpTool>[
        MemorySaveTool(handler: (args) async => {}),
        MemorySearchTool(handler: (args) async => {}),
        MemoryReadTool(handler: (args) async => {}),
        OnboardingCompleteTool(workspaceDir: '/tmp'),
        WebFetchTool(),
        BraveSearchTool(provider: _StubSearchProvider()),
        TavilySearchTool(provider: _StubSearchProvider()),
        SessionsSendTool(delegate: _stubDelegate()),
        KgAddTool(kg: kg),
        KgQueryTool(kg: kg),
        KgTimelineTool(kg: kg),
        KgInvalidateTool(kg: kg),
        KgContradictionsTool(kg: kg),
      ];

      for (final tool in tools) {
        final schema = tool.inputSchema;
        if (schema['type'] == 'object') {
          expect(
            schema['additionalProperties'],
            false,
            reason: '${tool.name}.inputSchema missing additionalProperties: false',
          );
        }
      }
    });
  });
}
