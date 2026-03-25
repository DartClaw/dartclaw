import 'dart:convert';

import 'package:dartclaw_google_chat/dartclaw_google_chat.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

final _googleTokenUri = Uri.https('oauth2.googleapis.com', 'token');
// Test-only RSA key — not associated with any real service account.
const _serviceAccountPrivateKey = '''
-----BEGIN PRIVATE KEY-----
MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQCoXGQ1+6x9fnBp
opuCXc9BgPOoCCLApC2EycYdI9WsHhrGP7JweXbVFoa75+sOOfRbDQH7/iDCLyzm
X5Pa4A9aQmyaEM5n5pUOzSNBb6DE6liItjmzVD/9/cHJQZzAJL57q+bEy10vHVVy
NchF9MkLPfRQ8IT+mH/5iCuhRFD7y2FDHlEJWWDJfM5txr5oM3XtPEAmWBZJgZ1a
3KAJwYzlJiIz/sKPUsakIoB/Gu5Qvd4lzJryIogkGVWGsGLAvdkR+B0Ou9Sl3IwM
Xg4agYzos70d371PjkjB5HQQu8zCiU+WVR77zVL7orh6SrDWa+Anz5gR7lKAvBpF
ROEFGnHZAgMBAAECggEACXdwdwyYrVG/tmDbR6BIuBEtIiSa96QDnzTNO/Q43n2u
2bjZKrPZt6+Vkdk/gURG9husIeQvKVwHtUhoguUYV+XmP190i6kOdo+YTOSe8JOQ
uNcuNWQmWPy8ublDvBYU09Vdm3En4y9OD6bwhOZ3q3cnVqm/gKVIhNpgQagauZ2l
lMETW9X3hnibeSNmJ1zbjbIERESOPWSV19c7FRUawbKQwurPyrJTFgum/f6hni9k
MfnytUzZx9W3eo13sQUO0B7QQmlubS1Jh/KhuNS0I2JsCCghsLK6oys5AL+sNeu2
NCiCppkjH66IelEJTnwiKrQcIlWgplzt4z8LDlUBgQKBgQDXMY7jbC6tfyQsWv9W
BKolFwM1D0IvdNwTuPxC8EWEy/cGUUCUPQ1zpWZmJYN7BvC3keh87CzJWDr1Cmha
DCQjWkJasvlB3pMcz3FKCPPHYSPYq189dec7Afk8y9w251cNHc0hHy5eE3iRWBuw
Cu+YOfcur5r2yhAqQPYBscMFqQKBgQDISV6DS4QVj6s83z2OrwzmOup5daXPWmPf
DUXvc+wrMeSsfY215KNDi/y1S2BRQqUttShcCyGlLvgPL5bdzuC4e+vrifrJVxyB
1v/2eOWVujyjLIiRk7xbojHs3iYIGDJ1nEJTX3MAPkNKS9SUCWxB5X1Yv+tcjEES
8s5mWcxIsQKBgDjEEfVcLFQIHfq1ZnXCdT+jem0cwVDTetqZCbJ+v1fwlhFMjcSM
9mdzUjfP3YcupYFHNBUAGDBk3eiV/kECwuWwgaB7ZdVCaXxIHJJzGhuWPGaDjnQg
Dgc61gx7mnPBQu1q1xnNp+WZLUzp+SPPPrThVZszJ6XCV9FNoZeA1PlBAoGBALVv
yZ+1BDWoDZ66OQCN0WirTIe1LPzXTIvecVFHOVW0AAzGPF7ffYsOQGJXoyxZ7Fqo
tqQTLWp/TxYqrUfIRki5cfHQ8A/+ywNQKlY0FP77VD0ZdaozJDn6h7GlWNySVvu2
D1uJpxs8TCb85NkqZBiZ9WA1k9gl8jlhHdsYU/gxAoGABOnBxb5gOW2cswiGC1SE
5uzZdOQAfmbUOPbM/6LIcqv30uoTQvp5ogMBKcl8loYbnmpt1/SYwRxBbsJJisPA
ziYQGAGUXYeBjycSuJriTb3YSZ8ZUnnCQ1SZ8YOWYxO1DSzIOQV0Q3L02cnHEMfs
/enQZOL5KRzXzPNF0PPnyQs=
-----END PRIVATE KEY-----
''';

