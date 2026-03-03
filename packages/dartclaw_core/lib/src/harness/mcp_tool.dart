/// Abstract interface for MCP tools registered with the internal MCP server.
///
/// Tool implementers define [name], [description], [inputSchema] (JSON Schema),
/// and a [call] handler. The MCP server exposes these via `tools/list` and
/// dispatches `tools/call` requests to the appropriate handler.
abstract interface class McpTool {
  /// Unique tool name (e.g. `sessions_send`).
  String get name;

  /// Human-readable description shown in the tool manifest.
  String get description;

  /// JSON Schema for the tool's input parameters.
  Map<String, dynamic> get inputSchema;

  /// Execute the tool with the given [args] and return a text result.
  ///
  /// Throws on error — the MCP server translates exceptions to JSON-RPC errors.
  Future<String> call(Map<String, dynamic> args);
}
