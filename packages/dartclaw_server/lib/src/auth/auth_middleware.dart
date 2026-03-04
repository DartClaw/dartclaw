import 'dart:convert';

import 'package:shelf/shelf.dart';

import 'session_token.dart';
import 'token_service.dart';

const _publicPaths = {'/health', '/login', '/favicon.ico'};

/// URL prefixes that bypass authentication entirely.
///
/// **Security note**: Any route under these prefixes is auth-exempt. This is
/// correct for webhook callbacks (which use per-route shared secrets) and
/// static assets, but adding new routes under these prefixes without their
/// own auth will create an unauthenticated endpoint. Always verify that new
/// webhook-style routes include per-route secret validation.
const _publicPrefixes = ['/webhook/', '/static/'];

/// Auth middleware for the DartClaw gateway.
///
/// Uses stateless HMAC-signed cookies — no server-side session storage.
/// Cookies survive server restarts; `token rotate` auto-invalidates all
/// sessions (new token won't match old cookie signatures).
///
/// Check order:
/// 1. Public path -> pass through
/// 2. Valid session cookie (HMAC-signed) -> pass through
/// 3. Valid Bearer token -> pass through
/// 4. GET / with `?token=<valid>` -> set cookie, redirect /
/// 5. Else -> browser? redirect /login : 401 JSON
Middleware authMiddleware({
  required TokenService tokenService,
  required String gatewayToken,
  bool enabled = true,
}) {
  if (!enabled) return (Handler inner) => inner;

  return (Handler inner) => (Request request) async {
    final path = '/${request.url.path}';

    // 1. Public paths
    if (_publicPaths.contains(path) || _publicPrefixes.any(path.startsWith)) {
      return inner(request);
    }

    // 2. Session cookie (HMAC-signed, stateless)
    final cookieHeader = request.headers['cookie'];
    if (cookieHeader != null) {
      final token = _parseCookie(cookieHeader, sessionCookieName);
      if (token != null && validateSessionToken(token, gatewayToken)) {
        return inner(request);
      }
    }

    // 3. Bearer token
    final authHeader = request.headers['authorization'];
    if (authHeader != null && authHeader.startsWith('Bearer ')) {
      final candidate = authHeader.substring(7);
      if (tokenService.validateToken(candidate)) {
        return inner(request);
      }
    }

    // 4. Token bootstrap: GET / with ?token=<valid>
    if (request.method == 'GET' && request.url.path.isEmpty) {
      final tokenParam = request.url.queryParameters['token'];
      if (tokenParam != null && tokenService.validateToken(tokenParam)) {
        final sessionToken = createSessionToken(gatewayToken);
        return Response.found('/', headers: {
          'set-cookie': sessionCookieHeader(sessionToken),
        });
      }
    }

    // 5. Unauthorized
    final isBrowser = request.headers['accept']?.contains('text/html') ?? false;
    if (isBrowser) {
      return Response.found('/login');
    }
    return Response(
      401,
      body: jsonEncode({'error': 'Unauthorized', 'message': 'Valid token required'}),
      headers: {'content-type': 'application/json'},
    );
  };
}

/// Parses a specific cookie value from the Cookie header.
String? _parseCookie(String header, String name) {
  for (final part in header.split(';')) {
    final trimmed = part.trim();
    final eq = trimmed.indexOf('=');
    if (eq < 0) continue;
    if (trimmed.substring(0, eq).trim() == name) {
      return trimmed.substring(eq + 1).trim();
    }
  }
  return null;
}
