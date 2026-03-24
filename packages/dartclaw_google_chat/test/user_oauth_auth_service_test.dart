import 'dart:async';
import 'dart:convert';

import 'package:dartclaw_google_chat/dartclaw_google_chat.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

final _tokenUri = Uri.https('oauth2.googleapis.com', 'token');

StoredUserCredentials sampleCredentials() => StoredUserCredentials(
  clientId: 'test-client-id.apps.googleusercontent.com',
  clientSecret: 'test-client-secret',
  refreshToken: 'test-refresh-token',
  scopes: ['https://www.googleapis.com/auth/chat.messages.readonly'],
  createdAt: DateTime.utc(2026, 3, 24),
);

void main() {
  group('UserOAuthAuthService.createClient', () {
    test('produces a client that refreshes immediately and injects Bearer token', () async {
      var tokenRequests = 0;
      final authHeaders = <String>[];

      final mockClient = MockClient((request) async {
        if (request.url == _tokenUri) {
          tokenRequests++;
          // Verify it's a refresh_token grant
          expect(request.bodyFields['grant_type'], 'refresh_token');
          expect(request.bodyFields['refresh_token'], 'test-refresh-token');
          expect(request.bodyFields['client_id'], contains('test-client-id'));
          expect(request.bodyFields['client_secret'], 'test-client-secret');
          return http.Response(
            jsonEncode({'access_token': 'refreshed-token-$tokenRequests', 'token_type': 'Bearer', 'expires_in': 3600}),
            200,
            headers: {'content-type': 'application/json'},
          );
        }

        authHeaders.add(request.headers['Authorization'] ?? '');
        return http.Response('{}', 200, headers: {'content-type': 'application/json'});
      });

      final client = UserOAuthAuthService.createClient(credentials: sampleCredentials(), baseClient: mockClient);
      addTearDown(client.close);

      // First request should trigger a refresh (dummy token is expired).
      final response = await client.get(Uri.parse('https://example.com/test'));
      expect(response.statusCode, 200);
      expect(tokenRequests, 1);
      expect(authHeaders, ['Bearer refreshed-token-1']);
    });

    test('uses correct scopes from stored credentials', () async {
      final mockClient = MockClient((request) async {
        if (request.url == _tokenUri) {
          return http.Response(
            jsonEncode({'access_token': 'test-token', 'token_type': 'Bearer', 'expires_in': 3600}),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response('{}', 200, headers: {'content-type': 'application/json'});
      });

      final client = UserOAuthAuthService.createClient(credentials: sampleCredentials(), baseClient: mockClient);
      addTearDown(client.close);

      // Verify credentials have the expected scopes after refresh.
      await client.get(Uri.parse('https://example.com/test'));
      expect(client.credentials.scopes, ['https://www.googleapis.com/auth/chat.messages.readonly']);
    });

    test('throws on refresh failure', () async {
      final mockClient = MockClient((request) async {
        if (request.url == _tokenUri) {
          return http.Response(
            jsonEncode({'error': 'invalid_grant', 'error_description': 'Token revoked'}),
            400,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response('{}', 200);
      });

      final client = UserOAuthAuthService.createClient(credentials: sampleCredentials(), baseClient: mockClient);
      addTearDown(client.close);

      expect(() => client.get(Uri.parse('https://example.com/test')), throwsA(anything));
    });
  });

  group('UserOAuthAuthService.runConsentFlow', () {
    test('requests offline access and exchanges the callback code', () async {
      late Uri launchedUri;
      final callbackDone = Completer<void>();

      final mockClient = MockClient((request) async {
        if (request.url == _tokenUri) {
          expect(request.bodyFields['code'], 'auth-code');
          expect(request.bodyFields['redirect_uri'], startsWith('http://localhost:'));
          return http.Response(
            jsonEncode({
              'access_token': 'fresh-access-token',
              'refresh_token': 'fresh-refresh-token',
              'token_type': 'Bearer',
              'expires_in': 3600,
              'scope': 'https://www.googleapis.com/auth/chat.messages.readonly',
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        throw StateError('Unexpected request: ${request.url}');
      });

      final credentialsFuture = UserOAuthAuthService.runConsentFlow(
        clientId: sampleCredentials().clientId,
        clientSecret: sampleCredentials().clientSecret,
        scopes: sampleCredentials().scopes,
        baseClient: mockClient,
        openBrowser: (uri) {
          launchedUri = Uri.parse(uri);
          Future<void>(() async {
            final redirectUri = Uri.parse(launchedUri.queryParameters['redirect_uri']!);
            final callbackUri = redirectUri.replace(
              queryParameters: {'code': 'auth-code', 'state': launchedUri.queryParameters['state']!},
            );
            final response = await http.get(callbackUri);
            expect(response.statusCode, 200);
            callbackDone.complete();
          });
        },
      );

      final credentials = await credentialsFuture;
      await callbackDone.future;

      expect(launchedUri.queryParameters['access_type'], 'offline');
      expect(launchedUri.queryParameters['prompt'], 'consent');
      expect(credentials.refreshToken, 'fresh-refresh-token');
    });
  });
}
