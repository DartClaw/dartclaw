import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_runtime/src/mcp/mcp_server.dart';
import 'package:test/test.dart';

import '../guard_audit_test_support.dart';

// ---------------------------------------------------------------------------
// Doubles
// ---------------------------------------------------------------------------

class _RecordingTool implements McpTool {
  new(this.name, this.access, {Map<String, dynamic>? inputSchema})
    : inputSchema = inputSchema ?? {'type': 'object', 'properties': <String, dynamic>{}};

  @override
  final String name;

  @override
  final McpToolAccess access;

  @override
  final Map<String, dynamic> inputSchema;

  int invocations = 0;

  @override
  String get description => 'Recording tool $name';

  @override
  Future<ToolResult> call(Map<String, dynamic> args) async {
    invocations++;
    return ToolResult.text('ok:$name');
  }
}

class _StubGuard extends Guard {
  new(this._verdict);

  final GuardVerdict _verdict;
  final contexts = <GuardContext>[];

  @override
  String get name => 'StubGuard';

  @override
  String get category => 'test';

  @override
  Future<GuardVerdict> evaluate(GuardContext context) async {
    contexts.add(context);
    return _verdict;
  }
}

/// A chain whose evaluation throws rather than returning a verdict.
class _ThrowingGuardChain extends GuardChain {
  new() : super(guards: const []);

  @override
  Future<GuardVerdict> evaluateBeforeToolCall(
    String toolName,
    Map<dynamic, dynamic> toolInput, {
    String? sessionId,
    String? agentId,
    String? rawProviderToolName,
  }) => Future.error(StateError('guard evaluator offline'));
}

class _ThrowingAuditLogger extends GuardAuditLogger {
  int attempts = 0;

  @override
  Future<void> writeEntry(AuditEntry entry) async {
    attempts++;
    throw StateError('audit sink offline');
  }
}

class _AllowListPolicy implements McpCallerPolicy {
  new(this._allowed);

  final Set<String> _allowed;
  final denied = <String>[];

  @override
  bool allows(String toolName) => _allowed.contains(toolName);

  @override
  void onDenied(String toolName) => denied.add(toolName);
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

Future<Map<String, dynamic>> _call(
  McpProtocolHandler handler,
  String name, {
  Map<String, dynamic> arguments = const {},
}) async {
  final raw = await handler.handleRequest(
    jsonEncode({
      'jsonrpc': '2.0',
      'id': 7,
      'method': 'tools/call',
      'params': {'name': name, 'arguments': arguments},
    }),
  );
  return jsonDecode(raw!) as Map<String, dynamic>;
}

Map<String, dynamic> _result(Map<String, dynamic> response) {
  expect(response.containsKey('error'), isFalse, reason: 'expected a JSON-RPC success, got ${response['error']}');
  return response['result'] as Map<String, dynamic>;
}

String _text(Map<String, dynamic> result) =>
    ((result['content'] as List).single as Map<String, dynamic>)['text'] as String;

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  late _RecordingTool readTool;
  late _RecordingTool writeTool;
  late RecordingGuardAuditLogger audit;

  setUp(() {
    readTool = _RecordingTool('probe_read', McpToolAccess.read);
    writeTool = _RecordingTool('probe_write', McpToolAccess.write);
    audit = RecordingGuardAuditLogger();
  });

  McpProtocolHandler handlerWith({GuardChain? chain, GuardAuditLogger? sink}) =>
      McpProtocolHandler(guardChain: chain, auditLogger: sink)
        ..registerTool(readTool)
        ..registerTool(writeTool);

