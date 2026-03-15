import 'dart:convert';

import 'package:shelf/shelf.dart';

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
        return Response(
          403,
          body: jsonEncode({'error': 'Forbidden — invalid Origin'}),
          headers: {'content-type': 'application/json'},
        );
      }
    }

    // Auth check: Bearer token
    final authHeader = request.headers['authorization'];
    if (authHeader == null || !authHeader.startsWith('Bearer ')) {
      return Response(401, body: jsonEncode({'error': 'Unauthorized'}), headers: {'content-type': 'application/json'});
    }
    final token = authHeader.substring(7);
    if (token != gatewayToken) {
      return Response(401, body: jsonEncode({'error': 'Unauthorized'}), headers: {'content-type': 'application/json'});
    }

    // Method check
    if (request.method == 'GET') {
      return Response(
        405,
        body: jsonEncode({'error': 'GET not implemented — use POST for JSON-RPC'}),
        headers: {'content-type': 'application/json'},
      );
    }
    if (request.method != 'POST') {
      return Response(
        405,
        body: jsonEncode({'error': 'Method not allowed'}),
        headers: {'content-type': 'application/json'},
      );
    }

    // Content-Type check
    final contentType = request.headers['content-type'] ?? '';
    if (!contentType.contains('application/json')) {
      return Response(
        415,
        body: jsonEncode({'error': 'Unsupported Media Type — expected application/json'}),
        headers: {'content-type': 'application/json'},
      );
    }

    // Body size check: reject oversized payloads before reading.
    final contentLength = int.tryParse(request.headers['content-length'] ?? '');
    if (contentLength != null && contentLength > 1024 * 1024) {
      return Response(
        413,
        body: jsonEncode({'error': 'Payload too large — 1 MB limit'}),
        headers: {'content-type': 'application/json'},
      );
    }

    // Read body and dispatch to protocol handler
    final body = await request.readAsString();
    final response = await handler.handleRequest(body);

    // Null response means notification (no reply needed) — return 202 Accepted
    if (response == null) {
      return Response(202);
    }

    return Response.ok(response, headers: {'content-type': 'application/json'});
  };
}
