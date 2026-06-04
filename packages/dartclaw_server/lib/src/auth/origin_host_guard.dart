import 'package:shelf/shelf.dart';

import 'request_auth_context.dart';

const _safeMethods = {'GET', 'HEAD', 'OPTIONS'};

/// Application-level write boundary for cookie-authenticated browser sessions.
///
/// For unsafe HTTP methods (POST/PUT/PATCH/DELETE), when the request is
/// authenticated via a session cookie, this middleware verifies that the request
/// originates from the same scheme, host, and effective port:
///
/// - Checks the `Origin` authority first.
/// - Falls back to the `Referer` authority if `Origin` is absent.
/// - Rejects with 403 if neither is present or the authority does not match.
///
/// **Exempt requests (check is skipped):**
/// - Safe methods (GET/HEAD/OPTIONS), since CSRF is only relevant for state changes.
/// - Bearer-token-authenticated requests, since CSRF does not apply to API clients;
///   the exemption is automatic because the cookie auth context flag is absent.
/// - `localAdminMiddleware` sessions (no-auth mode), since there is no cookie context.
///
/// **Assumption:** modern browsers send `Origin` (or at minimum `Referer`) on
/// same-origin unsafe requests, including HTMX-driven form submissions and
/// `fetch()` calls from Stimulus controllers. The legitimate web UI therefore
/// passes without any special configuration.
Middleware originHostGuardMiddleware() {
  return (Handler inner) => (Request request) async {
    if (_safeMethods.contains(request.method)) {
      return inner(request);
    }

    if (!requestIsCookieAuthenticated(request)) {
      return inner(request);
    }

    final requestAuthority = _requestAuthority(request);
    if (requestAuthority == null) {
      return _forbidden('Missing Host header');
    }

    final origin = request.headers['origin'];
    if (origin != null) {
      final originAuthority = _authorityFromUri(Uri.tryParse(origin));
      if (originAuthority == null || originAuthority != requestAuthority) {
        return _forbidden('Origin authority does not match request authority');
      }
      return inner(request);
    }

    final referer = request.headers['referer'];
    if (referer != null) {
      final refererAuthority = _authorityFromUri(Uri.tryParse(referer));
      if (refererAuthority == null || refererAuthority != requestAuthority) {
        return _forbidden('Referer authority does not match request authority');
      }
      return inner(request);
    }

    return _forbidden('Cookie-authenticated request missing Origin and Referer');
  };
}

_EffectiveAuthority? _requestAuthority(Request request) {
  final host = request.headers['host'];
  if (host == null || host.trim().isEmpty) return null;
  final scheme = request.requestedUri.scheme.toLowerCase();
  if (scheme != 'http' && scheme != 'https') return null;
  return _authorityFromUri(Uri.tryParse('$scheme://${host.trim()}'));
}

_EffectiveAuthority? _authorityFromUri(Uri? uri) {
  if (uri == null || !uri.hasAuthority) return null;
  final scheme = uri.scheme.toLowerCase();
  final defaultPort = _defaultPort(scheme);
  if (defaultPort == null) return null;
  final host = uri.host.toLowerCase();
  if (host.isEmpty) return null;
  return _EffectiveAuthority(scheme: scheme, host: host, port: uri.hasPort ? uri.port : defaultPort);
}

int? _defaultPort(String scheme) {
  switch (scheme) {
    case 'http':
      return 80;
    case 'https':
      return 443;
    default:
      return null;
  }
}

final class _EffectiveAuthority {
  final String scheme;
  final String host;
  final int port;

  const _EffectiveAuthority({required this.scheme, required this.host, required this.port});

  @override
  bool operator ==(Object other) =>
      other is _EffectiveAuthority && other.scheme == scheme && other.host == host && other.port == port;

  @override
  int get hashCode => Object.hash(scheme, host, port);
}

Response _forbidden(String reason) =>
    Response.forbidden('{"error":"Forbidden","message":"$reason"}', headers: {'content-type': 'application/json'});
