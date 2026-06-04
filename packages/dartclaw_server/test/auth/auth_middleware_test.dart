import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide GoogleJwtVerifier, HarnessPool, TurnManager, TurnRunner;
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:dartclaw_server/src/auth/request_auth_context.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

void main() {
  final gatewayToken = 'a' * 64;
  late TokenService tokenService;

  Handler makeOk() =>
      (Request request) => Response.ok('ok');

  setUp(() {
    tokenService = TokenService(token: gatewayToken);
  });

  group('authMiddleware', () {
    test('admin context defaults closed when absent', () {
      final request = Request('GET', Uri.parse('http://localhost/api/config/guards'));

      expect(requestHasAdminAccess(request), isFalse);
      expect(requestHasAdminAccess(withAdminAuthContext(request)), isTrue);
    });

    test('disabled middleware passes all through', () async {
      final mw = authMiddleware(tokenService: tokenService, gatewayToken: gatewayToken, enabled: false);
      final handler = mw(makeOk());
      final response = await handler(Request('GET', Uri.parse('http://localhost/api/sessions')));
      expect(response.statusCode, 200);
    });

    test('localAdminMiddleware grants admin context to every request', () async {
      final handler = localAdminMiddleware()(
        (Request request) => Response.ok(requestHasAdminAccess(request) ? 'admin' : 'read-only'),
      );
      final response = await handler(Request('GET', Uri.parse('http://localhost/api/config/guards')));

      expect(response.statusCode, 200);
      expect(await response.readAsString(), 'admin');
    });

    group('public paths', () {
      test('/health passes through', () async {
        final mw = authMiddleware(tokenService: tokenService, gatewayToken: gatewayToken);
        final handler = mw(makeOk());
        final response = await handler(Request('GET', Uri.parse('http://localhost/health')));
        expect(response.statusCode, 200);
      });

      test('/login passes through', () async {
        final mw = authMiddleware(tokenService: tokenService, gatewayToken: gatewayToken);
        final handler = mw(makeOk());
        final response = await handler(Request('GET', Uri.parse('http://localhost/login')));
        expect(response.statusCode, 200);
      });

      test('/favicon.ico passes through', () async {
        final mw = authMiddleware(tokenService: tokenService, gatewayToken: gatewayToken);
        final handler = mw(makeOk());
        final response = await handler(Request('GET', Uri.parse('http://localhost/favicon.ico')));
        expect(response.statusCode, 200);
      });

      test('/static/ prefix passes through', () async {
        final mw = authMiddleware(tokenService: tokenService, gatewayToken: gatewayToken);
        final handler = mw(makeOk());
        final response = await handler(Request('GET', Uri.parse('http://localhost/static/controllers/index.js')));
        expect(response.statusCode, 200);
      });

      test('/webhook/ prefix passes through', () async {
        final mw = authMiddleware(tokenService: tokenService, gatewayToken: gatewayToken);
        final handler = mw(makeOk());
        final response = await handler(Request('GET', Uri.parse('http://localhost/webhook/whatsapp')));
        expect(response.statusCode, 200);
      });

      test('custom public path passes through', () async {
        final mw = authMiddleware(
          tokenService: tokenService,
          gatewayToken: gatewayToken,
          publicPaths: const ['/integrations/googlechat'],
        );
        final handler = mw(makeOk());
        final response = await handler(Request('GET', Uri.parse('http://localhost/integrations/googlechat')));
        expect(response.statusCode, 200);
      });
    });

    test('valid session cookie passes through', () async {
      final sessionToken = createSessionToken(gatewayToken);
      final mw = authMiddleware(tokenService: tokenService, gatewayToken: gatewayToken);
      final handler = mw(makeOk());
      final response = await handler(
        Request('GET', Uri.parse('http://localhost/api/sessions'), headers: {'cookie': 'dart_session=$sessionToken'}),
      );
      expect(response.statusCode, 200);
    });

    test('invalid session cookie does not pass', () async {
      final mw = authMiddleware(tokenService: tokenService, gatewayToken: gatewayToken);
      final handler = mw(makeOk());
      final response = await handler(
        Request('GET', Uri.parse('http://localhost/api/sessions'), headers: {'cookie': 'dart_session=invalid'}),
      );
      expect(response.statusCode, isNot(200));
    });

    test('session cookie signed with wrong key does not pass', () async {
      final sessionToken = createSessionToken('b' * 64);
      final mw = authMiddleware(tokenService: tokenService, gatewayToken: gatewayToken);
      final handler = mw(makeOk());
      final response = await handler(
        Request('GET', Uri.parse('http://localhost/api/sessions'), headers: {'cookie': 'dart_session=$sessionToken'}),
      );
      expect(response.statusCode, isNot(200));
    });

    test('valid bearer token passes through', () async {
      final mw = authMiddleware(tokenService: tokenService, gatewayToken: gatewayToken);
      final handler = mw(makeOk());
      final response = await handler(
        Request('GET', Uri.parse('http://localhost/api/sessions'), headers: {'authorization': 'Bearer $gatewayToken'}),
      );
      expect(response.statusCode, 200);
    });

    test('authenticated requests ignore client-supplied read-only downgrade header', () async {
      final mw = authMiddleware(tokenService: tokenService, gatewayToken: gatewayToken);
      final handler = mw((Request request) => Response.ok(requestHasAdminAccess(request) ? 'admin' : 'read-only'));
      final response = await handler(
        Request(
          'GET',
          Uri.parse('http://localhost/api/config/guards'),
          headers: {'authorization': 'Bearer $gatewayToken', 'x-dartclaw-read-only': 'true'},
        ),
      );

      expect(response.statusCode, 200);
      expect(await response.readAsString(), 'admin');
    });

    test('invalid bearer token returns 401 JSON for API client', () async {
      final mw = authMiddleware(tokenService: tokenService, gatewayToken: gatewayToken);
      final handler = mw(makeOk());
      final response = await handler(
        Request('GET', Uri.parse('http://localhost/api/sessions'), headers: {'authorization': 'Bearer wrong'}),
      );
      expect(response.statusCode, 401);
      final body = jsonDecode(await response.readAsString()) as Map<String, dynamic>;
      expect(body['error'], 'Unauthorized');
    });

    test('query token bootstrap is rejected without setting a cookie', () async {
      final mw = authMiddleware(tokenService: tokenService, gatewayToken: gatewayToken);
      final handler = mw(makeOk());
      final response = await handler(
        Request('GET', Uri.parse('http://localhost/?token=$gatewayToken'), headers: {'accept': 'application/json'}),
      );
      expect(response.statusCode, 401);
      expect(response.headers['set-cookie'], isNull);
    });

    test('query token browser requests redirect to login without leaking the token', () async {
      final mw = authMiddleware(tokenService: tokenService, gatewayToken: gatewayToken);
      final handler = mw(makeOk());
      final response = await handler(
        Request('GET', Uri.parse('http://localhost/settings?token=$gatewayToken'), headers: {'accept': 'text/html'}),
      );
      expect(response.statusCode, 302);
      expect(response.headers['location'], '/login?next=%2Fsettings');
      expect(response.headers['set-cookie'], isNull);
    });

    test('invalid token bootstrap does not set cookie', () async {
      final mw = authMiddleware(tokenService: tokenService, gatewayToken: gatewayToken);
      final handler = mw(makeOk());
      final response = await handler(
        Request('GET', Uri.parse('http://localhost/?token=wrong'), headers: {'accept': 'text/html'}),
      );
      // Should redirect to /login for browser
      expect(response.statusCode, 302);
      expect(response.headers['location'], '/login?next=%2F');
    });

    test('browser without auth redirects to /login', () async {
      final mw = authMiddleware(tokenService: tokenService, gatewayToken: gatewayToken);
      final handler = mw(makeOk());
      final response = await handler(
        Request('GET', Uri.parse('http://localhost/'), headers: {'accept': 'text/html,application/xhtml+xml'}),
      );
      expect(response.statusCode, 302);
      expect(response.headers['location'], '/login?next=%2F');
    });

    test('browser deep link without auth redirects to login with next path', () async {
      final mw = authMiddleware(tokenService: tokenService, gatewayToken: gatewayToken);
      final handler = mw(makeOk());
      final response = await handler(
        Request(
          'GET',
          Uri.parse('http://localhost/tasks/draft-1?status=review'),
          headers: {'accept': 'text/html,application/xhtml+xml'},
        ),
      );

      expect(response.statusCode, 302);
      expect(response.headers['location'], '/login?next=%2Ftasks%2Fdraft-1%3Fstatus%3Dreview');
    });

    test('API client without auth gets 401', () async {
      final mw = authMiddleware(tokenService: tokenService, gatewayToken: gatewayToken);
      final handler = mw(makeOk());
      final response = await handler(
        Request('GET', Uri.parse('http://localhost/api/sessions'), headers: {'accept': 'application/json'}),
      );
      expect(response.statusCode, 401);
    });

    test('fires FailedAuthEvent on gateway failure', () async {
      final eventBus = EventBus();
      addTearDown(eventBus.dispose);
      final events = <FailedAuthEvent>[];
      final sub = eventBus.on<FailedAuthEvent>().listen(events.add);
      addTearDown(sub.cancel);

      final mw = authMiddleware(tokenService: tokenService, gatewayToken: gatewayToken, eventBus: eventBus);
      final handler = mw(makeOk());
      final response = await handler(
        Request('GET', Uri.parse('http://localhost/api/sessions'), headers: {'authorization': 'Bearer wrong'}),
      );

      expect(response.statusCode, 401);
      await Future<void>.delayed(Duration.zero);
      expect(events, hasLength(1));
      expect(events.single.source, 'gateway');
      expect(events.single.reason, 'invalid_bearer');
      expect(events.single.limited, isFalse);
    });

    test('FailedAuthEvent uses trusted forwarded client identity', () async {
      final eventBus = EventBus();
      addTearDown(eventBus.dispose);
      final events = <FailedAuthEvent>[];
      final sub = eventBus.on<FailedAuthEvent>().listen(events.add);
      addTearDown(sub.cancel);

      final mw = authMiddleware(
        tokenService: tokenService,
        gatewayToken: gatewayToken,
        eventBus: eventBus,
        trustedProxies: const ['192.168.1.100'],
      );
      final handler = mw(makeOk());
      final response = await handler(
        _request(
          headers: {'authorization': 'Bearer wrong', 'x-forwarded-for': '10.0.0.1'},
          socketAddress: '192.168.1.100',
        ),
      );

      expect(response.statusCode, 401);
      await Future<void>.delayed(Duration.zero);
      expect(events.single.remoteKey, '10.0.0.1');
    });

    test('returns 429 after five prior failures in the same window', () async {
      final eventBus = EventBus();
      addTearDown(eventBus.dispose);
      final limiter = AuthRateLimiter();
      final events = <FailedAuthEvent>[];
      final sub = eventBus.on<FailedAuthEvent>().listen(events.add);
      addTearDown(sub.cancel);

      final mw = authMiddleware(
        tokenService: tokenService,
        gatewayToken: gatewayToken,
        eventBus: eventBus,
        rateLimiter: limiter,
      );
      final handler = mw(makeOk());

      for (var i = 0; i < 5; i++) {
        final response = await handler(
          Request('GET', Uri.parse('http://localhost/api/sessions'), headers: {'authorization': 'Bearer wrong'}),
        );
        expect(response.statusCode, 401);
      }

      final limited = await handler(
        Request('GET', Uri.parse('http://localhost/api/sessions'), headers: {'authorization': 'Bearer wrong'}),
      );

      expect(limited.statusCode, 429);
      await Future<void>.delayed(Duration.zero);
      expect(events, hasLength(6));
      expect(events.last.limited, isTrue);
    });

    test('rate limiter ignores X-Forwarded-For without trusted proxies', () async {
      final limiter = AuthRateLimiter();
      final mw = authMiddleware(tokenService: tokenService, gatewayToken: gatewayToken, rateLimiter: limiter);
      final handler = mw(makeOk());

      for (var i = 0; i < 5; i++) {
        final response = await handler(
          _request(
            headers: {'authorization': 'Bearer wrong', 'x-forwarded-for': '10.0.0.${i + 1}'},
            socketAddress: '192.168.1.50',
          ),
        );
        expect(response.statusCode, 401);
      }

      final limited = await handler(
        _request(
          headers: {'authorization': 'Bearer wrong', 'x-forwarded-for': '10.0.0.99'},
          socketAddress: '192.168.1.50',
        ),
      );
      expect(limited.statusCode, 429);
    });

    test('rate limiter keys on forwarded client when socket is trusted proxy', () async {
      final limiter = AuthRateLimiter();
      final mw = authMiddleware(
        tokenService: tokenService,
        gatewayToken: gatewayToken,
        rateLimiter: limiter,
        trustedProxies: const ['192.168.1.100'],
      );
      final handler = mw(makeOk());

      for (var i = 0; i < 5; i++) {
        final response = await handler(
          _request(
            headers: {'authorization': 'Bearer wrong', 'x-forwarded-for': '10.0.0.1'},
            socketAddress: '192.168.1.100',
          ),
        );
        expect(response.statusCode, 401);
      }

      final limited = await handler(
        _request(
          headers: {'authorization': 'Bearer wrong', 'x-forwarded-for': '10.0.0.1'},
          socketAddress: '192.168.1.100',
        ),
      );
      expect(limited.statusCode, 429);

      final differentClient = await handler(
        _request(
          headers: {'authorization': 'Bearer wrong', 'x-forwarded-for': '10.0.0.2'},
          socketAddress: '192.168.1.100',
        ),
      );
      expect(differentClient.statusCode, 401);
    });

    test('rate limiter ignores forwarded client when socket is not trusted', () async {
      final limiter = AuthRateLimiter();
      final mw = authMiddleware(
        tokenService: tokenService,
        gatewayToken: gatewayToken,
        rateLimiter: limiter,
        trustedProxies: const ['192.168.1.100'],
      );
      final handler = mw(makeOk());

      for (var i = 0; i < 5; i++) {
        final response = await handler(
          _request(
            headers: {'authorization': 'Bearer wrong', 'x-forwarded-for': '10.0.0.${i + 1}'},
            socketAddress: '192.168.1.50',
          ),
        );
        expect(response.statusCode, 401);
      }

      final limited = await handler(
        _request(
          headers: {'authorization': 'Bearer wrong', 'x-forwarded-for': '10.0.0.99'},
          socketAddress: '192.168.1.50',
        ),
      );
      expect(limited.statusCode, 429);
    });

    test('successful auth resets failure counter', () async {
      final limiter = AuthRateLimiter();
      final mw = authMiddleware(tokenService: tokenService, gatewayToken: gatewayToken, rateLimiter: limiter);
      final handler = mw(makeOk());

      for (var i = 0; i < 5; i++) {
        final response = await handler(
          Request('GET', Uri.parse('http://localhost/api/sessions'), headers: {'authorization': 'Bearer wrong'}),
        );
        expect(response.statusCode, 401);
      }

      final success = await handler(
        Request('GET', Uri.parse('http://localhost/api/sessions'), headers: {'authorization': 'Bearer $gatewayToken'}),
      );
      expect(success.statusCode, 200);

      for (var i = 0; i < 5; i++) {
        final response = await handler(
          Request('GET', Uri.parse('http://localhost/api/sessions'), headers: {'authorization': 'Bearer wrong'}),
        );
        expect(response.statusCode, 401);
      }

      final limited = await handler(
        Request('GET', Uri.parse('http://localhost/api/sessions'), headers: {'authorization': 'Bearer wrong'}),
      );
      expect(limited.statusCode, 429);
    });
  });
}

Request _request({Map<String, String> headers = const {}, required String socketAddress}) {
  return Request(
    'GET',
    Uri.parse('http://localhost/api/sessions'),
    headers: headers,
    context: {'shelf.io.connection_info': _FakeConnectionInfo(socketAddress)},
  );
}

class _FakeConnectionInfo implements HttpConnectionInfo {
  @override
  final InternetAddress remoteAddress;

  @override
  final int remotePort = 443;

  @override
  final int localPort = 3000;

  _FakeConnectionInfo(String address) : remoteAddress = InternetAddress.tryParse(address)!;
}
