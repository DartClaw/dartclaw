import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart' show CanonicalTool, EventBus;
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:shelf/shelf.dart';

import '../auth/auth_rate_limiter.dart';
import '../auth/auth_utils.dart';
import 'context_engine_profile.dart';
import 'mcp_server.dart';

/// Creates a shelf [Handler] for the `/mcp` endpoint.
///
/// Implements MCP Streamable HTTP transport (2025-03-26):
/// - `POST /mcp` — JSON-RPC request/response
/// - `GET /mcp` — not implemented in G01 (returns 405)
///
/// Auth: `/mcp` authenticates its own callers rather than deferring to the
/// gateway auth middleware, because a client bearer is not the gateway token and
/// the middleware knows only that one credential. When [gatewayToken] is
/// non-null, `Authorization: Bearer <token>` is compared constant-time against
/// it and then against every [clients] token: the gateway token reaches the
/// unscoped [handler] as the deployment itself, a client token reaches a handler
/// scoped to the context-engine profile and audited under that client's
/// principal, and anything else is a `401` recorded on [rateLimiter] — the same
/// failed-auth throttle that protects the gateway token elsewhere. Bearerless
/// access requires an exact loopback request host.
Handler mcpRoute(
  McpProtocolHandler handler, {
  String? gatewayToken,
  bool requireLoopbackHost = false,
  List<McpClientConfig> clients = const [],
  GuardAuditLogger? auditLogger,
  Map<String, CanonicalTool> toolCanonicals = const {},
  AuthRateLimiter? rateLimiter,
  EventBus? eventBus,
  List<String> trustedProxies = const [],
}) {
  if (gatewayToken == null && !requireLoopbackHost) {
    throw ArgumentError('Bearerless MCP requires loopback Host validation');
  }
  if (clients.isNotEmpty && gatewayToken == null) {
    throw ArgumentError('MCP clients require gateway token authentication');
  }

  final scopedHandlers = {
    for (final client in clients)
      client.token: handler.scopedTo(
        ContextEngineCallerPolicy(principal: mcpClientPrincipal(client.name), auditLogger: auditLogger),
        toolCanonicals: toolCanonicals,
        callerIdentity: McpCallerIdentity(authorityId: mcpClientPrincipal(client.name)),
      ),
  };

  /// Resolves [bearer] without short-circuiting, so the number of comparisons
  /// does not reveal which credential a guess was closest to.
  McpProtocolHandler? resolveCaller(String bearer) {
    McpProtocolHandler? resolved;
    if (constantTimeEquals(bearer, gatewayToken!)) resolved = handler;
    for (final entry in scopedHandlers.entries) {
      if (constantTimeEquals(bearer, entry.key)) resolved ??= entry.value;
    }
    return resolved;
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

    // Auth check: Bearer token — the gateway token, or one configured client's.
    var caller = handler;
    if (gatewayToken != null) {
      final authHeader = request.headers['authorization'];
      final bearer = authHeader != null && authHeader.startsWith('Bearer ') ? authHeader.substring(7) : null;
      final resolved = bearer == null ? null : resolveCaller(bearer);
      final remoteKey = requestRemoteKey(request, trustedProxies: trustedProxies) ?? 'unknown';
      if (resolved == null) {
        final limited = rateLimiter?.shouldLimit(remoteKey) ?? false;
        if (!limited) rateLimiter?.recordFailure(remoteKey);
        fireFailedAuthEvent(
          eventBus,
          request,
          source: 'mcp',
          reason: bearer == null ? 'missing_credentials' : 'invalid_bearer',
          limited: limited,
          trustedProxies: trustedProxies,
        );
        if (limited) {
          return _mcpError(429, 'Too many failed authentication attempts');
        }
        return _mcpError(401, 'Unauthorized');
      }
      // Only a gateway-token success clears the window. The limiter is shared
      // with `authMiddleware` and keyed by remote alone, so letting a client
      // token reset it would let the least-trusted credential the design admits
      // disable the control protecting the gateway token, the REST API and the
      // web UI from that address — four guesses interleaved with one valid
      // client call, indefinitely.
      if (identical(resolved, handler)) rateLimiter?.reset(remoteKey);
      caller = resolved;
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
    final response = await caller.handleRequest(body);

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
