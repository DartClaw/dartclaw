import 'tool_result.dart';

/// Whether an MCP tool observes host state or changes it.
///
/// Declared on every tool so a caller that partitions the tool surface reads
/// one authority instead of a hand-maintained name list.
enum McpToolAccess {
  /// Observes host state without changing it.
  read,

  /// Changes host state, or reaches a destination the host cannot bound — a
  /// caller-supplied target, or a third party whose behaviour it cannot verify.
  /// A tool that only queries a fixed configured provider is [read].
  write,
}

/// Abstract interface for MCP tools registered with the DartClaw MCP server.
///
/// Tool implementers define [name], [description], [inputSchema] (JSON Schema),
/// [access], and a [call] handler. The MCP server exposes these via
/// `tools/list` and dispatches `tools/call` requests to the appropriate
/// handler.
///
/// Tools must be registered before the server starts handling requests via
/// `DartclawServer.registerTool()`. Duplicate names are silently skipped
/// (first registration wins).
abstract interface class McpTool {
  /// Unique tool name (e.g. `sessions_send`).
  String get name;

  /// Human-readable description shown in the tool manifest.
  String get description;

  /// JSON Schema for the tool's input parameters.
  Map<String, dynamic> get inputSchema;

  /// Whether this tool observes host state or changes it.
  ///
  /// Required and undefaulted: a tool that omits it fails to compile rather
  /// than falling into the permissive half of a read/write partition.
  McpToolAccess get access;

  /// Execute the tool with the given [args].
  ///
  /// Return [ToolResult.text] for success or [ToolResult.error] for handled
  /// errors. Unhandled exceptions are caught by the MCP server and converted
  /// to [ToolResult.error] automatically — but prefer explicit error returns
  /// for predictable agent behavior.
  ///
  /// Handlers may be called concurrently from multiple agent turns.
  /// Implementations must be reentrant or use their own synchronization.
  Future<ToolResult> call(Map<String, dynamic> args);
}
