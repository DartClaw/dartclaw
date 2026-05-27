import 'package:shelf/shelf.dart';

/// SHA-256 hash of the inline theme-detection script in layout.dart.
/// Must be updated if that script changes.
const _themeScriptHash = 'sha256-Nv1JReIKyK52u/L2sOlX5XEwoodaiEphFAlIFGeX9A8=';

/// Content-Security-Policy: script hashes for static inline scripts,
/// explicit CDN allowlist, no unsafe-inline for scripts.
const _csp =
    "default-src 'none'; "
    "script-src 'self' '$_themeScriptHash' https://unpkg.com https://cdn.jsdelivr.net; "
    "style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; "
    'font-src https://fonts.gstatic.com; '
    "img-src 'self' data:; "
    "connect-src 'self'; "
    // Allow embedding same-origin iframes (e.g. the canvas-admin Live Canvas
    // preview). Without this, frame-src falls back to default-src 'none' and
    // the browser blocks the iframe entirely.
    "frame-src 'self'; "
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
    // A route that sets its own CSP owns its framing policy too (e.g. the
    // sandboxed canvas embed needs frame-ancestors 'self' + a script nonce to
    // render inside the admin iframe). Don't clobber it with the global CSP or
    // X-Frame-Options: DENY, which would block same-origin framing entirely.
    final routeOwnsCsp = hasHeader('content-security-policy');
    return response.change(
      headers: {
        if (!routeOwnsCsp) 'Content-Security-Policy': _csp,
        'Referrer-Policy': 'no-referrer',
        'X-Content-Type-Options': 'nosniff',
        if (!routeOwnsCsp) 'X-Frame-Options': 'DENY',
        if (!hasCacheControl) 'Cache-Control': 'no-store',
        'Vary': 'HX-Request',
        if (enableHsts) 'Strict-Transport-Security': 'max-age=31536000; includeSubDomains',
      },
    );
  };
}
