import 'dart:convert';

import 'package:shelf/shelf.dart';

import '../auth/auth_utils.dart';
import 'mcp_server.dart';

/// Creates a shelf [Handler] for the `/mcp` endpoint.
///
/// Implements MCP Streamable HTTP transport (2025-03-26):
/// - `POST /mcp` — JSON-RPC request/response
/// - `GET /mcp` — not implemented in G01 (returns 405)
///
/// Auth: validates `Authorization: Bearer <token>` against [gatewayToken].
Handler mcpRoute(McpProtocolHandler handler, {required String gatewayToken}) {
  return (Request request) async {
    // Origin check: if browser sends Origin header, only allow localhost.
    // Non-browser clients (e.g. Claude Desktop) do not send Origin — allow them.
    final origin = request.headers['origin'];
    if (origin != null) {
      final allowed =
          origin.startsWith('http://localhost') ||
          origin.startsWith('https://localhost') ||
          origin.startsWith('http://127.0.0.1') ||
          origin.startsWith('https://127.0.0.1');
      if (!allowed) {
        return _mcpError(403, 'Forbidden — invalid Origin');
      }
    }

    // Auth check: Bearer token
    final authHeader = request.headers['authorization'];
    if (authHeader == null || !authHeader.startsWith('Bearer ')) {
      return _mcpError(401, 'Unauthorized');
    }
    final token = authHeader.substring(7);
    if (token != gatewayToken) {
      return _mcpError(401, 'Unauthorized');
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

Response _mcpError(int status, String message) =>
    Response(status, body: jsonEncode({'error': message}), headers: {'content-type': 'application/json'});
