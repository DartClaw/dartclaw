import 'dart:convert';

import 'package:shelf/shelf.dart';

import 'session_store.dart';
import 'token_service.dart';

const _publicPaths = {'/health', '/login', '/favicon.ico'};
const _publicPrefixes = ['/webhook/', '/static/'];

const _cookieName = 'dart_session';
const _cookieMaxAge = 2592000; // 30 days in seconds

/// Auth middleware for the DartClaw gateway.
///
/// Check order:
/// 1. Public path -> pass through
/// 2. Valid session cookie -> pass through
/// 3. Valid Bearer token -> pass through
/// 4. GET / with `?token=<valid>` -> set cookie, redirect /
/// 5. Else -> browser? redirect /login : 401 JSON
Middleware authMiddleware({
  required TokenService tokenService,
  required SessionStore sessionStore,
  bool enabled = true,
}) {
  if (!enabled) return (Handler inner) => inner;

  return (Handler inner) => (Request request) async {
    final path = '/${request.url.path}';

    // 1. Public paths
    if (_publicPaths.contains(path) || _publicPrefixes.any(path.startsWith)) {
      return inner(request);
    }

    // 2. Session cookie
    final cookieHeader = request.headers['cookie'];
    if (cookieHeader != null) {
      final sessionId = _parseCookie(cookieHeader, _cookieName);
      if (sessionId != null && sessionStore.validate(sessionId)) {
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
        final sessionId = sessionStore.createSession();
        return Response.found('/', headers: {
          'set-cookie': '$_cookieName=$sessionId; HttpOnly; SameSite=Strict; Path=/; Max-Age=$_cookieMaxAge',
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
