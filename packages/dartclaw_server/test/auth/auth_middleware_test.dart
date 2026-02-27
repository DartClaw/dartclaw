import 'dart:convert';

import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

void main() {
  late TokenService tokenService;
  late SessionStore sessionStore;

  Handler makeOk() => (Request request) => Response.ok('ok');

  setUp(() {
    tokenService = TokenService(token: 'a' * 64);
    sessionStore = SessionStore();
  });

  group('authMiddleware', () {
    test('disabled middleware passes all through', () async {
      final mw = authMiddleware(
        tokenService: tokenService,
        sessionStore: sessionStore,
        enabled: false,
      );
      final handler = mw(makeOk());
      final response = await handler(Request('GET', Uri.parse('http://localhost/api/sessions')));
      expect(response.statusCode, 200);
    });

    group('public paths', () {
      test('/health passes through', () async {
        final mw = authMiddleware(tokenService: tokenService, sessionStore: sessionStore);
        final handler = mw(makeOk());
        final response = await handler(Request('GET', Uri.parse('http://localhost/health')));
        expect(response.statusCode, 200);
      });

      test('/login passes through', () async {
        final mw = authMiddleware(tokenService: tokenService, sessionStore: sessionStore);
        final handler = mw(makeOk());
        final response = await handler(Request('GET', Uri.parse('http://localhost/login')));
        expect(response.statusCode, 200);
      });

      test('/favicon.ico passes through', () async {
        final mw = authMiddleware(tokenService: tokenService, sessionStore: sessionStore);
        final handler = mw(makeOk());
        final response = await handler(Request('GET', Uri.parse('http://localhost/favicon.ico')));
        expect(response.statusCode, 200);
      });

      test('/static/ prefix passes through', () async {
        final mw = authMiddleware(tokenService: tokenService, sessionStore: sessionStore);
        final handler = mw(makeOk());
        final response = await handler(Request('GET', Uri.parse('http://localhost/static/app.js')));
        expect(response.statusCode, 200);
      });

      test('/webhook/ prefix passes through', () async {
        final mw = authMiddleware(tokenService: tokenService, sessionStore: sessionStore);
        final handler = mw(makeOk());
        final response = await handler(Request('GET', Uri.parse('http://localhost/webhook/whatsapp')));
        expect(response.statusCode, 200);
      });
    });

    test('valid session cookie passes through', () async {
      final sessionId = sessionStore.createSession();
      final mw = authMiddleware(tokenService: tokenService, sessionStore: sessionStore);
      final handler = mw(makeOk());
      final response = await handler(Request(
        'GET',
        Uri.parse('http://localhost/api/sessions'),
        headers: {'cookie': 'dart_session=$sessionId'},
      ));
      expect(response.statusCode, 200);
    });

    test('invalid session cookie does not pass', () async {
      final mw = authMiddleware(tokenService: tokenService, sessionStore: sessionStore);
      final handler = mw(makeOk());
      final response = await handler(Request(
        'GET',
        Uri.parse('http://localhost/api/sessions'),
        headers: {'cookie': 'dart_session=invalid'},
      ));
      expect(response.statusCode, isNot(200));
    });

    test('valid bearer token passes through', () async {
      final mw = authMiddleware(tokenService: tokenService, sessionStore: sessionStore);
      final handler = mw(makeOk());
      final response = await handler(Request(
        'GET',
        Uri.parse('http://localhost/api/sessions'),
        headers: {'authorization': 'Bearer ${'a' * 64}'},
      ));
      expect(response.statusCode, 200);
    });

    test('invalid bearer token returns 401 JSON for API client', () async {
      final mw = authMiddleware(tokenService: tokenService, sessionStore: sessionStore);
      final handler = mw(makeOk());
      final response = await handler(Request(
        'GET',
        Uri.parse('http://localhost/api/sessions'),
        headers: {'authorization': 'Bearer wrong'},
      ));
      expect(response.statusCode, 401);
      final body = jsonDecode(await response.readAsString()) as Map<String, dynamic>;
      expect(body['error'], 'Unauthorized');
    });

    test('token bootstrap sets cookie and redirects', () async {
      final mw = authMiddleware(tokenService: tokenService, sessionStore: sessionStore);
      final handler = mw(makeOk());
      final response = await handler(Request(
        'GET',
        Uri.parse('http://localhost/?token=${'a' * 64}'),
      ));
      expect(response.statusCode, 302);
      expect(response.headers['location'], '/');
      expect(response.headers['set-cookie'], contains('dart_session='));
      expect(response.headers['set-cookie'], contains('HttpOnly'));
      expect(response.headers['set-cookie'], contains('SameSite=Strict'));
    });

    test('invalid token bootstrap does not set cookie', () async {
      final mw = authMiddleware(tokenService: tokenService, sessionStore: sessionStore);
      final handler = mw(makeOk());
      final response = await handler(Request(
        'GET',
        Uri.parse('http://localhost/?token=wrong'),
        headers: {'accept': 'text/html'},
      ));
      // Should redirect to /login for browser
      expect(response.statusCode, 302);
      expect(response.headers['location'], '/login');
    });

    test('browser without auth redirects to /login', () async {
      final mw = authMiddleware(tokenService: tokenService, sessionStore: sessionStore);
      final handler = mw(makeOk());
      final response = await handler(Request(
        'GET',
        Uri.parse('http://localhost/'),
        headers: {'accept': 'text/html,application/xhtml+xml'},
      ));
      expect(response.statusCode, 302);
      expect(response.headers['location'], '/login');
    });

    test('API client without auth gets 401', () async {
      final mw = authMiddleware(tokenService: tokenService, sessionStore: sessionStore);
      final handler = mw(makeOk());
      final response = await handler(Request(
        'GET',
        Uri.parse('http://localhost/api/sessions'),
        headers: {'accept': 'application/json'},
      ));
      expect(response.statusCode, 401);
    });
  });
}
