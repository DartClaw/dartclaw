import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart' show ExecutionRequest, ExecutionSurface;
import 'package:dartclaw_runtime/src/mcp/mcp_router.dart';
import 'package:dartclaw_runtime/src/mcp/mcp_server.dart';
import 'package:dartclaw_runtime/src/runtime/harness_wiring.dart';
import 'package:dartclaw_runtime/src/runtime/security_wiring.dart';
import 'package:dartclaw_runtime/src/runtime/storage_wiring.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import 'harness_wiring_fixture.dart';

const _gatewayToken = 'c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1';

final class _NamedTool implements McpTool {
  new(this.name);

  @override
  final String name;

  @override
  String get description => name;

  @override
  Map<String, dynamic> get inputSchema => const {'type': 'object', 'properties': <String, Object?>{}};

  @override
  McpToolAccess get access => McpToolAccess.read;

  @override
  Future<ToolResult> call(Map<String, dynamic> args) async => ToolResult.text('ran $name');
}

/// `tools/list` and `tools/call` for a host harness over the real `/mcp` route and its minted bearers.
void main() {
  late Directory tempDir;
  late DartclawConfig config;
  late EventBus eventBus;
  late List<HarnessFactoryConfig> configs;
  late Handler route;
  StorageWiring? storage;
  SecurityWiring? security;
  HarnessWiring? harnessWiring;

  Never unexpectedExit(int code) => throw StateError('Unexpected exit($code)');

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_harness_mcp_listing_');
    config = DartclawConfig(
      server: ServerConfig(dataDir: tempDir.path, claudeExecutable: Platform.resolvedExecutable),
      agent: const AgentConfig(
        provider: 'claude',
        definitions: [
          AgentDefinition(id: 'closed', description: 'Closed', prompt: 'Work', allowedTools: {'context_research'}),
          AgentDefinition(id: 'open', description: 'Open', prompt: 'Work'),
          AgentDefinition(id: 'denying', description: 'Denying', prompt: 'Work', deniedTools: {'context_research'}),
          AgentDefinition(
            id: 'closed-mcp',
            description: 'Closed with mcp_call',
            prompt: 'Work',
            allowedTools: {'context_research', 'mcp_call'},
          ),
        ],
      ),
      providers: ProvidersConfig(
        entries: {'claude': ProviderEntry(executable: Platform.resolvedExecutable, poolSize: 1)},
      ),
      credentials: const CredentialsConfig(entries: {'anthropic': CredentialEntry(apiKey: 'anthropic-key')}),
      gateway: const GatewayConfig(authMode: 'token', token: _gatewayToken),
      security: const SecurityConfig(contentGuardFailOpen: true),
    );
    eventBus = EventBus();
    configs = [];
    await writeWorkspacePromptFiles(config.workspaceDir);
    storage = await wireTestStorage(config: config, eventBus: eventBus, exitFn: unexpectedExit);
    security = await wireTestSecurity(
      config: config,
      dataDir: tempDir.path,
      eventBus: eventBus,
      exitFn: unexpectedExit,
    );
    final factory = HarnessFactory()
      ..register('claude', (factoryConfig) {
        configs.add(factoryConfig);
        return FakeAgentHarness(promptStrategy: PromptStrategy.append);
      });
    harnessWiring = await wireTestHarness(
      config: config,
      dataDir: tempDir.path,
      harnessFactory: factory,
      exitFn: unexpectedExit,
      storage: storage!,
      security: security!,
      eventBus: eventBus,
      serverRefGetter: () => throw UnimplementedError(),
    );
    // `context_research` is mapped, `kg_add` is not (it reaches the guard as `mcp_call`).
    expect(harnessWiring!.ownMcpToolCanonicals['context_research'], CanonicalTool.contextResearch);
    expect(harnessWiring!.ownMcpToolCanonicals.containsKey('kg_add'), isFalse);
    final handler = McpProtocolHandler()
      ..registerTool(_NamedTool('context_research'))
      ..registerTool(_NamedTool('kg_add'))
      ..registerTool(_NamedTool('task_list'));
    route = mcpRoute(handler, gatewayToken: _gatewayToken, harnessBearers: harnessWiring!.mcpBearers);
  });

  tearDown(() async {
    await harnessWiring?.executions.dispose();
    await security?.dispose();
    await storage?.dispose();
    tempDir.deleteSync(recursive: true);
  });

  Future<String> bearerOfWorkerFor({String? agentId}) async {
    final lease = await harnessWiring!.executions.acquire(
      ExecutionRequest(
        surface: agentId == null ? ExecutionSurface.task : ExecutionSurface.logicalAgent,
        providerId: 'claude',
        policy: const ExecutionPolicy.host(),
        sessionId: 'session-${agentId ?? 'task'}',
        logicalAgentId: agentId,
      ),
    );
    addTearDown(() async => lease?.release());
    return configs.last.harnessConfig.mcpGatewayToken!;
  }

  Future<Map<String, dynamic>> rpc(String bearer, String method, [Map<String, Object?>? params]) async {
    final response = await route(
      Request(
        'POST',
        Uri.parse('http://localhost/mcp'),
        body: jsonEncode({'jsonrpc': '2.0', 'id': 1, 'method': method, 'params': ?params}),
        headers: {'authorization': 'Bearer $bearer', 'content-type': 'application/json'},
      ),
    );
    expect(response.statusCode, 200);
    return jsonDecode(await response.readAsString()) as Map<String, dynamic>;
  }

  Future<List<String>> listed(String bearer) async {
    final result = (await rpc(bearer, 'tools/list'))['result'] as Map<String, dynamic>;
    return [for (final tool in result['tools'] as List) (tool as Map<String, dynamic>)['name'] as String]..sort();
  }

  test('an agent with a closed tools list is listed exactly the DartClaw tools it may call', () async {
    expect(await listed(await bearerOfWorkerFor(agentId: 'closed')), ['context_research']);
  });

  test('naming mcp_call adds the unmapped tools only, not a mapped one such as task_list', () async {
    expect(await listed(await bearerOfWorkerFor(agentId: 'closed-mcp')), ['context_research', 'kg_add']);
  });

  test('an agent without a tools list keeps the full listing', () async {
    expect(await listed(await bearerOfWorkerFor(agentId: 'open')), ['context_research', 'kg_add', 'task_list']);
  });

  test('an agent with only denied_tools has just the denied tool hidden, by the same cascade decision', () async {
    expect(await listed(await bearerOfWorkerFor(agentId: 'denying')), ['kg_add', 'task_list']);
  });

  test('the primary harness and a worker with no logical agent keep the full listing', () async {
    final taskWorker = await bearerOfWorkerFor();

    expect(await listed(configs.first.harnessConfig.mcpGatewayToken!), ['context_research', 'kg_add', 'task_list']);
    expect(await listed(taskWorker), ['context_research', 'kg_add', 'task_list']);
  });

  test('tools/call is not narrowed by the listing: the harness guard still refuses an unlisted tool', () async {
    final bearer = await bearerOfWorkerFor(agentId: 'closed');
    final workerConfig = configs.last;

    final call = await rpc(bearer, 'tools/call', {'name': 'kg_add', 'arguments': <String, Object?>{}});
    expect(call['error'], isNull);
    expect(jsonEncode(call['result']), contains('ran kg_add'));

    final verdict = await workerConfig.guardChain!.evaluateBeforeToolCall(
      CanonicalTool.mcpCall.stableName,
      const <String, dynamic>{},
      agentId: 'closed',
      rawProviderToolName: 'mcp__dartclaw__kg_add',
    );
    expect(verdict.isBlock, isTrue);
  });
}
