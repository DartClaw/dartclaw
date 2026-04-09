import 'package:dartclaw_core/dartclaw_core.dart';

import 'canvas_service.dart';
import 'canvas_state.dart';
import 'canvas_utils.dart';

/// MCP tool for pushing content to the workshop canvas and creating share links.
class CanvasTool implements McpTool {
  final CanvasService _canvasService;
  final String _sessionKey;
  final String? _baseUrl;
  final CanvasPermission _defaultPermission;
  final Duration _defaultTtl;

  CanvasTool({
    required CanvasService canvasService,
    required String sessionKey,
    String? baseUrl,
    CanvasPermission defaultPermission = CanvasPermission.interact,
    Duration defaultTtl = const Duration(hours: 8),
  })
    : _canvasService = canvasService,
      _sessionKey = sessionKey,
      _baseUrl = baseUrl,
      _defaultPermission = defaultPermission,
      _defaultTtl = defaultTtl;

  @override
  String get name => 'canvas';

  @override
  String get description => 'Push HTML content to the shared canvas, manage visibility, and generate share links.';

  @override
  Map<String, dynamic> get inputSchema => {
    'type': 'object',
    'properties': {
      'action': {
        'type': 'string',
        'enum': ['render', 'clear', 'share', 'present', 'hide'],
        'description': 'Canvas action to execute',
      },
      'html': {'type': 'string', 'description': 'HTML fragment to render (required for action=render)'},
      'permission': {
        'type': 'string',
        'enum': ['view', 'interact'],
        'description': 'Share token permission (default: interact)',
      },
      'ttl': {'type': 'string', 'description': 'Share token TTL, e.g. "30m" or "8h"'},
    },
    'required': ['action'],
    'additionalProperties': false,
  };

  @override
  Future<ToolResult> call(Map<String, dynamic> args) async {
    final action = _trimmedString(args['action'])?.toLowerCase();
    if (action == null) {
      return ToolResult.error('Missing required parameter "action"');
    }

    switch (action) {
      case 'render':
        final html = _trimmedString(args['html']);
        if (html == null) {
          return ToolResult.error('Missing required parameter "html" for action=render');
        }
        try {
          _canvasService.push(_sessionKey, html);
        } on ArgumentError catch (e) {
          return ToolResult.error('${e.message}');
        }
        return const ToolResult.text('Canvas updated');
      case 'clear':
        _canvasService.clear(_sessionKey);
        return const ToolResult.text('Canvas cleared');
      case 'present':
        _canvasService.setVisible(_sessionKey, true);
        return const ToolResult.text('Canvas visible');
      case 'hide':
        _canvasService.setVisible(_sessionKey, false);
        return const ToolResult.text('Canvas hidden');
      case 'share':
        final baseUrl = _baseUrl;
        if (baseUrl == null) {
          return ToolResult.error('Canvas share links require server.baseUrl to be configured');
        }
        final permission = CanvasPermission.fromName(_trimmedString(args['permission']) ?? _defaultPermission.name);
        if (permission == null) {
          return ToolResult.error('Invalid "permission" value. Expected "view" or "interact".');
        }
        final ttlString = _trimmedString(args['ttl']);
        final ttl = ttlString == null ? _defaultTtl : parseDuration(ttlString);
        if (ttl == null || ttl <= Duration.zero) {
          return ToolResult.error(
            'Invalid "ttl" value "${ttlString ?? _defaultTtl}". Use formats like 30m, 8h, or 1d.',
          );
        }
        final shareToken = _canvasService.createShareToken(_sessionKey, permission: permission, ttl: ttl);
        final normalizedBaseUrl = baseUrl.replaceFirst(RegExp(r'/+$'), '');
        return ToolResult.text('Share URL: $normalizedBaseUrl/canvas/${shareToken.token}');
      default:
        return ToolResult.error('Unknown canvas action: $action');
    }
  }
}

String? _trimmedString(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}
