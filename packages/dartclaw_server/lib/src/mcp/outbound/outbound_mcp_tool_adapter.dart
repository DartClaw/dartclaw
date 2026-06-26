import 'package:dartclaw_core/dartclaw_core.dart' show McpTool, ToolResult;

import 'outbound_mcp_client.dart';
import 'outbound_mcp_models.dart';
import 'outbound_mcp_pool.dart';

/// Supplies the caller identity used for outbound MCP guard and audit decisions.
typedef OutboundMcpCallerProvider = OutboundMcpCaller Function();

/// Returns the harness-facing tool name for an external MCP server tool.
String outboundMcpToolName({required String serverName, required String toolName}) => 'mcp__${serverName}__$toolName';

/// Adapts one surfaced outbound MCP tool to the inbound [McpTool] contract.
final class OutboundMcpToolAdapter implements McpTool {
  /// External MCP server name in the configured registry.
  final String serverName;

  /// External MCP tool metadata advertised by the server.
  final OutboundMcpTool tool;

  /// Pool that owns outbound connections and guard/governance enforcement.
  final OutboundMcpPool pool;

  /// Provider for the caller identity attached to each outbound tool call.
  final OutboundMcpCallerProvider callerProvider;

  /// Creates an adapter for one surfaced [tool] on [serverName].
  OutboundMcpToolAdapter({
    required this.serverName,
    required this.tool,
    required this.pool,
    required this.callerProvider,
  });

  /// Namespaced tool name exposed to harness-facing MCP clients.
  @override
  String get name => outboundMcpToolName(serverName: serverName, toolName: tool.name);

  /// Description advertised to harness-facing MCP clients.
  @override
  String get description => tool.description ?? 'External MCP tool ${tool.name} from $serverName.';

  /// Input schema advertised to harness-facing MCP clients.
  @override
  Map<String, dynamic> get inputSchema => tool.inputSchema;

  /// Dispatches the call through [OutboundMcpPool.callTool] and maps the result.
  @override
  Future<ToolResult> call(Map<String, dynamic> args) async {
    final result = await pool.callTool(
      serverName: serverName,
      toolName: tool.name,
      arguments: args,
      caller: callerProvider(),
    );
    return toToolResult(result);
  }
}