  group('S01 dispatch guard and audit on the allow path', () {
    test('every dispatched tool call is guard-evaluated once and audited as allow', () async {
      final guard = _StubGuard(GuardVerdict.pass());
      final handler = handlerWith(
        chain: GuardChain(guards: [guard]),
        sink: audit,
      );

      expect(_text(_result(await _call(handler, 'probe_read'))), 'ok:probe_read');
      expect(_text(_result(await _call(handler, 'probe_write'))), 'ok:probe_write');

      expect(guard.contexts.map((c) => c.hookPoint), ['beforeToolCall', 'beforeToolCall']);
      expect(guard.contexts.map((c) => c.toolName), ['probe_read', 'probe_write']);
      expect(guard.contexts.map((c) => c.rawProviderToolName), ['probe_read', 'probe_write']);

      expect(audit.entries, hasLength(2));
      expect(audit.entries.map((e) => e.decision), ['allow', 'allow']);
      expect(audit.entries.map((e) => e.verdict), ['pass', 'pass']);
      expect(audit.entries.map((e) => e.tool), ['probe_read', 'probe_write']);
      expect(audit.entries.map((e) => e.rawProviderToolName), ['probe_read', 'probe_write']);
      expect(audit.entries.map((e) => e.principal), [mcpStewardPrincipal, mcpStewardPrincipal]);
      expect(audit.entries.map((e) => e.hook), ['mcp_tool_call', 'mcp_tool_call']);
      expect(audit.entries.map((e) => e.server), ['dartclaw', 'dartclaw']);
      expect(audit.entries.map((e) => e.reason), ['access=read', 'access=write']);
    });

    test('a null chain and a null sink leave dispatch untouched', () async {
      final handler = handlerWith();

      expect(_text(_result(await _call(handler, 'probe_write'))), 'ok:probe_write');
      expect(writeTool.invocations, 1);
      expect(audit.entries, isEmpty);
    });
  });

  group('S02 a guard block refuses the call as a tool error', () {
    test('the response is a tool error, the tool never runs, and the deny is audited', () async {
      final guard = _StubGuard(GuardVerdict.block('mcp writes disabled'));
      final handler = handlerWith(
        chain: GuardChain(guards: [guard]),
        sink: audit,
      );

      final result = _result(await _call(handler, 'probe_write'));

      expect(result['isError'], isTrue);
      expect(_text(result), 'mcp writes disabled');
      expect(writeTool.invocations, 0);

      final entry = audit.entries.single;
      expect(entry.decision, 'deny');
      expect(entry.verdict, 'block');
      expect(entry.tool, 'probe_write');
      expect(entry.reason, 'access=write mcp writes disabled');
    });
  });

  group('S03 negative control: a guard chain that throws refuses the call', () {
    test('an evaluator-level throw denies, never invokes, and is audited', () async {
      final handler = handlerWith(chain: _ThrowingGuardChain(), sink: audit);

      final result = _result(await _call(handler, 'probe_write'));

      expect(result['isError'], isTrue);
      expect(_text(result), contains('guard failure'));
      expect(writeTool.invocations, 0);

      final entry = audit.entries.single;
      expect(entry.decision, 'deny');
      expect(entry.reason, contains('guard evaluator offline'));
    });
  });

  group('S04 negative control: an audit sink that throws refuses the call', () {
    test('an unauditable dispatch does not happen', () async {
      final sink = _ThrowingAuditLogger();
      final handler = handlerWith(
        chain: GuardChain(guards: [_StubGuard(GuardVerdict.pass())]),
        sink: sink,
      );

      final result = _result(await _call(handler, 'probe_write'));

      expect(result['isError'], isTrue);
      expect(_text(result), contains('audit failure'));
      expect(writeTool.invocations, 0);
      expect(sink.attempts, 1);
    });

    test('a deny that cannot be audited still refuses', () async {
      final sink = _ThrowingAuditLogger();
      final handler = handlerWith(
        chain: GuardChain(guards: [_StubGuard(GuardVerdict.block('nope'))]),
        sink: sink,
      );

      final result = _result(await _call(handler, 'probe_write'));

      expect(result['isError'], isTrue);
      expect(_text(result), contains('audit failure'));
      expect(writeTool.invocations, 0);
    });
  });

