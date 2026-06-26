@Tags(['integration'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_cli/src/commands/service_wiring.dart';
import 'package:dartclaw_core/dartclaw_core.dart' hide GoogleJwtVerifier, HarnessPool, TurnManager, TurnRunner;
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' hide GoogleJwtVerifier, HarnessPool, TurnManager, TurnRunner;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

String _staticDir() {
  const fromPkg = 'packages/dartclaw_server/lib/src/static';
  if (Directory(fromPkg).existsSync()) return fromPkg;
  return p.join('..', '..', 'packages', 'dartclaw_server', 'lib', 'src', 'static');
}

String _templatesDir() {
  const fromWorkspace = 'packages/dartclaw_server/lib/src/templates';
  if (Directory(fromWorkspace).existsSync()) return fromWorkspace;
  return p.join('..', '..', 'packages', 'dartclaw_server', 'lib', 'src', 'templates');
}

HarnessFactory _harnessFactoryFor(AgentHarness harness) {
  final factory = HarnessFactory();
  factory.register('claude', (_) => harness);
  return factory;
}

void _runGit(String workingDirectory, List<String> args) {
  final result = Process.runSync('git', args, workingDirectory: workingDirectory);
  if (result.exitCode != 0) {
    fail('git ${args.join(' ')} failed in $workingDirectory: ${result.stderr}');
  }
}

/// Stages skeletal provider-owned AndThen skills under [searchRoot] so
/// provider-native skill roots exist for tests that exercise invocation paths.
void _stageProviderAndThenSkillStubs(String searchRoot) {
  const refs = [
    'andthen:prd',
    'andthen:plan',
    'andthen:spec',
    'andthen:exec-spec',
    'andthen:review',
    'andthen:remediate-findings',
    'andthen:quick-review',
    'andthen:ops',
    'andthen:architecture',
    'andthen:simplify-code',
  ];
  for (final ref in refs) {
    final codexAlias = ref.replaceFirst('andthen:', 'andthen-');
    for (final entry in [(tier: '.claude/skills', name: ref), (tier: '.agents/skills', name: codexAlias)]) {
      File(p.join(searchRoot, entry.tier, entry.name, 'SKILL.md'))
        ..createSync(recursive: true)
        ..writeAsStringSync('---\nname: "${entry.name}"\n---\nbody\n');
    }
  }
}

ResolvedAssets _resolvedAssetsForConfig(DartclawConfig config) => ResolvedAssets.fromSourceTree(
  templatesDir: config.server.templatesDir,
  staticDir: config.server.staticDir,
  source: AssetSource.sourceTreeDefault,
);

Never _unexpectedExit(int code) {
  throw StateError('Unexpected exit($code) during server builder integration test');
}

class _RecordingChannel extends Channel {
  final List<(String, ChannelResponse)> sent = [];

  @override
  String get name => 'recording-googlechat';

  @override
  ChannelType get type => ChannelType.googlechat;

  @override
  Future<void> connect() async {}

  @override
  Future<void> disconnect() async {}

  @override
  bool ownsJid(String jid) => true;

  @override
  Future<void> sendMessage(String recipientJid, ChannelResponse response) async {
    sent.add((recipientJid, response));
  }
}

final class _FakeOutboundTransport implements OutboundMcpTransport {
  final List<Map<String, dynamic>> tools;
  final List<({String toolName, Map<String, dynamic> arguments})> calls = [];
  final int failedToolsListResponses;
  final bool rejectDuplicateInitialize;
  final bool throwOnClose;
  var closed = false;
  var closeCount = 0;
  var initializeRequests = 0;
  var toolsListRequests = 0;

  _FakeOutboundTransport({
    required this.tools,
    this.failedToolsListResponses = 0,
    this.rejectDuplicateInitialize = false,
    this.throwOnClose = false,
  });

  @override
  Future<Map<String, dynamic>> sendRequest(
    String method,
    Map<String, dynamic> params, {
    required Duration timeout,
    required int maxResponseBytes,
  }) async {
    if (closed) {
      throw StateError('Unexpected MCP request after transport close: $method');
    }
    if (method == 'initialize') {
      initializeRequests++;
      if (rejectDuplicateInitialize && initializeRequests > 1) {
        throw StateError('Duplicate initialize on the same transport');
      }
      return const {};
    }
    if (method == 'tools/list') {
      toolsListRequests++;
      if (toolsListRequests <= failedToolsListResponses) {
        throw const OutboundMcpException('startup_list_failed', 'startup list failed');
      }
      return {'tools': tools};
    }
    if (method == 'tools/call') {
      calls.add((toolName: params['name'] as String, arguments: Map<String, dynamic>.from(params['arguments'] as Map)));
      final args = params['arguments'] as Map;
      return {
        'content': [
          {'type': 'text', 'text': '${params['name']}:${args['id'] ?? 'ok'}'},
        ],
      };
    }
    throw StateError('Unexpected MCP method: $method');
  }

  @override
  Future<void> sendNotification(
    String method,
    Map<String, dynamic> params, {
    required Duration timeout,
    required int maxResponseBytes,
  }) async {}

  @override
  Future<bool> ping({required Duration timeout, required int maxResponseBytes}) async => true;

  @override
  Future<void> close() async {
    closed = true;
    closeCount++;
    if (throwOnClose) {
      throw StateError('transport close failed');
    }
  }
}

final class _NamedTool implements McpTool {
  @override
  final String name;

  _NamedTool(this.name);

  @override
  String get description => 'test duplicate';

  @override
  Map<String, dynamic> get inputSchema => const {'type': 'object'};

  @override
  Future<ToolResult> call(Map<String, dynamic> args) async => ToolResult.text('ok');
}

Future<void> _disposeWiringResult(WiringResult result, LogService logService, {bool disposeExtras = true}) async {
  await result.server.shutdown();
  if (disposeExtras) {
    await result.shutdownExtras();
  }
  result.heartbeat?.stop();
  result.scheduleService?.stop();
  result.resetService.dispose();
  await result.kvService.dispose();
  await result.selfImprovement.dispose();
  await result.taskService.dispose();
  await result.eventBus.dispose();
  await result.qmdManager?.stop();
  result.searchDb.close();
  await logService.dispose();
}

String _mcpRequest(String method, {Object? id, Map<String, dynamic>? params}) {
  return jsonEncode({
    'jsonrpc': '2.0',
    'method': method,
    if (id != null) 'id': id, // ignore: use_null_aware_elements
    if (params != null) 'params': params, // ignore: use_null_aware_elements
  });
}

Future<Set<String>> _mcpToolNames(DartclawServer server) async {
  final raw = await server.mcpHandler.handleRequest(_mcpRequest('tools/list', id: 1));
  final body = jsonDecode(raw!) as Map<String, dynamic>;
  final result = body['result'] as Map<String, dynamic>;
  return ((result['tools'] as List).cast<Map<String, dynamic>>()).map((tool) => tool['name'] as String).toSet();
}

DartclawConfig _baseConfig(Directory tempDir, {McpServersConfig mcpServers = const McpServersConfig.defaults()}) {
  return DartclawConfig(
    agent: const AgentConfig(provider: 'claude'),
    credentials: const CredentialsConfig(entries: {'anthropic': CredentialEntry(apiKey: 'anthropic-key')}),
    providers: ProvidersConfig(
      entries: {'claude': ProviderEntry(executable: Platform.resolvedExecutable, poolSize: 0)},
    ),
    gateway: const GatewayConfig(authMode: 'none'),
    mcpServers: mcpServers,
    server: ServerConfig(
      dataDir: tempDir.path,
      staticDir: _staticDir(),
      templatesDir: _templatesDir(),
      claudeExecutable: Platform.resolvedExecutable,
    ),
  );
}

void main() {
  late Directory tempDir;
  late File configFile;
  late FakeAgentHarness worker;
  late MessageRedactor messageRedactor;
  late LogService logService;

  setUpAll(() => initTemplates(_templatesDir()));

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_server_builder_integration_');
    configFile = File(p.join(tempDir.path, 'dartclaw.yaml'))..writeAsStringSync('# test config\n');
    worker = FakeAgentHarness();

    messageRedactor = MessageRedactor();
    logService = LogService.fromConfig(
      format: 'human',
      level: 'INFO',
      redactor: LogRedactor(redactor: messageRedactor),
    );
  });

  tearDown(() async {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  test('ServiceWiring builds a server that serves / and /health', () async {
    final config = DartclawConfig(
      agent: const AgentConfig(provider: 'claude'),
      credentials: const CredentialsConfig(entries: {'anthropic': CredentialEntry(apiKey: 'anthropic-key')}),
      providers: ProvidersConfig(
        entries: {'claude': ProviderEntry(executable: Platform.resolvedExecutable, poolSize: 0)},
      ),
      gateway: const GatewayConfig(authMode: 'none'),
      server: ServerConfig(
        dataDir: tempDir.path,
        staticDir: _staticDir(),
        templatesDir: _templatesDir(),
        claudeExecutable: Platform.resolvedExecutable,
      ),
    );

    final wiring = ServiceWiring(
      config: config,
      dataDir: tempDir.path,
      port: 3000,
      harnessFactory: _harnessFactoryFor(worker),
      serverFactory: (builder) => builder.build(),
      searchDbFactory: (_) => sqlite3.openInMemory(),
      taskDbFactory: (_) => sqlite3.openInMemory(),
      stderrLine: (_) {},
      exitFn: _unexpectedExit,
      resolvedConfigPath: configFile.path,
      logService: logService,
      messageRedactor: messageRedactor,
      resolvedAssets: _resolvedAssetsForConfig(config),
      runAndthenSkillsBootstrap: false,
    );

    final result = await wiring.wire();
    addTearDown(() => _disposeWiringResult(result, logService));
    await result.agentExecutionRepository.create(
      AgentExecution(
        id: 'ae-1',
        provider: 'claude',
        sessionId: 'sess-1',
        startedAt: DateTime.parse('2026-04-19T00:00:00Z'),
      ),
    );
    expect(await result.agentExecutionRepository.get('ae-1'), isNotNull);

    final handler = result.server.handler;

    final rootResponse = await handler(Request('GET', Uri.parse('http://localhost/')));
    expect(rootResponse.statusCode, equals(302));
    expect(rootResponse.headers['location'], startsWith('/sessions/'));

    final healthResponse = await handler(Request('GET', Uri.parse('http://localhost/health')));
    expect(healthResponse.statusCode, equals(200));

    final healthBody = jsonDecode(await healthResponse.readAsString()) as Map<String, dynamic>;
    expect(healthBody['status'], equals('healthy'));

    final toolNames = await _mcpToolNames(result.server);
    expect(toolNames, contains('sessions_send'));
    expect(toolNames, contains('context_research'));
    expect(toolNames, isNot(contains('sessions_spawn')));
  });

  test('ServiceWiring registers surfaced outbound MCP tools on the live MCP handler', () async {
    final transport = _FakeOutboundTransport(
      tools: const [
        {
          'name': 'lookup',
          'description': 'Lookup records',
          'inputSchema': {
            'type': 'object',
            'properties': {
              'id': {'type': 'string'},
            },
          },
        },
        {'name': 'delete_all'},
      ],
    );
    final config = DartclawConfig(
      agent: const AgentConfig(provider: 'claude'),
      credentials: const CredentialsConfig(entries: {'anthropic': CredentialEntry(apiKey: 'anthropic-key')}),
      providers: ProvidersConfig(
        entries: {'claude': ProviderEntry(executable: Platform.resolvedExecutable, poolSize: 0)},
      ),
      gateway: const GatewayConfig(authMode: 'none'),
      mcpServers: const McpServersConfig(
        entries: {
          'acme': McpServerEntry(
            command: 'fake-acme',
            networkClass: McpNetworkClass.local,
            allowTools: ['lookup', 'delete_all'],
            surfaceTools: ['lookup'],
          ),
        },
      ),
      server: ServerConfig(
        dataDir: tempDir.path,
        staticDir: _staticDir(),
        templatesDir: _templatesDir(),
        claudeExecutable: Platform.resolvedExecutable,
      ),
    );
    final wiring = ServiceWiring(
      config: config,
      dataDir: tempDir.path,
      port: 3000,
      harnessFactory: _harnessFactoryFor(worker),
      serverFactory: (builder) => builder.build(),
      searchDbFactory: (_) => sqlite3.openInMemory(),
      taskDbFactory: (_) => sqlite3.openInMemory(),
      stderrLine: (_) {},
      exitFn: _unexpectedExit,
      resolvedConfigPath: configFile.path,
      logService: logService,
      messageRedactor: messageRedactor,
      resolvedAssets: _resolvedAssetsForConfig(config),
      outboundMcpTransportFactory: (server, options) async {
        expect(server.name, 'acme');
        return transport;
      },
      runAndthenSkillsBootstrap: false,
    );

    final result = await wiring.wire();
    addTearDown(() => _disposeWiringResult(result, logService, disposeExtras: false));

    final toolNames = await _mcpToolNames(result.server);
    expect(toolNames, contains('mcp__acme__lookup'));
    expect(toolNames, isNot(contains('mcp__acme__delete_all')));

    final response = await result.server.mcpHandler.handleRequest(
      _mcpRequest(
        'tools/call',
        id: 2,
        params: {
          'name': 'mcp__acme__lookup',
          'arguments': {'id': '42'},
        },
      ),
    );
    final body = jsonDecode(response!) as Map<String, dynamic>;
    final callResult = body['result'] as Map<String, dynamic>;
    final content = callResult['content'] as List;
    expect(content.single['text'], 'lookup:42');
    expect(transport.calls.single.toolName, 'lookup');
    expect(transport.calls.single.arguments, {'id': '42'});

    final direct = await result.outboundMcpPool!.callTool(
      serverName: 'acme',
      toolName: 'delete_all',
      arguments: const {},
      caller: const OutboundMcpCaller(sessionId: 'session-1', principal: 'operator'),
    );
    expect(direct.isSuccess, isTrue);
    expect(direct.content.single['text'], 'delete_all:ok');

    await result.shutdownExtras();
    expect(transport.closed, isTrue);
  });

  test('ServiceWiring preserves outbound MCP startup errors when cleanup close fails', () async {
    final transport = _FakeOutboundTransport(
      tools: const [
        {'name': 'delete_all'},
      ],
      throwOnClose: true,
    );
    final config = _baseConfig(
      tempDir,
      mcpServers: const McpServersConfig(
        entries: {
          'acme': McpServerEntry(
            command: 'fake-acme',
            networkClass: McpNetworkClass.local,
            allowTools: ['lookup'],
            surfaceTools: ['lookup'],
          ),
        },
      ),
    );
    final wiring = ServiceWiring(
      config: config,
      dataDir: tempDir.path,
      port: 3000,
      harnessFactory: _harnessFactoryFor(worker),
      serverFactory: (builder) => builder.build(),
      searchDbFactory: (_) => sqlite3.openInMemory(),
      taskDbFactory: (_) => sqlite3.openInMemory(),
      stderrLine: (_) {},
      exitFn: _unexpectedExit,
      resolvedConfigPath: configFile.path,
      logService: logService,
      messageRedactor: messageRedactor,
      resolvedAssets: _resolvedAssetsForConfig(config),
      outboundMcpTransportFactory: (server, options) async => transport,
      runAndthenSkillsBootstrap: false,
    );

    await expectLater(
      wiring.wire(),
      throwsA(
        isA<StateError>()
            .having((error) => error.message, 'message', contains('acme'))
            .having((error) => error.message, 'message', contains('lookup'))
            .having((error) => error.message, 'message', isNot(contains('transport close failed'))),
      ),
    );
    expect(transport.closed, isTrue);
  });

  test('ServiceWiring keeps direct outbound policy when startup listing fails', () async {
    final transports = <_FakeOutboundTransport>[];
    final config = DartclawConfig(
      agent: const AgentConfig(provider: 'claude'),
      credentials: const CredentialsConfig(entries: {'anthropic': CredentialEntry(apiKey: 'anthropic-key')}),
      providers: ProvidersConfig(
        entries: {'claude': ProviderEntry(executable: Platform.resolvedExecutable, poolSize: 0)},
      ),
      gateway: const GatewayConfig(authMode: 'none'),
      mcpServers: const McpServersConfig(
        entries: {
          'acme': McpServerEntry(
            command: 'fake-acme',
            networkClass: McpNetworkClass.local,
            allowTools: ['delete_all'],
            surfaceTools: ['lookup'],
          ),
        },
      ),
      server: ServerConfig(
        dataDir: tempDir.path,
        staticDir: _staticDir(),
        templatesDir: _templatesDir(),
        claudeExecutable: Platform.resolvedExecutable,
      ),
    );
    final wiring = ServiceWiring(
      config: config,
      dataDir: tempDir.path,
      port: 3000,
      harnessFactory: _harnessFactoryFor(worker),
      serverFactory: (builder) => builder.build(),
      searchDbFactory: (_) => sqlite3.openInMemory(),
      taskDbFactory: (_) => sqlite3.openInMemory(),
      stderrLine: (_) {},
      exitFn: _unexpectedExit,
      resolvedConfigPath: configFile.path,
      logService: logService,
      messageRedactor: messageRedactor,
      resolvedAssets: _resolvedAssetsForConfig(config),
      outboundMcpTransportFactory: (server, options) async {
        final transport = _FakeOutboundTransport(
          tools: const [
            {'name': 'delete_all'},
          ],
          failedToolsListResponses: transports.isEmpty ? 1 : 0,
          rejectDuplicateInitialize: true,
        );
        transports.add(transport);
        return transport;
      },
      runAndthenSkillsBootstrap: false,
    );

    final result = await wiring.wire();
    addTearDown(() => _disposeWiringResult(result, logService, disposeExtras: false));

    expect(await _mcpToolNames(result.server), isNot(contains('mcp__acme__lookup')));

    final direct = await result.outboundMcpPool!.callTool(
      serverName: 'acme',
      toolName: 'delete_all',
      arguments: const {},
      caller: const OutboundMcpCaller(sessionId: 'session-1', principal: 'operator'),
    );
    expect(direct.isSuccess, isTrue);
    expect(transports, hasLength(2));
    expect(transports.first.closed, isTrue);
    expect(transports.last.calls.single.toolName, 'delete_all');

    await result.shutdownExtras();
  });

  test('ServiceWiring does not connect direct-only outbound MCP servers during startup', () async {
    var factoryCalls = 0;
    final transport = _FakeOutboundTransport(
      tools: const [
        {'name': 'delete_all'},
      ],
    );
    final config = DartclawConfig(
      agent: const AgentConfig(provider: 'claude'),
      credentials: const CredentialsConfig(entries: {'anthropic': CredentialEntry(apiKey: 'anthropic-key')}),
      providers: ProvidersConfig(
        entries: {'claude': ProviderEntry(executable: Platform.resolvedExecutable, poolSize: 0)},
      ),
      gateway: const GatewayConfig(authMode: 'none'),
      mcpServers: const McpServersConfig(
        entries: {
          'acme': McpServerEntry(
            command: 'fake-acme',
            networkClass: McpNetworkClass.local,
            allowTools: ['delete_all'],
            surfaceTools: [],
          ),
        },
      ),
      server: ServerConfig(
        dataDir: tempDir.path,
        staticDir: _staticDir(),
        templatesDir: _templatesDir(),
        claudeExecutable: Platform.resolvedExecutable,
      ),
    );
    final wiring = ServiceWiring(
      config: config,
      dataDir: tempDir.path,
      port: 3000,
      harnessFactory: _harnessFactoryFor(worker),
      serverFactory: (builder) => builder.build(),
      searchDbFactory: (_) => sqlite3.openInMemory(),
      taskDbFactory: (_) => sqlite3.openInMemory(),
      stderrLine: (_) {},
      exitFn: _unexpectedExit,
      resolvedConfigPath: configFile.path,
      logService: logService,
      messageRedactor: messageRedactor,
      resolvedAssets: _resolvedAssetsForConfig(config),
      outboundMcpTransportFactory: (server, options) async {
        factoryCalls++;
        expect(server.name, 'acme');
        return transport;
      },
      runAndthenSkillsBootstrap: false,
    );

    final result = await wiring.wire();
    addTearDown(() => _disposeWiringResult(result, logService, disposeExtras: false));

    expect(factoryCalls, 0);
    expect(await _mcpToolNames(result.server), isNot(contains('mcp__acme__delete_all')));

    final direct = await result.outboundMcpPool!.callTool(
      serverName: 'acme',
      toolName: 'delete_all',
      arguments: const {},
      caller: const OutboundMcpCaller(sessionId: 'session-1', principal: 'operator'),
    );
    expect(direct.isSuccess, isTrue);
    expect(factoryCalls, 1);
    expect(transport.calls.single.toolName, 'delete_all');

    await result.shutdownExtras();
  });

  test('ServiceWiring fails when surfaced outbound MCP tool is not exposed', () async {
    final transport = _FakeOutboundTransport(
      tools: const [
        {'name': 'delete_all'},
      ],
    );
    final config = _baseConfig(
      tempDir,
      mcpServers: const McpServersConfig(
        entries: {
          'acme': McpServerEntry(
            command: 'fake-acme',
            networkClass: McpNetworkClass.local,
            allowTools: ['lookup'],
            surfaceTools: ['lookup'],
          ),
        },
      ),
    );
    final wiring = ServiceWiring(
      config: config,
      dataDir: tempDir.path,
      port: 3000,
      harnessFactory: _harnessFactoryFor(worker),
      serverFactory: (builder) => builder.build(),
      searchDbFactory: (_) => sqlite3.openInMemory(),
      taskDbFactory: (_) => sqlite3.openInMemory(),
      stderrLine: (_) {},
      exitFn: _unexpectedExit,
      resolvedConfigPath: configFile.path,
      logService: logService,
      messageRedactor: messageRedactor,
      resolvedAssets: _resolvedAssetsForConfig(config),
      outboundMcpTransportFactory: (server, options) async => transport,
      runAndthenSkillsBootstrap: false,
    );

    await expectLater(
      wiring.wire(),
      throwsA(
        isA<StateError>()
            .having((error) => error.message, 'message', contains('acme'))
            .having((error) => error.message, 'message', contains('lookup')),
      ),
    );
    expect(transport.closed, isTrue);
  });

  test('ServiceWiring closes the outbound MCP pool when later startup fails', () async {
    final transport = _FakeOutboundTransport(
      tools: const [
        {'name': 'lookup'},
      ],
      throwOnClose: true,
    );
    final config = _baseConfig(
      tempDir,
      mcpServers: const McpServersConfig(
        entries: {
          'acme': McpServerEntry(
            command: 'fake-acme',
            networkClass: McpNetworkClass.local,
            allowTools: ['lookup'],
            surfaceTools: ['lookup'],
          ),
        },
      ),
    );
    final wiring = ServiceWiring(
      config: config,
      dataDir: tempDir.path,
      port: 3000,
      harnessFactory: _harnessFactoryFor(worker),
      serverFactory: (builder) => builder.build(),
      searchDbFactory: (_) => sqlite3.openInMemory(),
      taskDbFactory: (_) => sqlite3.openInMemory(),
      stderrLine: (_) {},
      exitFn: _unexpectedExit,
      resolvedConfigPath: configFile.path,
      logService: logService,
      messageRedactor: messageRedactor,
      resolvedAssets: _resolvedAssetsForConfig(config),
      outboundMcpTransportFactory: (server, options) async => transport,
      postMcpStartupHook: (_) async => throw StateError('post-registration startup failed'),
      runAndthenSkillsBootstrap: false,
    );

    await expectLater(
      wiring.wire(),
      throwsA(
        isA<StateError>()
            .having((error) => error.message, 'message', contains('post-registration'))
            .having((error) => error.message, 'message', isNot(contains('transport close failed'))),
      ),
    );
    expect(transport.closeCount, 1);
  });

  test('ServiceWiring returns handled errors for live denied outbound MCP calls', () async {
    final transport = _FakeOutboundTransport(
      tools: const [
        {'name': 'lookup'},
        {'name': 'allowed'},
      ],
    );
    final config = _baseConfig(
      tempDir,
      mcpServers: const McpServersConfig(
        entries: {
          'acme': McpServerEntry(
            command: 'fake-acme',
            networkClass: McpNetworkClass.local,
            allowTools: ['allowed'],
            surfaceTools: ['lookup', 'allowed'],
          ),
        },
      ),
    );
    final wiring = ServiceWiring(
      config: config,
      dataDir: tempDir.path,
      port: 3000,
      harnessFactory: _harnessFactoryFor(worker),
      serverFactory: (builder) => builder.build(),
      searchDbFactory: (_) => sqlite3.openInMemory(),
      taskDbFactory: (_) => sqlite3.openInMemory(),
      stderrLine: (_) {},
      exitFn: _unexpectedExit,
      resolvedConfigPath: configFile.path,
      logService: logService,
      messageRedactor: messageRedactor,
      resolvedAssets: _resolvedAssetsForConfig(config),
      outboundMcpTransportFactory: (server, options) async => transport,
      runAndthenSkillsBootstrap: false,
    );

    final result = await wiring.wire();
    addTearDown(() => _disposeWiringResult(result, logService, disposeExtras: false));

    final deniedResponse = await result.server.mcpHandler.handleRequest(
      _mcpRequest(
        'tools/call',
        id: 2,
        params: {
          'name': 'mcp__acme__lookup',
          'arguments': {'id': '42'},
        },
      ),
    );
    final deniedBody = jsonDecode(deniedResponse!) as Map<String, dynamic>;
    final deniedResult = deniedBody['result'] as Map<String, dynamic>;
    expect(deniedResult['isError'], isTrue);
    expect((deniedResult['content'] as List).single['text'], contains('not allowlisted'));
    expect(transport.calls, isEmpty);

    final allowedResponse = await result.server.mcpHandler.handleRequest(
      _mcpRequest(
        'tools/call',
        id: 3,
        params: {
          'name': 'mcp__acme__allowed',
          'arguments': {'id': 'ok'},
        },
      ),
    );
    final allowedBody = jsonDecode(allowedResponse!) as Map<String, dynamic>;
    final allowedResult = allowedBody['result'] as Map<String, dynamic>;
    expect((allowedResult['content'] as List).single['text'], 'allowed:ok');
    expect(transport.calls.single.toolName, 'allowed');

    await result.shutdownExtras();
    expect(transport.closed, isTrue);
  });

  test('ServiceWiring fails when an outbound MCP adapter name collides', () async {
    final transport = _FakeOutboundTransport(
      tools: const [
        {'name': 'lookup'},
      ],
    );
    final config = _baseConfig(
      tempDir,
      mcpServers: const McpServersConfig(
        entries: {
          'acme': McpServerEntry(
            command: 'fake-acme',
            networkClass: McpNetworkClass.local,
            allowTools: ['lookup'],
            surfaceTools: ['lookup'],
          ),
        },
      ),
    );
    final wiring = ServiceWiring(
      config: config,
      dataDir: tempDir.path,
      port: 3000,
      harnessFactory: _harnessFactoryFor(worker),
      serverFactory: (builder) {
        final server = builder.build();
        server.registerTool(_NamedTool('mcp__acme__lookup'));
        return server;
      },
      searchDbFactory: (_) => sqlite3.openInMemory(),
      taskDbFactory: (_) => sqlite3.openInMemory(),
      stderrLine: (_) {},
      exitFn: _unexpectedExit,
      resolvedConfigPath: configFile.path,
      logService: logService,
      messageRedactor: messageRedactor,
      resolvedAssets: _resolvedAssetsForConfig(config),
      outboundMcpTransportFactory: (server, options) async => transport,
      runAndthenSkillsBootstrap: false,
    );

    await expectLater(
      wiring.wire(),
      throwsA(isA<StateError>().having((error) => error.message, 'message', contains('mcp__acme__lookup'))),
    );
    expect(transport.closed, isTrue);
  });

  test('ServiceWiring does not connect disabled or uncredentialed outbound MCP servers', () async {
    const yaml = '''
mcp_servers:
  disabled:
    command: fake-disabled
    enabled: false
    network_class: local
    surface_tools: [lookup]
  uncredentialed:
    command: fake-uncredentialed
    credential: missing
    network_class: local
    surface_tools: [lookup]
''';
    final parsed = DartclawConfig.load(
      configPath: configFile.path,
      env: {'HOME': tempDir.path},
      fileReader: (path) => path == configFile.path ? yaml : null,
    );
    final config = parsed.copyWith(
      agent: const AgentConfig(provider: 'claude'),
      credentials: const CredentialsConfig(entries: {'anthropic': CredentialEntry(apiKey: 'anthropic-key')}),
      providers: ProvidersConfig(
        entries: {'claude': ProviderEntry(executable: Platform.resolvedExecutable, poolSize: 0)},
      ),
      gateway: const GatewayConfig(authMode: 'none'),
      server: ServerConfig(
        dataDir: tempDir.path,
        staticDir: _staticDir(),
        templatesDir: _templatesDir(),
        claudeExecutable: Platform.resolvedExecutable,
      ),
    );
    var factoryCalls = 0;
    final wiring = ServiceWiring(
      config: config,
      dataDir: tempDir.path,
      port: 3000,
      harnessFactory: _harnessFactoryFor(worker),
      serverFactory: (builder) => builder.build(),
      searchDbFactory: (_) => sqlite3.openInMemory(),
      taskDbFactory: (_) => sqlite3.openInMemory(),
      stderrLine: (_) {},
      exitFn: _unexpectedExit,
      resolvedConfigPath: configFile.path,
      logService: logService,
      messageRedactor: messageRedactor,
      resolvedAssets: _resolvedAssetsForConfig(config),
      outboundMcpTransportFactory: (server, options) async {
        factoryCalls++;
        return _FakeOutboundTransport(tools: const []);
      },
      runAndthenSkillsBootstrap: false,
    );

    final result = await wiring.wire();
    addTearDown(() => _disposeWiringResult(result, logService, disposeExtras: false));

    expect(result.outboundMcpPool, isNull);
    expect(await _mcpToolNames(result.server), isNot(contains('mcp__disabled__lookup')));
    expect(await _mcpToolNames(result.server), isNot(contains('mcp__uncredentialed__lookup')));
    expect(factoryCalls, 0);
  });

  test('ServiceWiring closes the outbound MCP pool during shutdown extras', () async {
    final transport = _FakeOutboundTransport(
      tools: const [
        {'name': 'lookup'},
      ],
    );
    final config = _baseConfig(
      tempDir,
      mcpServers: const McpServersConfig(
        entries: {
          'acme': McpServerEntry(
            command: 'fake-acme',
            networkClass: McpNetworkClass.local,
            allowTools: ['lookup'],
            surfaceTools: ['lookup'],
          ),
        },
      ),
    );
    final wiring = ServiceWiring(
      config: config,
      dataDir: tempDir.path,
      port: 3000,
      harnessFactory: _harnessFactoryFor(worker),
      serverFactory: (builder) => builder.build(),
      searchDbFactory: (_) => sqlite3.openInMemory(),
      taskDbFactory: (_) => sqlite3.openInMemory(),
      stderrLine: (_) {},
      exitFn: _unexpectedExit,
      resolvedConfigPath: configFile.path,
      logService: logService,
      messageRedactor: messageRedactor,
      resolvedAssets: _resolvedAssetsForConfig(config),
      outboundMcpTransportFactory: (server, options) async => transport,
      runAndthenSkillsBootstrap: false,
    );

    final result = await wiring.wire();
    addTearDown(() => _disposeWiringResult(result, logService, disposeExtras: false));

    await result.shutdownExtras();

    expect(transport.closeCount, 1);
  });

  test('ServiceWiring wires AlertRouter into the production EventBus', () async {
    final config = DartclawConfig(
      agent: const AgentConfig(provider: 'claude'),
      credentials: const CredentialsConfig(entries: {'anthropic': CredentialEntry(apiKey: 'anthropic-key')}),
      providers: ProvidersConfig(
        entries: {'claude': ProviderEntry(executable: Platform.resolvedExecutable, poolSize: 0)},
      ),
      gateway: const GatewayConfig(authMode: 'none'),
      alerts: const AlertsConfig(
        enabled: true,
        targets: [AlertTarget(channel: 'googlechat', recipient: 'spaces/abc')],
      ),
      channels: const ChannelConfig(
        channelConfigs: {
          'google_chat': {'enabled': true},
        },
      ),
      server: ServerConfig(
        dataDir: tempDir.path,
        staticDir: _staticDir(),
        templatesDir: _templatesDir(),
        claudeExecutable: Platform.resolvedExecutable,
      ),
    );

    final wiring = ServiceWiring(
      config: config,
      dataDir: tempDir.path,
      port: 3000,
      harnessFactory: _harnessFactoryFor(worker),
      serverFactory: (builder) => builder.build(),
      searchDbFactory: (_) => sqlite3.openInMemory(),
      taskDbFactory: (_) => sqlite3.openInMemory(),
      stderrLine: (_) {},
      exitFn: _unexpectedExit,
      resolvedConfigPath: configFile.path,
      logService: logService,
      messageRedactor: messageRedactor,
      resolvedAssets: _resolvedAssetsForConfig(config),
      runAndthenSkillsBootstrap: false,
    );

    final result = await wiring.wire();
    addTearDown(() => _disposeWiringResult(result, logService));

    final channel = _RecordingChannel();
    result.channelManager!.registerChannel(channel);

    result.eventBus.fire(
      GuardBlockEvent(
        guardName: 'bash-guard',
        guardCategory: 'file',
        verdict: 'block',
        hookPoint: 'PreToolUse',
        timestamp: DateTime.now(),
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(channel.sent, hasLength(1));
    expect(channel.sent.single.$1, equals('spaces/abc'));
    expect(channel.sent.single.$2.text, contains('Guard Block'));
  });

  test('ServiceWiring loads built-in skills from source tree without materializing project copies', () async {
    for (final projectId in ['alpha', 'beta']) {
      Directory(p.join(tempDir.path, 'projects', projectId)).createSync(recursive: true);
    }

    final config = DartclawConfig(
      agent: const AgentConfig(provider: 'claude'),
      credentials: const CredentialsConfig(entries: {'anthropic': CredentialEntry(apiKey: 'anthropic-key')}),
      providers: ProvidersConfig(
        entries: {'claude': ProviderEntry(executable: Platform.resolvedExecutable, poolSize: 0)},
      ),
      gateway: const GatewayConfig(authMode: 'none'),
      projects: const ProjectConfig(
        definitions: {
          'alpha': ProjectDefinition(id: 'alpha', remote: 'file:///tmp/alpha.git'),
          'beta': ProjectDefinition(id: 'beta', remote: 'file:///tmp/beta.git'),
        },
      ),
      server: ServerConfig(
        dataDir: tempDir.path,
        staticDir: _staticDir(),
        templatesDir: _templatesDir(),
        claudeExecutable: Platform.resolvedExecutable,
      ),
    );

    final wiring = ServiceWiring(
      config: config,
      dataDir: tempDir.path,
      port: 3000,
      harnessFactory: _harnessFactoryFor(worker),
      serverFactory: (builder) => builder.build(),
      searchDbFactory: (_) => sqlite3.openInMemory(),
      taskDbFactory: (_) => sqlite3.openInMemory(),
      stderrLine: (_) {},
      exitFn: _unexpectedExit,
      resolvedConfigPath: configFile.path,
      logService: logService,
      messageRedactor: messageRedactor,
      resolvedAssets: _resolvedAssetsForConfig(config),
      runAndthenSkillsBootstrap: false,
    );

    final result = await wiring.wire();
    addTearDown(() => _disposeWiringResult(result, logService));

    for (final projectId in ['alpha', 'beta']) {
      final projectSkillDir = p.join(
        tempDir.path,
        'projects',
        projectId,
        '.claude',
        'skills',
        'dartclaw-discover-andthen-spec',
      );
      expect(Directory(projectSkillDir).existsSync(), isFalse);
    }
  });

  test('ServiceWiring rejects missing local refs for local-path workflow starts', () async {
    final projectDir = Directory(p.join(tempDir.path, 'live-project'))..createSync(recursive: true);
    _runGit(projectDir.path, ['init', '-b', 'main']);
    _runGit(projectDir.path, ['config', 'user.name', 'Test User']);
    _runGit(projectDir.path, ['config', 'user.email', 'test@example.com']);
    File(p.join(projectDir.path, 'README.md')).writeAsStringSync('hello\n');
    _runGit(projectDir.path, ['add', 'README.md']);
    _runGit(projectDir.path, ['commit', '-m', 'initial']);

    _stageProviderAndThenSkillStubs(tempDir.path);
    _stageProviderAndThenSkillStubs(projectDir.path);

    final config = DartclawConfig(
      agent: const AgentConfig(provider: 'claude'),
      credentials: const CredentialsConfig(entries: {'anthropic': CredentialEntry(apiKey: 'anthropic-key')}),
      providers: ProvidersConfig(
        entries: {'claude': ProviderEntry(executable: Platform.resolvedExecutable, poolSize: 0)},
      ),
      gateway: const GatewayConfig(authMode: 'none'),
      projects: ProjectConfig(
        definitions: {'alpha': ProjectDefinition(id: 'alpha', localPath: projectDir.path, branch: 'main')},
      ),
      server: ServerConfig(
        dataDir: tempDir.path,
        staticDir: _staticDir(),
        templatesDir: _templatesDir(),
        claudeExecutable: Platform.resolvedExecutable,
      ),
    );

    final wiring = ServiceWiring(
      config: config,
      dataDir: tempDir.path,
      port: 3000,
      harnessFactory: _harnessFactoryFor(worker),
      serverFactory: (builder) => builder.build(),
      searchDbFactory: (_) => sqlite3.openInMemory(),
      taskDbFactory: (_) => sqlite3.openInMemory(),
      stderrLine: (_) {},
      exitFn: _unexpectedExit,
      resolvedConfigPath: configFile.path,
      logService: logService,
      messageRedactor: messageRedactor,
      resolvedAssets: _resolvedAssetsForConfig(config),
      runAndthenSkillsBootstrap: false,
    );

    final result = await wiring.wire();
    addTearDown(() => _disposeWiringResult(result, logService));

    final response = await result.server.handler(
      Request(
        'POST',
        Uri.parse('http://localhost/api/workflows/run'),
        body: jsonEncode({
          'definition': 'spec-and-implement',
          'variables': {'FEATURE': 'Missing ref regression', 'PROJECT': 'alpha', 'BRANCH': 'missing/ref'},
        }),
        headers: {'content-type': 'application/json'},
      ),
    );

    final responseBody = await response.readAsString();
    expect(response.statusCode, 400, reason: responseBody);
    final body = jsonDecode(responseBody) as Map<String, dynamic>;
    expect(((body['error'] as Map<String, dynamic>)['message'] as String), contains('Ref "missing/ref" not found'));
  });

  test('ServiceWiring drops legacy session_cost entries at boot and logs the cleanup count', () async {
    final seededKv = KvService(filePath: p.join(tempDir.path, 'kv.json'));
    await seededKv.set(
      'session_cost:legacy',
      jsonEncode({'input_tokens': 100, 'new_input_tokens': 20, 'output_tokens': 50, 'total_tokens': 150}),
    );
    await seededKv.set(
      'session_cost:current',
      jsonEncode({
        'input_tokens': 20,
        'output_tokens': 10,
        'cache_read_tokens': 5,
        'cache_write_tokens': 0,
        'total_tokens': 30,
        'effective_tokens': 30,
        'estimated_cost_usd': 0.0,
        'turn_count': 1,
        'provider': 'claude',
      }),
    );
    await seededKv.dispose();

    final config = DartclawConfig(
      agent: const AgentConfig(provider: 'claude'),
      credentials: const CredentialsConfig(entries: {'anthropic': CredentialEntry(apiKey: 'anthropic-key')}),
      providers: ProvidersConfig(
        entries: {'claude': ProviderEntry(executable: Platform.resolvedExecutable, poolSize: 0)},
      ),
      gateway: const GatewayConfig(authMode: 'none'),
      server: ServerConfig(
        dataDir: tempDir.path,
        staticDir: _staticDir(),
        templatesDir: _templatesDir(),
        claudeExecutable: Platform.resolvedExecutable,
      ),
    );

    final oldLevel = Logger.root.level;
    Logger.root.level = Level.ALL;
    final records = <LogRecord>[];
    final logSub = Logger.root.onRecord.listen(records.add);
    addTearDown(() async {
      await logSub.cancel();
      Logger.root.level = oldLevel;
    });

    final wiring = ServiceWiring(
      config: config,
      dataDir: tempDir.path,
      port: 3000,
      harnessFactory: _harnessFactoryFor(worker),
      serverFactory: (builder) => builder.build(),
      searchDbFactory: (_) => sqlite3.openInMemory(),
      taskDbFactory: (_) => sqlite3.openInMemory(),
      stderrLine: (_) {},
      exitFn: _unexpectedExit,
      resolvedConfigPath: configFile.path,
      logService: logService,
      messageRedactor: messageRedactor,
      resolvedAssets: _resolvedAssetsForConfig(config),
      runAndthenSkillsBootstrap: false,
    );

    final result = await wiring.wire();
    addTearDown(() => _disposeWiringResult(result, logService));

    expect(await result.kvService.get('session_cost:legacy'), isNull);
    expect(await result.kvService.get('session_cost:current'), isNotNull);
    expect(
      records.any(
        (record) =>
            record.loggerName == 'ServiceWiring' &&
            record.level == Level.INFO &&
            record.message == 'Dropped 1 legacy session_cost entries (pre-Tier-1b schema)',
      ),
      isTrue,
    );
  });

  test('ServiceWiring runs the AndThen skills bootstrap before wire() returns', () async {
    final provisionHome = Directory(p.join(tempDir.path, 'provision-home'))..createSync(recursive: true);
    _stageProviderAndThenSkillStubs(provisionHome.path);

    final config = DartclawConfig(
      agent: const AgentConfig(provider: 'claude'),
      credentials: const CredentialsConfig(entries: {'anthropic': CredentialEntry(apiKey: 'anthropic-key')}),
      providers: ProvidersConfig(
        entries: {'claude': ProviderEntry(executable: Platform.resolvedExecutable, poolSize: 0)},
      ),
      gateway: const GatewayConfig(authMode: 'none'),
      server: ServerConfig(
        dataDir: tempDir.path,
        staticDir: _staticDir(),
        templatesDir: _templatesDir(),
        claudeExecutable: Platform.resolvedExecutable,
      ),
    );

    final wiring = ServiceWiring(
      config: config,
      dataDir: tempDir.path,
      port: 3000,
      harnessFactory: _harnessFactoryFor(worker),
      serverFactory: (builder) => builder.build(),
      searchDbFactory: (_) => sqlite3.openInMemory(),
      taskDbFactory: (_) => sqlite3.openInMemory(),
      stderrLine: (_) {},
      exitFn: _unexpectedExit,
      resolvedConfigPath: configFile.path,
      logService: logService,
      messageRedactor: messageRedactor,
      resolvedAssets: _resolvedAssetsForConfig(config),
      // Default `runAndthenSkillsBootstrap: true` – we want the bootstrap to run.
      skillProvisionerEnvironment: {'HOME': provisionHome.path},
    );

    final result = await wiring.wire();
    addTearDown(() => _disposeWiringResult(result, logService));

    // DC-native skills copied into both data-dir native trees by SkillProvisioner.
    for (final name in const [
      'dartclaw-discover-andthen-spec',
      'dartclaw-discover-andthen-plan',
      'dartclaw-validate-workflow',
      'dartclaw-merge-resolve',
    ]) {
      expect(
        File(p.join(tempDir.path, '.agents', 'skills', name, 'SKILL.md')).existsSync(),
        isTrue,
        reason: '$name in data-dir native Codex tree',
      );
      expect(
        File(p.join(tempDir.path, '.claude', 'skills', name, 'SKILL.md')).existsSync(),
        isTrue,
        reason: '$name in data-dir native Claude tree',
      );
    }
    // Marker written for the data-dir native destination.
    expect(File(p.join(tempDir.path, '.dartclaw-native-skills')).existsSync(), isTrue);
    expect(_unexpectedDataDirSkillEntries(tempDir.path), isEmpty);
  });
}

List<String> _unexpectedDataDirSkillEntries(String dataDir) {
  final allowed = {
    'dartclaw-discover-andthen-spec',
    'dartclaw-discover-andthen-plan',
    'dartclaw-validate-workflow',
    'dartclaw-merge-resolve',
  };
  final roots = [Directory(p.join(dataDir, '.agents', 'skills')), Directory(p.join(dataDir, '.claude', 'skills'))];
  return [
    for (final root in roots)
      if (root.existsSync())
        for (final entity in root.listSync(followLinks: false))
          if (entity is Directory && !allowed.contains(p.basename(entity.path))) entity.path,
  ];
}
