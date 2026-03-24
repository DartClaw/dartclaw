import 'dart:io';
import 'dart:math';

import 'package:googleapis_auth/auth_io.dart';
import 'package:http/http.dart' as http;

import 'user_oauth_credential_store.dart';

/// Creates authenticated HTTP clients using stored user OAuth credentials,
/// and runs the interactive OAuth consent flow for initial authorization.
class UserOAuthAuthService {
  static final _oauthAuthorizeUri = Uri.https('accounts.google.com', '/o/oauth2/v2/auth');

  /// Creates an auto-refreshing OAuth client from stored user credentials.
  ///
  /// The client will refresh the access token automatically on first use
  /// (since we construct it with an expired dummy token) and on subsequent
  /// expiry. The [credentials.refreshToken] is used for all refresh calls.
  static AutoRefreshingAuthClient createClient({required StoredUserCredentials credentials, http.Client? baseClient}) {
    final clientId = ClientId(credentials.clientId, credentials.clientSecret);

    // Construct AccessCredentials with an already-expired access token.
    // autoRefreshingClient will refresh immediately on first use.
    final expiredToken = AccessToken('Bearer', '', DateTime.utc(2000));
    final accessCredentials = AccessCredentials(expiredToken, credentials.refreshToken, credentials.scopes);

    return autoRefreshingClient(clientId, accessCredentials, baseClient ?? http.Client());
  }

  /// Runs the interactive OAuth consent flow via localhost redirect.
  ///
  /// 1. Starts a temporary HTTP server on localhost:[listenPort]
  /// 2. Opens the user's browser to the Google consent URL
  /// 3. Receives the authorization code via redirect
  /// 4. Exchanges it for access + refresh tokens
  ///
  /// Returns [AccessCredentials] containing the refresh token.
  ///
  /// [openBrowser] is called with the consent URL. Override for testing
  /// or headless environments. Defaults to `open` (macOS) / `xdg-open` (Linux).
  static Future<AccessCredentials> runConsentFlow({
    required String clientId,
    required String clientSecret,
    required List<String> scopes,
    int listenPort = 0,
    void Function(String uri)? openBrowser,
    http.Client? baseClient,
  }) async {
    final id = ClientId(clientId, clientSecret);
    final client = baseClient ?? http.Client();
    final server = await HttpServer.bind('localhost', listenPort);
    final redirectUri = 'http://localhost:${server.port}';
    final state = _randomState();
    final authUri = _oauthAuthorizeUri.replace(
      queryParameters: {
        'client_id': clientId,
        'response_type': 'code',
        'redirect_uri': redirectUri,
        'scope': scopes.join(' '),
        'access_type': 'offline',
        'prompt': 'consent',
        'state': state,
      },
    );

    try {
      (openBrowser ?? _defaultOpenBrowser)(authUri.toString());
      final request = await server.first;
      final uri = request.uri;

      if (request.method != 'GET') {
        request.response.statusCode = 400;
        await request.response.close();
        throw StateError('Invalid OAuth callback method: ${request.method}');
      }
      if (uri.queryParameters['state'] != state) {
        request.response.statusCode = 400;
        await request.response.close();
        throw StateError('Invalid OAuth callback state');
      }

      final error = uri.queryParameters['error'];
      if (error != null && error.isNotEmpty) {
        request.response.statusCode = 400;
        await request.response.close();
        throw StateError('OAuth consent failed: $error');
      }

      final code = uri.queryParameters['code'];
      if (code == null || code.isEmpty) {
        request.response.statusCode = 400;
        await request.response.close();
        throw StateError('OAuth callback did not include an authorization code');
      }

      final credentials = await obtainAccessCredentialsViaCodeExchange(client, id, code, redirectUrl: redirectUri);

      request.response
        ..statusCode = 200
        ..headers.contentType = ContentType.html
        ..write(
          '<!DOCTYPE html><html><body><h2>Authorization successful.</h2>'
          '<p>You can close this window.</p></body></html>',
        );
      await request.response.close();
      return credentials;
    } finally {
      await server.close(force: true);
      if (baseClient == null) client.close();
    }
  }

  static void _defaultOpenBrowser(String uri) {
    if (Platform.isMacOS) {
      Process.start('open', [uri]);
    } else if (Platform.isLinux) {
      Process.start('xdg-open', [uri]);
    } else if (Platform.isWindows) {
      Process.start('start', [uri], runInShell: true);
    }
  }

  static String _randomState() {
    const alphabet = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    final random = Random.secure();
    return List.generate(32, (_) => alphabet[random.nextInt(alphabet.length)]).join();
  }
}
