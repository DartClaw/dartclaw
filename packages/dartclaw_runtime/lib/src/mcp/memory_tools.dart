import 'package:dartclaw_core/dartclaw_core.dart';

import '../memory_handlers.dart' show maxMemoryCaptureTextLength, maxMemorySearchResults;
import 'mcp_utils.dart';
import 'mcp_server.dart';

/// Runs one memory tool call as [context]'s caller, against the memory that caller resolves to.
typedef MemoryHandler = Future<Map<String, dynamic>> Function(Map<String, dynamic> args, McpCallerContext context);

/// MCP tool for provenance-labelled observation and learning capture.
class MemoryObserveTool extends ContextualMcpTool {
  final MemoryHandler _handler;

  new({required MemoryHandler handler}) : _handler = handler;

  @override
  String get name => 'memory_observe';

  @override
  String get description => 'Record a non-authoritative observation or runtime learning.';

  @override
  Map<String, dynamic> get inputSchema => {
    'type': 'object',
    'properties': {
      'text': {'type': 'string', 'maxLength': maxMemoryCaptureTextLength, 'description': 'The text to record'},
      'role': {
        'type': 'string',
        'enum': ['observation', 'learning'],
        'description': 'Canonical capture role',
      },
    },
    'required': ['text', 'role'],
    'additionalProperties': false,
  };

  @override
  McpToolAccess get access => McpToolAccess.write;

  @override
  Future<ToolResult> callWithContext(Map<String, dynamic> args, McpCallerContext context) async =>
      ToolResult.text(extractMcpText(await _handler(args, context)));
}

/// MCP tool for atomically curating personal memory with collection CAS.
class MemoryApplyTool extends ContextualMcpTool {
  final MemoryHandler _handler;

  new({required MemoryHandler handler}) : _handler = handler;

  @override
  String get name => 'memory_apply';

  @override
  String get description => 'Atomically add, revise, merge, or remove curated personal memory.';

  @override
  Map<String, dynamic> get inputSchema => {
    'type': 'object',
    'properties': {
      'expectedRevision': {'type': 'integer', 'minimum': 1},
      'operations': {'type': 'array', 'minItems': 1, 'items': memoryApplyOperationSchema},
    },
    'required': ['expectedRevision', 'operations'],
    'additionalProperties': false,
  };

  @override
  McpToolAccess get access => McpToolAccess.write;

  @override
  Future<ToolResult> callWithContext(Map<String, dynamic> args, McpCallerContext context) async =>
      ToolResult.text(extractMcpText(await _handler(args, context)));
}

/// MCP tool for searching saved memories using natural language.
class MemorySearchTool extends ContextualMcpTool {
  final MemoryHandler _handler;

  new({required MemoryHandler handler}) : _handler = handler;

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
  McpToolAccess get access => McpToolAccess.read;

  @override
  Future<ToolResult> callWithContext(Map<String, dynamic> args, McpCallerContext context) async =>
      ToolResult.text(extractMcpText(await _handler(args, context)));
}

/// MCP tool for bounded source-of-record reads.
class MemoryReadTool extends ContextualMcpTool {
  final MemoryHandler _handler;

  new({required MemoryHandler handler}) : _handler = handler;

  @override
  String get name => 'memory_read';

  @override
  String get description => 'Read canonical memory or a native knowledge source by stable selector.';

  @override
  Map<String, dynamic> get inputSchema => {
    'type': 'object',
    'properties': <String, dynamic>{
      'locator': {'type': 'string', 'description': 'Stable locator returned by memory_search'},
      'role': {
        'type': 'string',
        'enum': ['topic', 'archive'],
        'description': 'Topic-bearing canonical role',
      },
      'topic': {'type': 'string', 'description': 'Canonical topic slug'},
      'limit': {
        'type': 'integer',
        'description': 'Number of records (1-$maxMemorySearchResults, default 5)',
        'default': 5,
        'minimum': 1,
        'maximum': maxMemorySearchResults,
      },
    },
    'oneOf': [
      {
        'required': ['locator'],
        'not': {
          'anyOf': [
            {
              'required': ['role'],
            },
            {
              'required': ['topic'],
            },
          ],
        },
      },
      {
        'required': ['role', 'topic'],
        'not': {
          'required': ['locator'],
        },
      },
    ],
    'additionalProperties': false,
  };

  @override
  McpToolAccess get access => McpToolAccess.read;

  @override
  Future<ToolResult> callWithContext(Map<String, dynamic> args, McpCallerContext context) async =>
      ToolResult.text(extractMcpText(await _handler(args, context)));
}
