import 'package:dartclaw_core/dartclaw_core.dart';

import '../memory_handlers.dart' show maxMemorySaveCategoryLength, maxMemorySaveTextLength, maxMemorySearchResults;
import 'mcp_utils.dart';

/// Callback type matching the memory handler signature from
/// `createMemoryHandlers()`.
typedef MemoryHandler = Future<Map<String, dynamic>> Function(Map<String, dynamic>);

/// MCP tool for saving a fact or preference to persistent memory.
class MemorySaveTool implements McpTool {
  final MemoryHandler _handler;

  MemorySaveTool({required MemoryHandler handler}) : _handler = handler;

  @override
  String get name => 'memory_save';

  @override
  String get description => 'Save a fact, preference, or piece of knowledge to persistent memory.';

  @override
  Map<String, dynamic> get inputSchema => {
    'type': 'object',
    'properties': {
      'text': {'type': 'string', 'maxLength': maxMemorySaveTextLength, 'description': 'The text to save'},
      'category': {
        'type': 'string',
        'maxLength': maxMemorySaveCategoryLength,
        'description': 'Category (e.g. preferences, project)',
      },
    },
    'required': ['text'],
    'additionalProperties': false,
  };

  @override
  Future<ToolResult> call(Map<String, dynamic> args) async {
    final result = await _handler(args);
    return ToolResult.text(extractMcpText(result));
  }
}

/// MCP tool for searching saved memories using natural language.
class MemorySearchTool implements McpTool {
  final MemoryHandler _handler;

  MemorySearchTool({required MemoryHandler handler}) : _handler = handler;

  @override
  String get name => 'memory_search';

  @override
  String get description => 'Search saved memories using natural language.';

  @override
  Map<String, dynamic> get inputSchema => {
    'type': 'object',
    'properties': {
      'query': {'type': 'string', 'description': 'Search query'},
      'limit': {
        'type': 'integer',
        'description': 'Number of results (1-$maxMemorySearchResults, default 5)',
        'default': 5,
        'minimum': 1,
        'maximum': maxMemorySearchResults,
      },
    },
    'required': ['query'],
    'additionalProperties': false,
  };

  @override
  Future<ToolResult> call(Map<String, dynamic> args) async {
    final result = await _handler(args);
    return ToolResult.text(extractMcpText(result));
  }
}

/// MCP tool for reading the full contents of MEMORY.md.
class MemoryReadTool implements McpTool {
  final MemoryHandler _handler;

  MemoryReadTool({required MemoryHandler handler}) : _handler = handler;

  @override
  String get name => 'memory_read';

  @override
  String get description => 'Read the full contents of MEMORY.md.';

  @override
  Map<String, dynamic> get inputSchema => {
    'type': 'object',
    'properties': <String, dynamic>{},
    'additionalProperties': false,
  };

  @override
  Future<ToolResult> call(Map<String, dynamic> args) async {
    final result = await _handler(args);
    return ToolResult.text(extractMcpText(result));
  }
}