  group('S05 the audited principal follows the transport-authenticated caller', () {
    test('a scoped handler audits the caller authority and forwards its session and agent ids', () async {
      final guard = _StubGuard(GuardVerdict.pass());
      final unscoped = handlerWith(
        chain: GuardChain(guards: [guard]),
        sink: audit,
      );
      final scoped = unscoped.scopedTo(
        _AllowListPolicy({'probe_write'}),
        callerIdentity: const McpCallerIdentity(
          authorityId: 'authority-42',
          sessionId: 'session-9',
          agentId: 'agent-3',
        ),
      );

      // A request payload claiming another identity changes nothing.
      await _call(scoped, 'probe_write', arguments: {'authorityId': 'spoofed', 'principal': 'spoofed'});
      await _call(unscoped, 'probe_write', arguments: {'authorityId': 'spoofed', 'principal': 'spoofed'});

      final scopedEntry = audit.entries.first;
      expect(scopedEntry.principal, 'authority-42');
      expect(scopedEntry.sessionId, 'session-9');
      expect(scopedEntry.agentId, 'agent-3');
      expect(guard.contexts.first.sessionId, 'session-9');
      expect(guard.contexts.first.agentId, 'agent-3');

      final unscopedEntry = audit.entries.last;
      expect(unscopedEntry.principal, mcpStewardPrincipal);
      expect(unscopedEntry.sessionId, isNull);
      expect(unscopedEntry.agentId, isNull);
      expect(guard.contexts.last.sessionId, isNull);
    });

    test('a scoped view enforces with the same guard chain and audit sink', () async {
      final blocked = handlerWith(
        chain: GuardChain(guards: [_StubGuard(GuardVerdict.block('blocked'))]),
        sink: audit,
      );
      final scoped = blocked.scopedTo(_AllowListPolicy({'probe_write'}));

      final result = _result(await _call(scoped, 'probe_write'));

      expect(result['isError'], isTrue);
      expect(writeTool.invocations, 0);
      expect(audit.entries.single.decision, 'deny');
    });
  });

  group('S01 the seam enforces the real base chain, not just a stub', () {
    // The base guards key on bare tool names, so the seam's `tool.name` and the
    // guard's key must stay the same string — renaming `web_fetch` would
    // silently take it out of NetworkGuard's reach.
    _RecordingTool webFetch() => _RecordingTool(
      'web_fetch',
      McpToolAccess.write,
      inputSchema: {
        'type': 'object',
        'properties': {
          'url': {'type': 'string'},
        },
      },
    );

    McpProtocolHandler handlerWithNetworkGuard(_RecordingTool tool) => McpProtocolHandler(
      guardChain: GuardChain(
        guards: [
          NetworkGuard(
            config: NetworkGuardConfig(allowedDomains: {'allowed.example'}, exfilPatterns: const []),
          ),
        ],
      ),
      auditLogger: audit,
    )..registerTool(tool);

    test('a real NetworkGuard blocks an out-of-allowlist web_fetch at dispatch', () async {
      final tool = webFetch();
      final result = _result(
        await _call(handlerWithNetworkGuard(tool), 'web_fetch', arguments: {'url': 'https://blocked.example/x'}),
      );

      expect(result['isError'], isTrue);
      expect(_text(result), contains('blocked.example'));
      expect(tool.invocations, 0);
      expect(audit.entries.single.decision, 'deny');
    });

    test('a real NetworkGuard lets an allowlisted web_fetch through', () async {
      final tool = webFetch();
      final result = _result(
        await _call(handlerWithNetworkGuard(tool), 'web_fetch', arguments: {'url': 'https://allowed.example/x'}),
      );

      expect(result['isError'], isNull);
      expect(tool.invocations, 1);
      expect(audit.entries.single.decision, 'allow');
    });
  });

