import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/src/mcp/context_engine_profile.dart';
import 'package:dartclaw_runtime/src/mcp/kg_tools.dart';
import 'package:dartclaw_runtime/src/mcp/mcp_server.dart';
import 'package:dartclaw_runtime/src/mcp/memory_tools.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

class _NamedTool implements McpTool {
  new(this.name, this.access);

  @override
  final String name;
  @override
  final McpToolAccess access;

  @override
  String get description => 'test tool $name';
  @override
  Map<String, dynamic> get inputSchema => {'type': 'object', 'properties': <String, dynamic>{}};

  @override
  Future<ToolResult> call(Map<String, dynamic> args) async => ToolResult.text('called $name');
}

List<Map<String, dynamic>> _entries(Directory dataDir) => [
  for (final file in dataDir.listSync().whereType<File>().where((f) => f.path.endsWith('.ndjson')))
    for (final line in file.readAsLinesSync())
      if (line.trim().isNotEmpty) jsonDecode(line) as Map<String, dynamic>,
];

void main() {
  late Directory tempDir;
  late GuardAuditLogger auditLogger;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_context_engine_');
    auditLogger = GuardAuditLogger(dataDir: tempDir.path);
  });

  tearDown(() async {
    await auditLogger.flush();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  group('the context-engine profile', () {
    test('is exactly the five read tools the client surface promises', () {
      expect(
        contextEngineProfileTools,
        unorderedEquals(['context_research', 'memory_search', 'memory_read', 'kg_query', 'kg_timeline']),
      );
    });

    test('namespaces the client principal so it cannot be read as the steward or a session', () {
      expect(mcpClientPrincipal('ide'), 'mcp-client:ide');
      expect(mcpClientPrincipal('ide'), isNot(mcpStewardPrincipal));
    });
  });

  group('ContextEngineCallerPolicy', () {
    test('allows the profile and denies every other name, registered or not', () {
      final policy = ContextEngineCallerPolicy(principal: mcpClientPrincipal('ide'));

      for (final tool in contextEngineProfileTools) {
        expect(policy.allows(tool), isTrue, reason: tool);
      }
      for (final tool in [
        'kg_add',
        'kg_invalidate',
        'kg_contradictions',
        'memory_apply',
        'memory_observe',
        'web_fetch',
        'brave_search',
        'sessions_spawn',
        'wiki_write',
        'onboarding_complete',
        'never_registered',
      ]) {
        expect(policy.allows(tool), isFalse, reason: tool);
      }
    });

    test(
      'writes one audit entry naming the client and the tool for each refusal, and none for an allowed call',
      () async {
        final policy = ContextEngineCallerPolicy(principal: mcpClientPrincipal('ide'), auditLogger: auditLogger);

        policy.onDenied('kg_add');
        await auditLogger.flush();

        final entries = _entries(tempDir);
        expect(entries, hasLength(1));
        expect(entries.single['principal'], 'mcp-client:ide');
        expect(entries.single['tool'], 'kg_add');
        expect(entries.single['decision'], 'deny');
        expect(entries.single['hook'], 'mcp_tool_call');
        // An allowed call never reaches onDenied; the dispatch seam owns its entry.
        expect(policy.allows('kg_query'), isTrue);
        await auditLogger.flush();
        expect(_entries(tempDir), hasLength(1));
      },
    );
  });

  group('a handler scoped to one client', () {
    late McpProtocolHandler handler;
    late Database db;
    late TemporalKnowledgeGraphService kg;

    McpProtocolHandler scoped() => handler.scopedTo(
      ContextEngineCallerPolicy(principal: mcpClientPrincipal('ide'), auditLogger: auditLogger),
      callerIdentity: McpCallerIdentity(authorityId: mcpClientPrincipal('ide')),
    );

    Future<Map<String, dynamic>> call(McpProtocolHandler target, String method, Map<String, dynamic> params) async {
      final response = await target.handleRequest(
        jsonEncode({'jsonrpc': '2.0', 'id': 1, 'method': method, 'params': params}),
      );
      return jsonDecode(response!) as Map<String, dynamic>;
    }

    setUp(() {
      db = sqlite3.openInMemory();
      kg = TemporalKnowledgeGraphService(db);
      handler = McpProtocolHandler(auditLogger: auditLogger);
      handler.registerTool(KgQueryTool(kg: kg));
      handler.registerTool(KgTimelineTool(kg: kg));
      handler.registerTool(KgAddTool(kg: kg));
      handler.registerTool(KgContradictionsTool(kg: kg));
      handler.registerTool(MemoryReadTool(handler: (args) async => {'echo': args}));
      handler.registerTool(MemorySearchTool(handler: (args) async => {'echo': args}));
      handler.registerTool(_NamedTool('web_fetch', McpToolAccess.write));
      handler.registerTool(_NamedTool('brave_search', McpToolAccess.read));
    });

    tearDown(() => db.close());

    test('discovers only the profile tools that are registered', () async {
      final result = await call(scoped(), 'tools/list', {});
      final names = ((result['result'] as Map<String, dynamic>)['tools'] as List)
          .map((tool) => (tool as Map<String, dynamic>)['name'])
          .toList();

      expect(names, unorderedEquals(['kg_query', 'kg_timeline', 'memory_read', 'memory_search']));
    });

    test('refuses a write tool, a read-classified egress tool and an unknown name identically', () async {
      final target = scoped();
      final denied = <Map<String, dynamic>>[
        for (final name in ['kg_add', 'brave_search', 'never_registered'])
          (await call(target, 'tools/call', {'name': name, 'arguments': <String, dynamic>{}}))['error']
              as Map<String, dynamic>,
      ];

      expect(denied.map((error) => error['code']).toSet(), {-32601});
      expect(
        denied.map((error) => (error['message'] as String).replaceAll(RegExp(r': .*$'), '')).toSet(),
        hasLength(1),
      );
      // The unregistered name is indistinguishable from the two that exist.
      expect(denied[2]['message'], 'Tool not available: never_registered');
    });

    test('audits a refused registered tool as the client, and never invokes it', () async {
      final before = kg.timeline(entity: 'Fact').length;

      await call(scoped(), 'tools/call', {
        'name': 'kg_add',
        'arguments': {
          'entity': 'Fact',
          'predicate': 'p',
          'value': 'v',
          'valid_from': '2026-05-01T00:00:00Z',
          'source': 'wiki/x.md',
        },
      });
      await auditLogger.flush();

      expect(kg.timeline(entity: 'Fact'), hasLength(before), reason: 'a refused write must not reach the tool');
      final denials = _entries(tempDir).where((entry) => entry['decision'] == 'deny').toList();
      expect(denials, hasLength(1));
      expect(denials.single['principal'], 'mcp-client:ide');
      expect(denials.single['tool'], 'kg_add');
    });

    test('audits an allowed read as the client, while the owner audits as the steward', () async {
      await call(scoped(), 'tools/call', {
        'name': 'kg_query',
        'arguments': {'entity': 'Anything'},
      });
      await call(handler, 'tools/call', {
        'name': 'kg_query',
        'arguments': {'entity': 'Anything'},
      });
      await auditLogger.flush();

      final allows = _entries(tempDir).where((entry) => entry['decision'] == 'allow').toList();
      expect(allows.map((entry) => entry['principal']), ['mcp-client:ide', mcpStewardPrincipal]);
      expect(allows.every((entry) => entry['tool'] == 'kg_query'), isTrue);
    });

    test('reads the owner view of the knowledge surface, narrowed by no fact owner', () async {
      kg.addFact(
        entity: 'Release',
        predicate: 'channel',
        value: 'stable',
        validFrom: '2026-05-01T00:00:00Z',
        source: 'wiki/release.md',
        owner: 'owner',
      );
      kg.addFact(
        entity: 'Release',
        predicate: 'runner',
        value: 'ubuntu',
        validFrom: '2026-05-01T00:00:00Z',
        source: 'wiki/release.md',
        owner: 'system',
      );

      const params = {
        'name': 'kg_timeline',
        'arguments': {'entity': 'Release'},
      };
      final ownerView = await call(handler, 'tools/call', params);
      final clientView = await call(scoped(), 'tools/call', params);

      expect(clientView['result'], ownerView['result']);
      expect(jsonEncode(clientView['result']), allOf(contains('stable'), contains('ubuntu')));

      const readParams = {
        'name': 'memory_read',
        'arguments': {'locator': 'wiki/release.md'},
      };
      expect(
        (await call(scoped(), 'tools/call', readParams))['result'],
        (await call(handler, 'tools/call', readParams))['result'],
      );
    });
  });
}
