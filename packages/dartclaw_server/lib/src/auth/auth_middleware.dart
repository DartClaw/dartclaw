import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:shelf/shelf.dart';

import 'auth_rate_limiter.dart';
import 'auth_utils.dart';
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
/// 4. GET with `?token=<valid>` -> set cookie, redirect back to same route
/// 5. Else -> browser? redirect /login : 401 JSON
Middleware authMiddleware({
  required TokenService tokenService,
  required String gatewayToken,
  bool enabled = true,
  bool cookieSecure = false,
  List<String> trustedProxies = const [],
  EventBus? eventBus,
  AuthRateLimiter? rateLimiter,
  List<String> publicPaths = const [],
  List<String> publicPrefixes = const [],
}) {
  if (!enabled) return (Handler inner) => inner;

  return (Handler inner) => (Request request) async {
    final path = '/${request.url.path}';
    final remoteKey = requestRemoteKey(request, trustedProxies: trustedProxies) ?? 'unknown';
    final allowedPaths = {..._publicPaths, ...publicPaths};
    final allowedPrefixes = [..._publicPrefixes, ...publicPrefixes];

    // 1. Public paths
    if (allowedPaths.contains(path) || allowedPrefixes.any(path.startsWith)) {
      return inner(request);
    }

    // 2. Session cookie (HMAC-signed, stateless)
    final cookieHeader = request.headers['cookie'];
    if (cookieHeader != null) {
      final token = _parseCookie(cookieHeader, sessionCookieName);
      if (token != null && validateSessionToken(token, gatewayToken)) {
        rateLimiter?.reset(remoteKey);
        return inner(request);
      }
    }

    // 3. Bearer token
    final authHeader = request.headers['authorization'];
    if (authHeader != null && authHeader.startsWith('Bearer ')) {
      final candidate = authHeader.substring(7);
      if (tokenService.validateToken(candidate)) {
        rateLimiter?.reset(remoteKey);
        return inner(request);
      }
    }

    // 4. Token bootstrap: any GET with ?token=<valid>
    if (request.method == 'GET') {
      final tokenParam = request.url.queryParameters['token'];
      if (tokenParam != null && tokenService.validateToken(tokenParam)) {
        rateLimiter?.reset(remoteKey);
        final sessionToken = createSessionToken(gatewayToken);
        return Response.found(
          _locationWithoutToken(request),
          headers: {'set-cookie': sessionCookieHeader(sessionToken, secure: cookieSecure)},
        );
      }
    }

    // 5. Unauthorized
    final limited = rateLimiter?.shouldLimit(remoteKey) ?? false;
    if (!limited) {
      rateLimiter?.recordFailure(remoteKey);
    }
    fireFailedAuthEvent(
      eventBus,
      request,
      source: 'gateway',
      reason: _failureReason(request),
      limited: limited,
      trustedProxies: trustedProxies,
    );
    if (limited) {
      return Response(
        429,
        body: jsonEncode({'error': 'Too Many Requests', 'message': 'Too many failed authentication attempts'}),
        headers: {'content-type': 'application/json'},
      );
    }

    final isBrowser = request.headers['accept']?.contains('text/html') ?? false;
    if (isBrowser) {
      return Response.found(_loginLocation(request));
    }
    return Response(
      401,
      body: jsonEncode({'error': 'Unauthorized', 'message': 'Valid token required'}),
      headers: {'content-type': 'application/json'},
    );
  };
}

String _failureReason(Request request) {
  final cookieHeader = request.headers['cookie'];
  if (cookieHeader != null && _parseCookie(cookieHeader, sessionCookieName) != null) {
    return 'invalid_session';
  }

  final authHeader = request.headers['authorization'];
  if (authHeader != null && authHeader.startsWith('Bearer ')) {
    return 'invalid_bearer';
  }

  if (request.method == 'GET' && request.url.queryParameters.containsKey('token')) {
    return 'invalid_query_token';
  }

  return 'missing_credentials';
}

String _locationWithoutToken(Request request) {
  final params = Map<String, String>.from(request.url.queryParameters);
  params.remove('token');

  final path = request.url.path.isEmpty ? '/' : '/${request.url.path}';
  if (params.isEmpty) return path;

  final query = Uri(queryParameters: params).query;
  return '$path?$query';
}

String _loginLocation(Request request) {
  final next = _locationWithoutToken(request);
  final query = Uri(queryParameters: {'next': next}).query;
  return '/login?$query';
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