  group('S01 a scoped caller is judged on the canonical tool name', () {
    // The caller policy authorizes `brave_search` through its canonical
    // (`web_search`); if the seam then evaluated the bare name, the agent
    // allowlist — written in canonical names — would refuse a call the policy
    // just allowed, and the two layers would disagree in both directions.
    test('an agent allowlist written in canonical names matches the tool serving it', () async {
      final search = _RecordingTool('brave_search', McpToolAccess.read);
      final handler = McpProtocolHandler(
        guardChain: GuardChain(
          guards: [
            ToolPolicyGuard(
              cascade: ToolPolicyCascade(
                agentAllow: {
                  'search': {'web_search', 'web_fetch'},
                },
              ),
            ),
          ],
        ),
        auditLogger: audit,
      )..registerTool(search);
      final scoped = handler.scopedTo(
        _AllowListPolicy({'brave_search'}),
        toolCanonicals: const {'brave_search': CanonicalTool.webSearch},
        callerIdentity: const McpCallerIdentity(authorityId: 'authority-42', agentId: 'search'),
      );

      final result = _result(await _call(scoped, 'brave_search'));

      expect(result['isError'], isNull);
      expect(search.invocations, 1);
      // The audit trail still names the tool that ran, not its category.
      expect(audit.entries.single.tool, 'brave_search');
      expect(audit.entries.single.decision, 'allow');
    });

    test('a canonical the agent allowlist omits is still refused', () async {
      final search = _RecordingTool('brave_search', McpToolAccess.read);
      final handler = McpProtocolHandler(
        guardChain: GuardChain(
          guards: [
            ToolPolicyGuard(
              cascade: ToolPolicyCascade(
                agentAllow: {
                  'writer': {'memory_apply'},
                },
              ),
            ),
          ],
        ),
        auditLogger: audit,
      )..registerTool(search);
      final scoped = handler.scopedTo(
        _AllowListPolicy({'brave_search'}),
        toolCanonicals: const {'brave_search': CanonicalTool.webSearch},
        callerIdentity: const McpCallerIdentity(authorityId: 'authority-42', agentId: 'writer'),
      );

      final result = _result(await _call(scoped, 'brave_search'));

      expect(result['isError'], isTrue);
      expect(search.invocations, 0);
      expect(audit.entries.single.decision, 'deny');
    });
  });

  group('S06 authorization and schema rejection answer before the seam', () {
    test('policy denial, unknown name and schema rejection reach neither the guard nor the sink', () async {
      final strict = _RecordingTool(
        'probe_strict',
        McpToolAccess.read,
        inputSchema: {
          'type': 'object',
          'properties': {
            'query': {'type': 'string'},
          },
          'additionalProperties': false,
        },
      );
      final guard = _StubGuard(GuardVerdict.pass());
      final handler =
          McpProtocolHandler(
              guardChain: GuardChain(guards: [guard]),
              auditLogger: audit,
            )
            ..registerTool(writeTool)
            ..registerTool(strict);
      final policy = _AllowListPolicy({'probe_strict'});
      final scoped = handler.scopedTo(policy);

      final denied = await _call(scoped, 'probe_write');
      final unknown = await _call(scoped, 'no_such_tool');
      final invalid = await _call(scoped, 'probe_strict', arguments: {'unexpected': 1});

      expect((denied['error'] as Map<String, dynamic>)['code'], -32601);
      expect((unknown['error'] as Map<String, dynamic>)['code'], -32601);
      // Denied and unregistered answer in the same shape, so a scoped caller
      // cannot tell an existing tool it may not use from a missing one.
      expect((denied['error'] as Map<String, dynamic>)['message'], 'Tool not available: probe_write');
      expect((unknown['error'] as Map<String, dynamic>)['message'], 'Tool not available: no_such_tool');
      expect((invalid['error'] as Map<String, dynamic>)['code'], -32602);

      expect(policy.denied, ['probe_write', 'no_such_tool']);
      expect(guard.contexts, isEmpty);
      expect(audit.entries, isEmpty);
      expect(writeTool.invocations, 0);
      expect(strict.invocations, 0);
    });

    test('an unauthenticated contextual tool is refused without invoking it', () async {
      final handler = McpProtocolHandler(
        guardChain: GuardChain(guards: [_StubGuard(GuardVerdict.pass())]),
        auditLogger: audit,
      )..registerTool(_ContextualProbe());
      final scoped = handler.scopedTo(_AllowListPolicy({'probe_contextual'}));

      final result = _result(await _call(scoped, 'probe_contextual'));

      expect(result['isError'], isTrue);
      expect(_text(result), 'Tool requires authenticated caller context');
    });
  });
}

class _ContextualProbe implements ContextualMcpTool {
  @override
  String get name => 'probe_contextual';

  @override
  String get description => 'Contextual probe';

  @override
  Map<String, dynamic> get inputSchema => {'type': 'object', 'properties': <String, dynamic>{}};

  @override
  McpToolAccess get access => McpToolAccess.write;

  @override
  Future<ToolResult> call(Map<String, dynamic> args) async => fail('unauthenticated contextual tool must not run');

  @override
  Future<ToolResult> callWithContext(Map<String, dynamic> args, McpCallerContext context) async =>
      fail('unauthenticated contextual tool must not run');
}
