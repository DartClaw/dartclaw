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

/// A [ContextualMcpTool] that records the caller context it runs with.
final class _ContextProbeTool extends ContextualMcpTool {
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

final class _OnlyPolicy implements McpCallerPolicy {
  const new(this.tool);

  final String tool;

  @override
  bool allows(String toolName) => toolName == tool;

  @override
  void onDenied(String toolName) {}
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

  String harnessBearer() => bearers.mint(McpCaller(identity: () => serving, turn: () => running));

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

  test('every contextual tool is refused while the harness runs no turn, the turn-reading ones too', () async {
    serving = null;
    final bearer = harnessBearer();

    for (final tool in ['context_probe', 'turn_probe']) {
      final result = toolResult(await call(tool, bearer: bearer));
      expect(result['isError'], isTrue, reason: tool);
      expect(resultText(result), 'Tool requires authenticated caller context');
    }
    expect(probe.contexts, isEmpty);
    expect(turnProbe.contexts, isEmpty);
  });

  test('the gateway token runs a contextual tool as the steward with no session', () async {
    expect(resultText(toolResult(await call('context_probe', bearer: _gatewayToken))), 'scoped');

    final context = probe.contexts.single;
    expect((context.authorityId, context.sessionId, context.agentId, context.turn), ('system', null, null, null));
  });

  test('a turn-reading tool receives the harness turn together with its identity', () async {
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

  test('a host agent policy narrows tools/list and refuses tools/call alike', () async {
    final bearer = bearers.mint(
      McpCaller(identity: () => agentIdentity, turn: () => running, policy: const _OnlyPolicy('context_probe')),
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
    expect((await call('turn_probe', bearer: bearer))['error'], containsPair('code', -32601));
    expect(turnProbe.contexts, isEmpty);
  });
}
