import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart' show McpToolAccess, ToolResult, TurnProvenance;
import 'package:dartclaw_runtime/src/mcp/mcp_server.dart';
import 'package:test/test.dart';

/// Sends a `tools/call` for [name] through [handler] and returns the decoded JSON-RPC response.
Future<Map<String, dynamic>> callTool(
  McpProtocolHandler handler,
  String name, {
  Map<String, dynamic> arguments = const {},
}) async {
  final raw = await handler.handleRequest(
    jsonEncode({
      'jsonrpc': '2.0',
      'id': 1,
      'method': 'tools/call',
      'params': {'name': name, 'arguments': arguments},
    }),
  );
  return jsonDecode(raw!) as Map<String, dynamic>;
}

/// The `result` of a `tools/call` [response]; a tool refusal is a JSON-RPC success carrying `isError`.
Map<String, dynamic> toolResult(Map<String, dynamic> response) {
  expect(response['error'], isNull, reason: 'a tool refusal must be a JSON-RPC success carrying isError');
  return response['result'] as Map<String, dynamic>;
}

String resultText(Map<String, dynamic> result) =>
    ((result['content'] as List).single as Map<String, dynamic>)['text'] as String;

Map<String, dynamic> resultPayload(Map<String, dynamic> result) =>
    jsonDecode(resultText(result)) as Map<String, dynamic>;

/// A scoped-caller policy that authorizes every tool.
final class AllowAllCallerPolicy implements McpCallerPolicy {
  @override
  bool allows(String toolName) => true;

  @override
  void onDenied(String toolName) {}
}

/// A read-only [TurnAwareMcpTool] that records the context each opted-in call carries.
///
/// A plain [call] answers `no context` and records nothing.
final class TurnProbeTool implements TurnAwareMcpTool {
  final contexts = <McpCallerContext>[];

  List<TurnProvenance?> get turns => [for (final context in contexts) context.turn];

  @override
  String get name => 'turn_probe';

  @override
  String get description => 'records the context it is called with';

  @override
  Map<String, dynamic> get inputSchema => const {'type': 'object', 'properties': <String, Object?>{}};

  @override
  McpToolAccess get access => McpToolAccess.read;

  @override
  Future<ToolResult> call(Map<String, dynamic> args) async => ToolResult.text('no context');

  @override
  Future<ToolResult> callWithTurn(Map<String, dynamic> args, McpCallerContext context) async {
    contexts.add(context);
    return ToolResult.text('ok');
  }
}
