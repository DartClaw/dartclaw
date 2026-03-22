import 'dart:io';

import 'package:logging/logging.dart';

/// HTTP proxy that runs on a Unix socket and injects API credentials
/// into outbound requests to Anthropic.
///
/// The container has `network:none` — this proxy is the sole egress path.
/// API keys never exist inside the container.
class CredentialProxy {
  static final _log = Logger('CredentialProxy');

  final String socketPath;
  final String? apiKey;
  final String targetHost;
  final int targetPort;

  HttpServer? _server;
  final HttpClient _client = HttpClient();
  int _requestCount = 0;
  int _errorCount = 0;

  CredentialProxy({
    required this.socketPath,
    this.apiKey,
    this.targetHost = 'api.anthropic.com',
    this.targetPort = 443,
  });

  int get requestCount => _requestCount;
  int get errorCount => _errorCount;

  /// Start the proxy on a Unix socket.
  Future<void> start() async {
    // Ensure socket dir exists and old socket is cleaned up
    final socketFile = File(socketPath);
    if (socketFile.existsSync()) {
      socketFile.deleteSync();
    }
    final dir = socketFile.parent;
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }

    _server = await HttpServer.bind(InternetAddress(socketPath, type: InternetAddressType.unix), 0);
    // Restrict socket to owner-only — prevents other host processes from
    // connecting and injecting credential headers.
    final chmodResult = await Process.run('chmod', ['600', socketPath]);
    if (chmodResult.exitCode != 0) {
      _log.warning('Failed to chmod 600 $socketPath: ${chmodResult.stderr}');
    }
    _log.info('Credential proxy listening on $socketPath');

    _server!.listen(_handleRequest);
  }

  /// Stop the proxy server.
  Future<void> stop() async {
    await _server?.close();
    _server = null;
    _client.close(force: true);
    _log.info('Credential proxy stopped (requests: $_requestCount, errors: $_errorCount)');

    // Clean up socket file
    try {
      final socketFile = File(socketPath);
      if (socketFile.existsSync()) socketFile.deleteSync();
    } catch (e) {
      _log.fine('Failed to delete proxy socket file: $e');
    }
  }

  Future<void> _handleRequest(HttpRequest request) async {
    _requestCount++;
    final stopwatch = Stopwatch()..start();

    try {
      final targetUrl = targetPort == 443
          ? Uri.https(targetHost, request.uri.path, request.uri.queryParametersAll)
          : Uri.http('$targetHost:$targetPort', request.uri.path, request.uri.queryParametersAll);
      _client.connectionTimeout = const Duration(seconds: 30);
      final outbound = await _client.openUrl(request.method, targetUrl);

      // Copy headers from original request
      request.headers.forEach((name, values) {
        if (name.toLowerCase() == 'host') return; // Don't copy host
        for (final value in values) {
          outbound.headers.add(name, value);
        }
      });

      // Inject API-key auth when configured. OAuth/setup-token mode forwards
      // the existing auth headers from the claude CLI unchanged.
      final key = apiKey;
      if (key != null && key.isNotEmpty) {
        outbound.headers.set('x-api-key', key);
        outbound.headers.set('Authorization', 'Bearer $key');
      }

      // Forward request body
      await for (final chunk in request) {
        outbound.add(chunk);
      }
      final response = await outbound.close();

      // Stream response back
      request.response.statusCode = response.statusCode;
      response.headers.forEach((name, values) {
        for (final value in values) {
          request.response.headers.add(name, value);
        }
      });
      await response.pipe(request.response);

      stopwatch.stop();
      _log.fine(
        'Proxy ${request.method} ${request.uri.path} -> $targetHost (${response.statusCode}, ${stopwatch.elapsedMilliseconds}ms)',
      );
    } catch (e) {
      _errorCount++;
      stopwatch.stop();
      _log.warning('Proxy error: ${request.method} ${request.uri.path} (${stopwatch.elapsedMilliseconds}ms): $e');
      try {
        request.response.statusCode = 502;
        request.response.write('Bad Gateway');
        await request.response.close();
      } catch (e) {
        _log.fine('Failed to send 502 error response to client: $e');
      }
    }
  }
}
