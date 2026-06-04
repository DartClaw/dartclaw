import 'package:dartclaw_server/src/auth/origin_host_guard.dart';
import 'package:dartclaw_server/src/auth/request_auth_context.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

void main() {
  Handler makeGuarded({bool cookieAuth = false}) {
    final guard = originHostGuardMiddleware();
    return guard((Request request) => Response.ok('ok'));
  }

  Request cookieRequest(String method, String url, {Map<String, String> headers = const {}}) {
    final base = Request(method, Uri.parse(url), headers: headers);
    return withCookieAuthContext(base);
  }

  Request bearerRequest(String method, String url, {Map<String, String> headers = const {}}) {
    // Bearer auth: admin context present but no cookie-auth flag.
    final base = Request(method, Uri.parse(url), headers: headers);
    return withAdminAuthContext(base);
  }

  group('safe methods', () {
    test('GET with foreign Origin is allowed', () async {
      final handler = makeGuarded();
      final response = await handler(
        cookieRequest('GET', 'http://localhost/api/config', headers: {'origin': 'http://evil.example.com'}),
      );
      expect(response.statusCode, 200);
    });

    test('HEAD with no Origin is allowed', () async {
      final handler = makeGuarded();
      final response = await handler(cookieRequest('HEAD', 'http://localhost/api/config'));
      expect(response.statusCode, 200);
    });

    test('OPTIONS is always allowed', () async {
      final handler = makeGuarded();
      final response = await handler(cookieRequest('OPTIONS', 'http://localhost/api/config'));
      expect(response.statusCode, 200);
    });
  });

  group('bearer-auth POST', () {
    test('foreign Origin is allowed (bearer exempt)', () async {
      final handler = makeGuarded();
      final response = await handler(
        bearerRequest(
          'POST',
          'http://localhost/api/config/guards',
          headers: {'host': 'localhost', 'origin': 'http://evil.example.com'},
        ),
      );
      expect(response.statusCode, 200);
    });

    test('absent Origin and Referer is allowed (bearer exempt)', () async {
      final handler = makeGuarded();
      final response = await handler(
        bearerRequest('POST', 'http://localhost/api/config/guards', headers: {'host': 'localhost'}),
      );
      expect(response.statusCode, 200);
    });
  });

  group('cookie-auth POST — Origin checks', () {
    test('matching Origin host is allowed', () async {
      final handler = makeGuarded();
      final response = await handler(
        cookieRequest(
          'POST',
          'http://localhost/api/config/guards',
          headers: {'host': 'localhost', 'origin': 'http://localhost'},
        ),
      );
      expect(response.statusCode, 200);
    });

    test('matching Origin host with port is allowed', () async {
      final handler = makeGuarded();
      final response = await handler(
        cookieRequest(
          'POST',
          'http://localhost:3000/api/config',
          headers: {'host': 'localhost:3000', 'origin': 'http://localhost:3000'},
        ),
      );
      expect(response.statusCode, 200);
    });

    test('rejects same hostname with different explicit Origin port', () async {
      final handler = makeGuarded();
      final response = await handler(
        cookieRequest(
          'POST',
          'http://localhost:8080/api/config',
          headers: {'host': 'localhost:8080', 'origin': 'http://localhost:5173'},
        ),
      );
      expect(response.statusCode, 403);
    });

    test('accepts HTTP and HTTPS default-port equivalents', () async {
      final handler = makeGuarded();
      final httpResponse = await handler(
        cookieRequest(
          'POST',
          'http://localhost/api/config',
          headers: {'host': 'localhost', 'origin': 'http://localhost:80'},
        ),
      );
      final httpsResponse = await handler(
        cookieRequest(
          'POST',
          'https://localhost/api/config',
          headers: {'host': 'localhost', 'origin': 'https://localhost:443'},
        ),
      );

      expect(httpResponse.statusCode, 200);
      expect(httpsResponse.statusCode, 200);
    });

    test('rejects same hostname with different scheme', () async {
      final handler = makeGuarded();
      final response = await handler(
        cookieRequest(
          'POST',
          'http://localhost/api/config',
          headers: {'host': 'localhost', 'origin': 'https://localhost:443'},
        ),
      );
      expect(response.statusCode, 403);
    });

    test('foreign Origin host is rejected with 403', () async {
      final handler = makeGuarded();
      final response = await handler(
        cookieRequest(
          'POST',
          'http://localhost/api/config/guards',
          headers: {'host': 'localhost', 'origin': 'http://evil.example.com'},
        ),
      );
      expect(response.statusCode, 403);
    });

    test('null-Origin (privacy-sensitive navigation) is rejected with 403', () async {
      final handler = makeGuarded();
      // origin: null is the literal string "null" sent by browsers in some contexts.
      final response = await handler(
        cookieRequest('POST', 'http://localhost/api/config', headers: {'host': 'localhost', 'origin': 'null'}),
      );
      expect(response.statusCode, 403);
    });
  });

  group('cookie-auth POST — Referer fallback', () {
    test('matching Referer host is allowed when Origin absent', () async {
      final handler = makeGuarded();
      final response = await handler(
        cookieRequest(
          'POST',
          'http://localhost/api/config/guards',
          headers: {'host': 'localhost', 'referer': 'http://localhost/settings'},
        ),
      );
      expect(response.statusCode, 200);
    });

    test('foreign Referer host is rejected with 403', () async {
      final handler = makeGuarded();
      final response = await handler(
        cookieRequest(
          'POST',
          'http://localhost/api/config/guards',
          headers: {'host': 'localhost', 'referer': 'http://evil.example.com/forge'},
        ),
      );
      expect(response.statusCode, 403);
    });
  });

  group('cookie-auth POST — missing both headers', () {
    test('absent Origin and Referer is rejected with 403 (strict)', () async {
      final handler = makeGuarded();
      final response = await handler(
        cookieRequest('POST', 'http://localhost/api/config/guards', headers: {'host': 'localhost'}),
      );
      expect(response.statusCode, 403);
    });
  });

  group('cookie-auth other unsafe methods', () {
    for (final method in ['PUT', 'PATCH', 'DELETE']) {
      test('$method with matching Origin is allowed', () async {
        final handler = makeGuarded();
        final response = await handler(
          cookieRequest(
            method,
            'http://localhost/api/config/guards/1',
            headers: {'host': 'localhost', 'origin': 'http://localhost'},
          ),
        );
        expect(response.statusCode, 200);
      });

      test('$method with foreign Origin is rejected', () async {
        final handler = makeGuarded();
        final response = await handler(
          cookieRequest(
            method,
            'http://localhost/api/config/guards/1',
            headers: {'host': 'localhost', 'origin': 'http://evil.example.com'},
          ),
        );
        expect(response.statusCode, 403);
      });
    }
  });

  group('no-auth mode (localAdminMiddleware path)', () {
    test('POST without cookie context is allowed (no-auth mode)', () async {
      // In no-auth mode, localAdminMiddleware sets admin context but NOT the
      // cookie flag — so the origin guard skips the check.
      final handler = originHostGuardMiddleware()((Request req) => Response.ok('ok'));
      final request = withAdminAuthContext(
        Request('POST', Uri.parse('http://localhost/api/config'), headers: {'host': 'localhost'}),
      );
      final response = await handler(request);
      expect(response.statusCode, 200);
    });
  });
}
