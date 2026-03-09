import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import 'package:dartclaw_server/src/auth/security_headers.dart';

void main() {
  Handler buildHandler({bool enableHsts = false}) =>
      securityHeadersMiddleware(enableHsts: enableHsts)((_) => Response.ok('ok'));

  test('sets Content-Security-Policy header', () async {
    final response = await buildHandler()(Request('GET', Uri.parse('http://localhost/')));
    final csp = response.headers['content-security-policy']!;

    expect(csp, contains("default-src 'none'"));
    expect(csp, contains("script-src 'self'"));
    expect(csp, contains('https://unpkg.com'));
    expect(csp, contains('https://cdn.jsdelivr.net'));
    expect(csp, contains('https://fonts.googleapis.com'));
    expect(csp, contains('https://fonts.gstatic.com'));
    expect(csp, contains("frame-ancestors 'none'"));
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

  test('does not set HSTS header by default', () async {
    final response = await buildHandler()(Request('GET', Uri.parse('http://localhost/')));
    expect(response.headers['strict-transport-security'], isNull);
  });

  test('sets HSTS header when enableHsts is true', () async {
    final response = await buildHandler(enableHsts: true)(Request('GET', Uri.parse('http://localhost/')));
    expect(response.headers['strict-transport-security'], 'max-age=31536000; includeSubDomains');
  });

  test('does not set HSTS header when enableHsts is false', () async {
    final response = await buildHandler(enableHsts: false)(Request('GET', Uri.parse('http://localhost/')));
    expect(response.headers['strict-transport-security'], isNull);
  });
}
