import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Constructs the [HttpClient] used by [httpRequest]; injectable for tests.
typedef HttpClientFactory = HttpClient Function();

/// Performs a one-shot HTTP request and returns the status code + decoded body.
///
/// Owns the [HttpClient] lifecycle: create → optional [connectionTimeout] → open
/// → set [headers] → optional write [body] → close → utf8-decode → finally
/// `close(force: true)`.
///
/// Does **not** interpret the status code — the caller applies its own policy.
/// [timeout] is applied to each network step that can block (open, close, and
/// the body read). Propagates `TimeoutException` / `SocketException` / etc. to
/// the caller unchanged.
Future<({int statusCode, String body})> httpRequest(
  Uri uri, {
  String method = 'GET',
  Map<String, String> headers = const {},
  String? body,
  Duration? connectionTimeout,
  Duration timeout = const Duration(seconds: 30),
  HttpClientFactory? factory,
}) async {
  final client = (factory ?? HttpClient.new)();
  if (connectionTimeout != null) {
    client.connectionTimeout = connectionTimeout;
  }
  try {
    final request = await client.openUrl(method, uri).timeout(timeout);
    headers.forEach(request.headers.set);
    if (body != null) {
      request.write(body);
    }
    final response = await request.close().timeout(timeout);
    final responseBody = await response.transform(utf8.decoder).join().timeout(timeout);
    return (statusCode: response.statusCode, body: responseBody);
  } finally {
    client.close(force: true);
  }
}
