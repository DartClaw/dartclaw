import 'package:shelf/shelf.dart';

/// SHA-256 hash of the inline theme-detection script in layout.dart.
/// Must be updated if that script changes.
const _themeScriptHash = 'sha256-Nv1JReIKyK52u/L2sOlX5XEwoodaiEphFAlIFGeX9A8=';

/// Content-Security-Policy: same-origin sources only, plus a script hash for
/// the static inline theme script. No external origin and no unsafe-inline for
/// scripts; every runtime dependency is vendored under `lib/src/static/`.
const _csp =
    "default-src 'none'; "
    "script-src 'self' '$_themeScriptHash'; "
    "style-src 'self' 'unsafe-inline'; "
    "font-src 'self'; "
    "img-src 'self' data:; "
    "connect-src 'self'; "
    "base-uri 'self'; "
    "form-action 'self'; "
    "frame-ancestors 'none'";

/// Middleware that adds security headers to every response.
///
/// Applied as the outermost middleware so headers are present on ALL responses
/// including 401s and error pages.
Middleware securityHeadersMiddleware({bool enableHsts = false}) {
  return (Handler inner) => (Request request) async {
    final response = await inner(request);
    bool hasHeader(String name) => response.headers.keys.any((key) => key.toLowerCase() == name);
    final hasCacheControl = hasHeader('cache-control');
    return response.change(
      headers: {
        'Content-Security-Policy': _csp,
        'Referrer-Policy': 'no-referrer',
        'X-Content-Type-Options': 'nosniff',
        'X-Frame-Options': 'DENY',
        if (!hasCacheControl) 'Cache-Control': 'no-store',
        'Vary': 'HX-Request',
        if (enableHsts) 'Strict-Transport-Security': 'max-age=31536000; includeSubDomains',
      },
    );
  };
}
