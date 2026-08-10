import 'dart:convert';

import 'package:dartclaw_security/dartclaw_security.dart' show isLoopbackHost;
import 'package:shelf/shelf.dart';

import '../auth/auth_utils.dart';
import 'mcp_server.dart';

/// Creates a shelf [Handler] for the `/mcp` endpoint.
///
/// Implements MCP Streamable HTTP transport (2025-03-26):
/// - `POST /mcp` — JSON-RPC request/response
/// - `GET /mcp` — not implemented in G01 (returns 405)
///
/// Auth: when [gatewayToken] is non-null, validates
/// `Authorization: Bearer <token>` against it. Bearerless access requires an
/// exact loopback request host.
Handler mcpRoute(McpProtocolHandler handler, {String? gatewayToken, bool requireLoopbackHost = false}) {
  if (gatewayToken == null && !requireLoopbackHost) {
    throw ArgumentError('Bearerless MCP requires loopback Host validation');
  }
  return (Request request) async {
    if (requireLoopbackHost && !_requestHasLoopbackHost(request)) {
      return _mcpError(403, 'Forbidden — invalid Host');
    }

    // Origin check: if browser sends Origin header, only allow an exact loopback host.
    // Non-browser clients (e.g. Claude Desktop) do not send Origin — allow them.
    final origin = request.headers['origin'];
    if (origin != null && !_isLoopbackOrigin(origin)) {
      return _mcpError(403, 'Forbidden — invalid Origin');
    }

    // Auth check: Bearer token
    if (gatewayToken != null) {
      final authHeader = request.headers['authorization'];
      if (authHeader == null || !authHeader.startsWith('Bearer ')) {
        return _mcpError(401, 'Unauthorized');
      }
      final token = authHeader.substring(7);
      if (token != gatewayToken) {
        return _mcpError(401, 'Unauthorized');
      }
    }

    // Method check
    if (request.method == 'GET') {
      return _mcpError(405, 'GET not implemented — use POST for JSON-RPC');
    }
    if (request.method != 'POST') {
      return _mcpError(405, 'Method not allowed');
    }

    // Content-Type check
    final contentType = request.headers['content-type'] ?? '';
    if (!contentType.contains('application/json')) {
      return _mcpError(415, 'Unsupported Media Type — expected application/json');
    }

    // Bounded body read: enforces 1 MiB limit at stream level, regardless of
    // Content-Length presence or truthfulness (covers chunked / spoofed headers).
    final body = await readBounded(request, maxWebhookPayloadBytes);
    if (body == null) {
      return _mcpError(413, 'Payload too large — 1 MB limit');
    }
    final response = await handler.handleRequest(body);

    // Null response means notification (no reply needed) — return 202 Accepted
    if (response == null) {
      return Response(202);
    }

    return Response.ok(response, headers: {'content-type': 'application/json'});
  };
}

bool _requestHasLoopbackHost(Request request) {
  final host = request.headers['host'];
  if (host == null || host.trim().isEmpty) return false;
  final uri = Uri.tryParse('http://${host.trim()}');
  return uri != null &&
      uri.hasAuthority &&
      uri.userInfo.isEmpty &&
      uri.path.isEmpty &&
      !uri.hasQuery &&
      !uri.hasFragment &&
      isLoopbackHost(uri.host);
}

bool _isLoopbackOrigin(String origin) {
  final uri = Uri.tryParse(origin);
  if (uri == null || !uri.hasAuthority || uri.userInfo.isNotEmpty || uri.path.isNotEmpty) return false;
  if (uri.hasQuery || uri.hasFragment || (uri.scheme != 'http' && uri.scheme != 'https')) return false;
  return isLoopbackHost(uri.host);
}

Response _mcpError(int status, String message) =>
    Response(status, body: jsonEncode({'error': message}), headers: {'content-type': 'application/json'});
