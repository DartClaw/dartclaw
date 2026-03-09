/// Result of an MCP tool invocation.
///
/// Tools return [ToolResult.text] for successful results or [ToolResult.error]
/// for handled errors. Unhandled exceptions thrown by tool handlers are caught
/// by the MCP server and converted to [ToolResult.error] automatically.
///
/// Error results produce a successful JSON-RPC response with `isError: true`
/// in the MCP content — not a JSON-RPC protocol error. This follows the MCP
/// spec: tool errors are application-level, not protocol-level.
sealed class ToolResult {
  const ToolResult();

  /// Successful result with text content returned to the agent.
  const factory ToolResult.text(String content) = ToolResultText;

  /// Error result — returned as error content to the agent (not an exception).
  /// The agent sees the error message and can decide how to proceed.
  const factory ToolResult.error(String message) = ToolResultError;
}

/// Successful tool result containing text content.
class ToolResultText extends ToolResult {
  /// The text content to return to the agent.
  final String content;

  const ToolResultText(this.content);
}

/// Error tool result containing an error message.
///
/// This is returned as a successful MCP response with `isError: true`,
/// not as a JSON-RPC error. The agent receives the message and can retry
/// or adapt its approach.
class ToolResultError extends ToolResult {
  /// The error message returned to the agent.
  final String message;

  const ToolResultError(this.message);
}
