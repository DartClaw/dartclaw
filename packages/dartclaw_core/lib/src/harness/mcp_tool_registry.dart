import 'dart:async';

import 'package:logging/logging.dart';

/// Definition of a single MCP tool with handler.
class McpToolDef {
  final String name;
  final String description;
  final Map<String, dynamic> inputSchema;
  final Future<Map<String, dynamic>> Function(Map<String, dynamic>) handler;
  final Duration timeout;

  const McpToolDef({
    required this.name,
    required this.description,
    required this.inputSchema,
    required this.handler,
    this.timeout = const Duration(seconds: 30),
  });
}

/// Registry for Dart-backed MCP tools. Manages tool definitions, dispatches
/// calls to handlers, and generates the `sdkMcpServers` map for the
/// initialize handshake.
class McpToolRegistry {
  static final _log = Logger('McpToolRegistry');

  final Map<String, McpToolDef> _tools = {};
  final Map<String, String> _toolToServer = {};
  final Map<String, List<McpToolDef>> _servers = {};

  /// Registers tools under a named MCP server.
  void registerServer(String serverName, List<McpToolDef> tools) {
    _servers[serverName] = tools;
    for (final tool in tools) {
      if (_tools.containsKey(tool.name)) {
        _log.warning('Tool "${tool.name}" already registered by '
            '"${_toolToServer[tool.name]}" — skipping duplicate from "$serverName"');
        continue;
      }
      _tools[tool.name] = tool;
      _toolToServer[tool.name] = serverName;
    }
  }

  /// Dispatches a tool call to the registered handler.
  /// Returns MCP result format. Unknown tools and timeouts return error results.
  Future<Map<String, dynamic>> dispatch(String toolName, Map<String, dynamic> args) async {
    final tool = _tools[toolName];
    if (tool == null) {
      _log.warning('Unknown MCP tool: $toolName');
      return {
        'content': [{'type': 'text', 'text': 'Unknown tool: $toolName'}],
        'isError': true,
      };
    }

    try {
      return await tool.handler(args).timeout(tool.timeout);
    } on TimeoutException {
      _log.warning('MCP tool "$toolName" timed out after ${tool.timeout.inSeconds}s');
      return {
        'content': [{'type': 'text', 'text': 'Tool timeout after ${tool.timeout.inSeconds}s'}],
        'isError': true,
      };
    } catch (e) {
      _log.warning('MCP tool "$toolName" error: $e');
      return {
        'content': [{'type': 'text', 'text': 'Error: $e'}],
        'isError': true,
      };
    }
  }

  /// Whether any tools are registered.
  bool get isEmpty => _servers.isEmpty;

  /// Builds the `sdkMcpServers` map for the initialize handshake.
  Map<String, dynamic> toSdkMcpServers() {
    final result = <String, dynamic>{};
    for (final entry in _servers.entries) {
      result[entry.key] = {
        'type': 'sdk_mcp_server',
        'tools': [
          for (final tool in entry.value)
            {
              'name': tool.name,
              'description': tool.description,
              'input_schema': tool.inputSchema,
            },
        ],
      };
    }
    return result;
  }
}