void main() {
  group('GcpAuthService.resolveCredentialJson', () {
    test('inline JSON detected by leading brace', () {
      final json = GcpAuthService.resolveCredentialJson(
        configValue: ' {"type":"service_account","project_id":"demo"} ',
      );
      expect(json, '{"type":"service_account","project_id":"demo"}');
    });

    test('file path reads file asynchronously', () async {
      final json = await GcpAuthService.resolveCredentialJsonAsync(
        configValue: '/tmp/service-account.json',
        fileReader: (path) async => path == '/tmp/service-account.json' ? '{"type":"service_account"}' : null,
      );
      expect(json, '{"type":"service_account"}');
    });

    test('env var fallback', () async {
      final json = await GcpAuthService.resolveCredentialJsonAsync(
        env: {'GOOGLE_APPLICATION_CREDENTIALS': '/tmp/service-account.json'},
        fileReader: (path) async => path == '/tmp/service-account.json' ? '{"type":"service_account"}' : null,
      );
      expect(json, '{"type":"service_account"}');
    });

    test('missing configured file falls through to GOOGLE_APPLICATION_CREDENTIALS', () async {
      final json = await GcpAuthService.resolveCredentialJsonAsync(
        configValue: '/tmp/missing.json',
        env: {'GOOGLE_APPLICATION_CREDENTIALS': '/tmp/service-account.json'},
        fileReader: (path) async => path == '/tmp/service-account.json' ? '{"type":"service_account"}' : null,
      );
      expect(json, '{"type":"service_account"}');
    });

    test('returns null when nothing available', () async {
      final json = await GcpAuthService.resolveCredentialJsonAsync();
      expect(json, isNull);
    });

    test('returns null for missing file', () async {
      final json = await GcpAuthService.resolveCredentialJsonAsync(
        configValue: '/tmp/missing.json',
        fileReader: (_) async => null,
      );
      expect(json, isNull);
    });
  });

  group('GcpAuthService construction', () {
    test('throws on invalid JSON', () {
      expect(() => GcpAuthService(serviceAccountJson: 'not json', scopes: ['scope']), throwsA(isA<StateError>()));
    });

    test('throws on invalid credentials format', () {
      expect(
        () => GcpAuthService(serviceAccountJson: '{"type":"service_account","project_id":"demo"}', scopes: ['scope']),
        throwsA(isA<StateError>()),
      );
    });

    test('does not require token_uri in credentials JSON', () {
      expect(
        () => GcpAuthService(
          serviceAccountJson: jsonEncode({
            'type': 'service_account',
            'client_email': 'chat-bot@example.iam.gserviceaccount.com',
            'private_key': _serviceAccountPrivateKey,
          }),
          scopes: ['scope'],
        ),
        returnsNormally,
      );
    });
  });

  group('GcpAuthService.initialize', () {
    test('returns auth client after successful token acquisition', () async {
      var tokenRequests = 0;
      final authHeaders = <String>[];
      final service = GcpAuthService(
        serviceAccountJson: _serviceAccountJson(),
        scopes: const ['https://www.googleapis.com/auth/chat.bot'],
        httpClient: MockClient((request) async {
          if (request.url == _googleTokenUri) {
            tokenRequests++;
            expect(request.method, 'POST');
            expect(request.bodyFields['grant_type'], 'urn:ietf:params:oauth:grant-type:jwt-bearer');
            expect(request.bodyFields['assertion'], isNotEmpty);
            return http.Response(
              jsonEncode({'access_token': 'token-1', 'token_type': 'Bearer', 'expires_in': 3600}),
              200,
              headers: {'content-type': 'application/json'},
            );
          }

          authHeaders.add(request.headers['Authorization'] ?? '');
          return http.Response('{}', 200, headers: {'content-type': 'application/json'});
        }),
      );

      final client = await service.initialize();
      addTearDown(client.close);

      expect(client.credentials.accessToken.data, 'token-1');
      expect(tokenRequests, 1);

      final response = await client.get(Uri.parse('https://example.com/spaces'));
      expect(response.statusCode, 200);
      expect(authHeaders, ['Bearer token-1']);
    });

    test('expired token is reacquired automatically on send', () async {
      var tokenRequests = 0;
      final authHeaders = <String>[];
      final service = GcpAuthService(
        serviceAccountJson: _serviceAccountJson(),
        scopes: const ['https://www.googleapis.com/auth/chat.bot'],
        httpClient: MockClient((request) async {
          if (request.url == _googleTokenUri) {
            tokenRequests++;
            return http.Response(
              jsonEncode({
                'access_token': 'token-$tokenRequests',
                'token_type': 'Bearer',
                'expires_in': tokenRequests == 1 ? 1 : 3600,
              }),
              200,
              headers: {'content-type': 'application/json'},
            );
          }

          authHeaders.add(request.headers['Authorization'] ?? '');
          return http.Response('{}', 200, headers: {'content-type': 'application/json'});
        }),
      );

      final client = await service.initialize();
      addTearDown(client.close);

      final refreshedCredentials = client.credentialUpdates.first;
      final response = await client.get(Uri.parse('https://example.com/spaces'));

      expect(response.statusCode, 200);
      expect(tokenRequests, 2);
      expect((await refreshedCredentials).accessToken.data, 'token-2');
      expect(client.credentials.accessToken.data, 'token-2');
      expect(authHeaders, ['Bearer token-2']);
    });
  });
}

String _serviceAccountJson() {
  return jsonEncode({
    'type': 'service_account',
    'client_email': 'chat-bot@example.iam.gserviceaccount.com',
    'private_key': _serviceAccountPrivateKey,
    'token_uri': _googleTokenUri.toString(),
  });
}
