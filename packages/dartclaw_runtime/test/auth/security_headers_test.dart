import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import 'package:dartclaw_runtime/src/auth/security_headers.dart';

void main() {
  Handler buildHandler({bool enableHsts = false}) =>
      securityHeadersMiddleware(enableHsts: enableHsts)((_) => Response.ok('ok'));

  test('sets Content-Security-Policy header', () async {
    final response = await buildHandler()(Request('GET', Uri.parse('http://localhost/')));
    final csp = response.headers['content-security-policy']!;

    // Pinned in full: every runtime dependency is vendored, so any added source
    // is a regression. A substring check would miss a scheme-less host source
    // like `font-src 'self' fonts.gstatic.com`, which is valid CSP.
    expect(
      csp,
      "default-src 'none'; "
      "script-src 'self' 'sha256-Nv1JReIKyK52u/L2sOlX5XEwoodaiEphFAlIFGeX9A8='; "
      "style-src 'self' 'unsafe-inline'; "
      "font-src 'self'; "
      "img-src 'self' data:; "
      "connect-src 'self'; "
      "base-uri 'self'; "
      "form-action 'self'; "
      "frame-ancestors 'none'",
    );
    expect(csp, contains("default-src 'none'"));
    expect(csp, contains("script-src 'self'"));
    expect(csp, contains("style-src 'self' 'unsafe-inline'"));
    expect(csp, contains("font-src 'self'"));
    expect(csp, isNot(contains('https://')));
    expect(csp, contains("frame-ancestors 'none'"));
    // No frame-src: it inherits default-src 'none', so the app embeds no frames.
    expect(csp, isNot(contains('frame-src')));
    // Inline theme script allowed via hash, not unsafe-inline
    expect(csp, contains('sha256-'));
    expect(csp, isNot(contains("script-src 'unsafe-inline'")));
  });

  test('sets X-Frame-Options DENY', () async {
    final response = await buildHandler()(Request('GET', Uri.parse('http://localhost/')));
    expect(response.headers['x-frame-options'], 'DENY');
  });

  test('sets X-Content-Type-Options nosniff', () async {
    final response = await buildHandler()(Request('GET', Uri.parse('http://localhost/')));
    expect(response.headers['x-content-type-options'], 'nosniff');
  });

  test('sets Referrer-Policy no-referrer', () async {
    final response = await buildHandler()(Request('GET', Uri.parse('http://localhost/')));
    expect(response.headers['referrer-policy'], 'no-referrer');
  });

  test('sets Cache-Control no-store', () async {
    final response = await buildHandler()(Request('GET', Uri.parse('http://localhost/')));
    expect(response.headers['cache-control'], 'no-store');
  });

  test('sets HSTS header when enableHsts is true, absent otherwise', () async {
    final responseOn = await buildHandler(enableHsts: true)(Request('GET', Uri.parse('http://localhost/')));
    expect(responseOn.headers['strict-transport-security'], 'max-age=31536000; includeSubDomains');

    final responseOff = await buildHandler(enableHsts: false)(Request('GET', Uri.parse('http://localhost/')));
    expect(responseOff.headers['strict-transport-security'], isNull);
  });

  test('applies the global CSP and X-Frame-Options unconditionally', () async {
    // Every response gets the global CSP + DENY; no route opts out of framing policy.
    final response = await securityHeadersMiddleware()(
      (_) => Response.ok('ok', headers: {'Content-Security-Policy': "script-src 'nonce-abc'"}),
    )(Request('GET', Uri.parse('http://localhost/embed')));
    expect(response.headers['content-security-policy'], contains("frame-ancestors 'none'"));
    expect(response.headers['x-frame-options'], 'DENY');
  });
}
