import 'dart:io';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_runtime/src/api/sse_broadcast.dart';
import 'package:dartclaw_runtime/src/knowledge/wiki_page_store.dart';
import 'package:dartclaw_runtime/src/mcp/attach_media_tool.dart';
import 'package:dartclaw_runtime/src/mcp/brave_search_tool.dart';
import 'package:dartclaw_runtime/src/mcp/context_research_tool.dart';
import 'package:dartclaw_runtime/src/mcp/kg_tools.dart';
import 'package:dartclaw_runtime/src/mcp/memory_tools.dart';
import 'package:dartclaw_runtime/src/mcp/onboarding_complete_tool.dart';
import 'package:dartclaw_runtime/src/mcp/schedule_tools.dart';
import 'package:dartclaw_runtime/src/mcp/search_provider.dart';
import 'package:dartclaw_runtime/src/mcp/sessions_send_tool.dart';
import 'package:dartclaw_runtime/src/mcp/sessions_spawn_tool.dart';
import 'package:dartclaw_runtime/src/mcp/task_tools.dart';
import 'package:dartclaw_runtime/src/mcp/tavily_search_tool.dart';
import 'package:dartclaw_runtime/src/mcp/web_fetch_tool.dart';
import 'package:dartclaw_runtime/src/mcp/wiki_write_tool.dart';
import 'package:dartclaw_runtime/src/mcp/workflow_tools.dart';
import 'package:dartclaw_runtime/src/scheduling/delivery.dart';
import 'package:dartclaw_runtime/src/scheduling/schedule_mutation.dart';
import 'package:dartclaw_runtime/src/task/task_review_service.dart';
import 'package:dartclaw_runtime/src/task/task_service.dart';
import 'package:dartclaw_runtime/src/workspace/workspace_path_guard.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' show InMemorySessionService, InMemoryTaskRepository;
import 'package:dartclaw_workflow/testing.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import '../api/workflow_test_support.dart';

/// Minimal [SearchProvider] stub for tool instantiation.
class _StubSearchProvider implements SearchProvider {
  @override
  Future<List<SearchResult>> search(String query, {int count = 5}) async => [];
}

class _StubSearchBackend implements SearchBackend {
  @override
  Future<void> indexAfterWrite() async {}

  @override
  Future<MemorySearchOutcome> search(
    String query, {
    int limit = 10,
    String userId = 'owner',
    Set<SearchResultLayer>? layers,
  }) async => const MemorySearchOutcome(results: []);

  @override
  Future<MemorySearchResult?> resolve(String locator, {String userId = 'owner'}) async => null;
}

LogicalAgentSessionService _stubSessions() => LogicalAgentSessionService(
  dispatch: ({required sessionId, required message, required agentId, required createSession}) async => '',
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

    ContextResearchTool contextResearchTool() =>
        ContextResearchTool(memorySearch: _StubSearchBackend(), kg: kg, synthesizer: (_) async => '{}');

    /// The six orchestration and content tools, built over throwaway
    /// collaborators — only their declared schemas are under test here.
    List<McpTool> orchestrationTools() {
      final tempDir = Directory.systemTemp.createTempSync('dartclaw_schema_compliance_');
      addTearDown(() => tempDir.existsSync() ? tempDir.deleteSync(recursive: true) : null);
      final mutations = ScheduleMutationService(
        writer: ConfigWriter(configPath: '${tempDir.path}/dartclaw.yaml'),
        dataDir: tempDir.path,
      );
      final sessions = InMemorySessionService();
      final definitions = InMemoryDefinitionSource(const []);
      return [
        WorkflowRunTool(
          definitions: definitions,
          workflows: FakeWorkflowService(
            db: sqlite3.openInMemory(),
            taskService: TaskService(InMemoryTaskRepository()),
            eventBus: EventBus(),
            dataDir: tempDir.path,
          ),
        ),
        WorkflowListTool(definitions: definitions),
        ScheduleUpsertTool(mutations: mutations),
        ScheduleListTool(mutations: mutations, schedules: null),
        AttachMediaTool(
          workspace: WorkspacePathGuard(tempDir.path),
          delivery: DeliveryService(
            channelManager: ChannelManager(
              queue: MessageQueue(dispatcher: (key, message, {senderJid, senderDisplayName}) async => ''),
              config: const ChannelConfig.defaults(),
            ),
            sseBroadcast: SseBroadcast(),
            sessions: sessions,
          ),
        ),
        WikiWriteTool(wiki: WikiPageStore(workspaceDir: tempDir.path)),
      ];
    }

    List<McpTool> taskTools() {
      final tasks = TaskService(InMemoryTaskRepository());
      addTearDown(tasks.dispose);
      return [
        TaskCreateTool(tasks: tasks),
        TaskReviewTool(reviews: TaskReviewService(tasks: tasks)),
        TaskListTool(tasks: tasks),
        ReviewListTool(tasks: tasks),
        TaskBindTool(tasks: tasks, bindings: null),
        TaskUnbindTool(bindings: null),
      ];
    }

    test('OnboardingCompleteTool', () => expectCompliant(OnboardingCompleteTool(workspaceDir: '/tmp')));

    test('WebFetchTool', () => expectCompliant(WebFetchTool()));

    test('BraveSearchTool', () => expectCompliant(BraveSearchTool(provider: _StubSearchProvider())));

    test('TavilySearchTool', () => expectCompliant(TavilySearchTool(provider: _StubSearchProvider())));

    test('SessionsSendTool', () => expectCompliant(SessionsSendTool(sessions: _stubSessions())));

    test('SessionsSpawnTool', () => expectCompliant(SessionsSpawnTool(sessions: _stubSessions())));

    test('KG tools', () {
      expectCompliant(KgAddTool(kg: kg));
      expectCompliant(KgQueryTool(kg: kg));
      expectCompliant(KgTimelineTool(kg: kg));
      expectCompliant(KgInvalidateTool(kg: kg));
      expectCompliant(KgContradictionsTool(kg: kg));
    });

    test('ContextResearchTool', () {
      expectCompliant(contextResearchTool());
    });

    test('task, review and binding tools', () {
      for (final tool in taskTools()) {
        expectCompliant(tool);
      }
    });

    test('orchestration and content tools', () {
      for (final tool in orchestrationTools()) {
        expectCompliant(tool);
      }
    });

    test('all registered object-type tools have additionalProperties: false (regression guard)', () {
      final tools = <McpTool>[
        MemoryApplyTool(handler: (args) async => {}),
        MemorySearchTool(handler: (args) async => {}),
        MemoryReadTool(handler: (args) async => {}),
        OnboardingCompleteTool(workspaceDir: '/tmp'),
        WebFetchTool(),
        BraveSearchTool(provider: _StubSearchProvider()),
        TavilySearchTool(provider: _StubSearchProvider()),
        SessionsSpawnTool(sessions: _stubSessions()),
        SessionsSendTool(sessions: _stubSessions()),
        KgAddTool(kg: kg),
        KgQueryTool(kg: kg),
        KgTimelineTool(kg: kg),
        KgInvalidateTool(kg: kg),
        KgContradictionsTool(kg: kg),
        contextResearchTool(),
        ...taskTools(),
        ...orchestrationTools(),
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
