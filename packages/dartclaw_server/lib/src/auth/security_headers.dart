import 'package:shelf/shelf.dart';

/// SHA-256 hash of the inline theme-detection script in layout.dart.
/// Must be updated if that script changes.
const _themeScriptHash = 'sha256-Nv1JReIKyK52u/L2sOlX5XEwoodaiEphFAlIFGeX9A8=';

/// Content-Security-Policy: script hashes for static inline scripts,
/// explicit CDN allowlist, no unsafe-inline for scripts.
const _csp = "default-src 'none'; "
    "script-src 'self' '$_themeScriptHash' https://unpkg.com https://cdn.jsdelivr.net; "
    "style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; "
    'font-src https://fonts.gstatic.com; '
    "img-src 'self' data:; "
    "connect-src 'self'; "
    "base-uri 'self'; "
    "form-action 'self'; "
    "frame-ancestors 'none'";

/// Middleware that adds security headers to every response.
///
/// Applied as the outermost middleware so headers are present on ALL responses
/// including 401s and error pages.
Middleware securityHeadersMiddleware() {
  return (Handler inner) => (Request request) async {
    final response = await inner(request);
    return response.change(headers: {
      'Content-Security-Policy': _csp,
      'Referrer-Policy': 'no-referrer',
      'X-Content-Type-Options': 'nosniff',
      'X-Frame-Options': 'DENY',
      'Cache-Control': 'no-store',
      'Vary': 'HX-Request',
    });
  };
}
