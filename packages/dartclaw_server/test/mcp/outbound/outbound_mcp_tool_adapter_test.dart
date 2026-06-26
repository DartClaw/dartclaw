import 'package:dartclaw_config/dartclaw_config.dart' show McpNetworkClass, McpServerEntry, McpServersConfig;
import 'package:dartclaw_core/dartclaw_core.dart' show ToolResultError, ToolResultText;
import 'package:dartclaw_security/dartclaw_security.dart';
import 'package:dartclaw_server/src/mcp/outbound/outbound_mcp_models.dart';
import 'package:dartclaw_server/src/mcp/outbound/outbound_mcp_pool.dart';
import 'package:dartclaw_server/src/mcp/outbound/outbound_mcp_tool_adapter.dart';
import 'package:dartclaw_server/src/mcp/outbound/outbound_mcp_transport.dart';
import 'package:test/test.dart';

void main() {
  group('OutboundMcpToolAdapter', () {
    test('maps a namespaced MCP call through the pool to the external server tool', () async {
      final transport = _AdapterTransport();
      final pool = OutboundMcpPool(
        mcpServers: const McpServersConfig(
          entries: {
            'acme': McpServerEntry(command: 'fake', networkClass: McpNetworkClass.local, surfaceTools: ['lookup']),
          },
        ),
        transportFactory: (server, options) async => transport,
        guardDecisionHook: (_) async => const OutboundMcpGuardDecision.allow(),
        auditLogger: GuardAuditLogger(),
      );
      addTearDown(pool.close);
      final adapter = OutboundMcpToolAdapter(
        serverName: 'acme',
        tool: const OutboundMcpTool(
          name: 'lookup',
          description: 'Lookup records',
          inputSchema: {
            'type': 'object',
            'properties': {
              'id': {'type': 'string'},
            },
          },
        ),
        pool: pool,
        callerProvider: () => const OutboundMcpCaller(sessionId: 'session-1', principal: 'operator'),
      );

      final result = await adapter.call({'id': '42'});

      expect(adapter.name, 'mcp__acme__lookup');
      expect(adapter.description, 'Lookup records');
      expect(result, isA<ToolResultText>().having((result) => result.content, 'content', 'result:42'));
      expect(transport.calls.single.toolName, 'lookup');
      expect(transport.calls.single.arguments, {'id': '42'});
    });

    test('maps egress-denied outbound results to handled MCP tool errors', () async {
      final pool = OutboundMcpPool(
        mcpServers: const McpServersConfig(
          entries: {
            'acme': McpServerEntry(command: 'fake', networkClass: McpNetworkClass.local, surfaceTools: ['lookup']),
          },
        ),
        transportFactory: (server, options) async => _AdapterTransport(),
        guardDecisionHook: (_) async => const OutboundMcpGuardDecision.deny('blocked by policy'),
        auditLogger: GuardAuditLogger(),
      );
      addTearDown(pool.close);
      final adapter = OutboundMcpToolAdapter(
        serverName: 'acme',
        tool: const OutboundMcpTool(name: 'lookup'),
        pool: pool,
        callerProvider: () => const OutboundMcpCaller(sessionId: 'session-1'),
      );

      final result = await adapter.call(const {});

      expect(result, isA<ToolResultError>().having((result) => result.message, 'message', 'blocked by policy'));
    });
  });
}

final class _AdapterTransport implements OutboundMcpTransport {
  final List<({String toolName, Map<String, dynamic> arguments})> calls = [];

  @override
  Future<Map<String, dynamic>> sendRequest(
    String method,
    Map<String, dynamic> params, {
    required Duration timeout,
    required int maxResponseBytes,
  }) async {
    if (method == 'initialize') return const {};
    if (method == 'tools/list') {
      return const {
        'tools': [
          {'name': 'lookup'},
        ],
      };
    }
    calls.add((toolName: params['name'] as String, arguments: Map<String, dynamic>.from(params['arguments'] as Map)));
    final args = params['arguments'] as Map;
    return {
      'content': [
        {'type': 'text', 'text': 'result:${args['id']}'},
      ],
    };
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
  Future<void> close() async {}
}
