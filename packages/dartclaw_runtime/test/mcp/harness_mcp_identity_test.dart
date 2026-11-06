import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/src/mcp/harness_mcp_bearers.dart';
import 'package:dartclaw_runtime/src/mcp/mcp_router.dart';
import 'package:dartclaw_runtime/src/mcp/mcp_server.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import '../guard_audit_test_support.dart';
import 'mcp_test_support.dart';

const _gatewayToken = 'test-gateway-token';

/// A [ContextualMcpTool] that records the caller context it runs with; its plain [call] answers `unscoped`.
final class _ContextProbeTool implements ContextualMcpTool {
  final contexts = <McpCallerContext>[];

  @override
  String get name => 'context_probe';

  @override
  String get description => 'records the caller context';

  @override
  Map<String, dynamic> get inputSchema => const {'type': 'object', 'properties': <String, Object?>{}};

  @override
  McpToolAccess get access => McpToolAccess.read;

  @override
  Future<ToolResult> call(Map<String, dynamic> args) async => ToolResult.text('unscoped');

  @override
  Future<ToolResult> callWithContext(Map<String, dynamic> args, McpCallerContext context) async {
    contexts.add(context);
    return ToolResult.text('scoped');
  }
}

final class _RecordingGuard extends Guard {
  final contexts = <GuardContext>[];

  @override
  String get name => 'RecordingGuard';

  @override
  String get category => 'test';

  @override
  Future<GuardVerdict> evaluate(GuardContext context) async {
    contexts.add(context);
    return GuardVerdict.pass();
  }
}

void main() {
  late _ContextProbeTool probe;
  late TurnProbeTool turnProbe;
  late _RecordingGuard guard;
  late RecordingGuardAuditLogger audit;
  late HarnessMcpBearers bearers;
  late Handler route;
  McpCallerIdentity? serving;
  TurnProvenance? running;

  const agentIdentity = McpCallerIdentity(authorityId: 'agent:eng-bot', sessionId: 'session-eng', agentId: 'eng-bot');
  const ownerIdentity = McpCallerIdentity(authorityId: mcpStewardPrincipal, sessionId: 'session-owner');

  setUp(() {
    probe = _ContextProbeTool();
    turnProbe = TurnProbeTool();
    guard = _RecordingGuard();
    audit = RecordingGuardAuditLogger();
    bearers = HarnessMcpBearers();
    serving = agentIdentity;
    running = null;
    final handler =
        McpProtocolHandler(
            guardChain: GuardChain(guards: [guard]),
            auditLogger: audit,
          )
          ..registerTool(probe)
          ..registerTool(turnProbe);
    route = mcpRoute(handler, gatewayToken: _gatewayToken, harnessBearers: bearers);
  });

  Future<Map<String, dynamic>> call(String tool, {required String bearer}) async {
    final response = await route(
      Request(
        'POST',
        Uri.parse('http://localhost/mcp'),
        body: jsonEncode({
          'jsonrpc': '2.0',
          'id': 1,
          'method': 'tools/call',
          'params': {'name': tool, 'arguments': <String, Object?>{}},
        }),
        headers: {'authorization': 'Bearer $bearer', 'content-type': 'application/json'},
      ),
    );
    expect(response.statusCode, 200);
    return jsonDecode(await response.readAsString()) as Map<String, dynamic>;
  }

  String harnessBearer() => bearers.mint(() => running, identity: () => serving);

  test('a contextual tool runs as the caller the harness is serving, resolved at each call', () async {
    final bearer = harnessBearer();

    expect(resultText(toolResult(await call('context_probe', bearer: bearer))), 'scoped');
    serving = ownerIdentity;
    await call('context_probe', bearer: bearer);

    expect(
      [for (final c in probe.contexts) (c.authorityId, c.sessionId, c.agentId, c.taskId)],
      [('agent:eng-bot', 'session-eng', 'eng-bot', null), ('system', 'session-owner', null, null)],
    );
    expect(probe.contexts.first.sourceEvent, startsWith('mcp-call:agent:eng-bot:'));
    expect(probe.contexts.map((c) => c.knowledgeScope), everyElement(McpKnowledgeScope.privateAndShared));
  });

  test('a contextual tool is refused while the harness runs no turn, never handed the unscoped call', () async {
    serving = null;

    final result = toolResult(await call('context_probe', bearer: harnessBearer()));

    expect(result['isError'], isTrue);
    expect(resultText(result), 'Tool requires authenticated caller context');
    expect(probe.contexts, isEmpty);
  });

  test('the gateway token carries no identity, so a contextual tool is still handed the unscoped call', () async {
    expect(resultText(toolResult(await call('context_probe', bearer: _gatewayToken))), 'unscoped');
    expect(probe.contexts, isEmpty);
  });

  test('a harness bearer minted without an identity resolver behaves as before', () async {
    final bearer = bearers.mint(() => running);

    expect(resultText(toolResult(await call('context_probe', bearer: bearer))), 'unscoped');
  });

  test('a turn-aware tool receives the harness turn together with its identity', () async {
    running = TurnProvenance.channel(
      channelType: ChannelType.slack,
      sessionKey: 'agent:eng-bot:channel:slack',
      recipientId: 'C1',
      senderId: 'U-A',
    );

    await call('turn_probe', bearer: harnessBearer());

    final context = turnProbe.contexts.single;
    expect(context.turn, running);
    expect((context.authorityId, context.sessionId, context.agentId), ('agent:eng-bot', 'session-eng', 'eng-bot'));
  });

  test('a turn-aware tool still runs with no identity and no turn, as the steward', () async {
    serving = null;

    await call('turn_probe', bearer: harnessBearer());

    final context = turnProbe.contexts.single;
    expect((context.turn, context.authorityId, context.sessionId, context.agentId), (null, 'system', null, null));
  });

  test('the audit entry names the serving caller while the guard chain sees no agent or session', () async {
    await call('context_probe', bearer: harnessBearer());
    await call('context_probe', bearer: _gatewayToken);

    expect(
      [for (final e in audit.entries) (e.principal, e.agentId, e.sessionId)],
      [('agent:eng-bot', 'eng-bot', 'session-eng'), ('system', null, null)],
    );
    // The harness's own ToolPolicyGuard has decided this call under its provider's names; an agent id here would
    // re-decide it under this seam's names (an unmapped tool reaches the guard by its bare name).
    expect([for (final c in guard.contexts) (c.agentId, c.sessionId)], [(null, null), (null, null)]);
  });

  test('tools/list is filtered by listsTool and unaffected by the identity', () async {
    final bearer = bearers.mint(
      () => running,
      identity: () => agentIdentity,
      listsTool: (name) => name == 'context_probe',
    );

    final response = await route(
      Request(
        'POST',
        Uri.parse('http://localhost/mcp'),
        body: jsonEncode({'jsonrpc': '2.0', 'id': 1, 'method': 'tools/list'}),
        headers: {'authorization': 'Bearer $bearer', 'content-type': 'application/json'},
      ),
    );

    final tools = ((jsonDecode(await response.readAsString()) as Map)['result'] as Map)['tools'] as List;
    expect([for (final tool in tools) (tool as Map)['name']], ['context_probe']);
  });
}
