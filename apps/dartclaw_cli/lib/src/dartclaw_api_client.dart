import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_config/dartclaw_config.dart' show DartclawConfig;
import 'package:dartclaw_server/dartclaw_server.dart' show TokenService;

typedef HttpClientFactory = HttpClient Function();

/// HTTP client for CLI-to-server communication.
class DartclawApiClient {
  final Uri baseUri;
  final String? token;
  final ApiTransport _transport;

  DartclawApiClient({required this.baseUri, this.token, HttpClientFactory? httpClientFactory, ApiTransport? transport})
    : _transport = transport ?? _IoApiTransport(httpClientFactory: httpClientFactory);

  factory DartclawApiClient.fromConfig({
    required DartclawConfig config,
    String? serverOverride,
    String? tokenOverride,
    HttpClientFactory? httpClientFactory,
    ApiTransport? transport,
  }) {
    final trimmedTokenOverride = tokenOverride?.trim();
    final token = trimmedTokenOverride != null && trimmedTokenOverride.isNotEmpty
        ? trimmedTokenOverride
        : config.gateway.authMode == 'none'
        ? null
        : config.gateway.token ?? TokenService.loadFromFile(config.server.dataDir);
    return DartclawApiClient(
      baseUri: resolveServerUri(config: config, serverOverride: serverOverride),
      token: token,
      httpClientFactory: httpClientFactory,
      transport: transport,
    );
  }

  static Uri resolveServerUri({required DartclawConfig config, String? serverOverride}) {
    final raw = serverOverride?.trim();
    if (raw == null || raw.isEmpty) {
      return Uri(scheme: 'http', host: 'localhost', port: config.server.port);
    }

    if (RegExp(r'^\d+$').hasMatch(raw)) {
      return Uri(scheme: 'http', host: 'localhost', port: int.parse(raw));
    }

    final candidate = raw.contains('://') ? Uri.parse(raw) : Uri.parse('http://$raw');
    final host = candidate.host.isEmpty ? 'localhost' : candidate.host;
    final useConfigPort = !raw.contains('://') && !candidate.hasPort;
    final scheme = candidate.scheme.isEmpty ? 'http' : candidate.scheme;
    final path = candidate.path.isEmpty ? '' : candidate.path;
    if (candidate.hasPort) {
      return Uri(scheme: scheme, host: host, port: candidate.port, path: path);
    }
    if (useConfigPort) {
      return Uri(scheme: scheme, host: host, port: config.server.port, path: path);
    }
    return Uri(scheme: scheme, host: host, path: path);
  }

  Future<Object?> get(String path, {Map<String, Object?>? queryParameters}) {
    return _requestJson('GET', path, queryParameters: queryParameters);
  }

  Future<Object?> post(String path, {Object? body, Map<String, Object?>? queryParameters}) {
    return _requestJson('POST', path, body: body, queryParameters: queryParameters);
  }

  Future<Object?> patch(String path, {Object? body, Map<String, Object?>? queryParameters}) {
    return _requestJson('PATCH', path, body: body, queryParameters: queryParameters);
  }

  Future<Object?> delete(String path, {Object? body, Map<String, Object?>? queryParameters}) {
    return _requestJson('DELETE', path, body: body, queryParameters: queryParameters);
  }

  Future<Map<String, dynamic>> getObject(String path, {Map<String, Object?>? queryParameters}) async {
    return _expectObject(await get(path, queryParameters: queryParameters), path);
  }

  Future<List<dynamic>> getList(String path, {Map<String, Object?>? queryParameters}) async {
    return _expectList(await get(path, queryParameters: queryParameters), path);
  }

  Future<Map<String, dynamic>> postObject(String path, {Object? body, Map<String, Object?>? queryParameters}) async {
    return _expectObject(await post(path, body: body, queryParameters: queryParameters), path);
  }

  Future<Map<String, dynamic>> patchObject(String path, {Object? body, Map<String, Object?>? queryParameters}) async {
    return _expectObject(await patch(path, body: body, queryParameters: queryParameters), path);
  }

  Future<Map<String, dynamic>> deleteObject(String path, {Object? body, Map<String, Object?>? queryParameters}) async {
    return _expectObject(await delete(path, body: body, queryParameters: queryParameters), path);
  }

  Future<bool> probeHealth({bool treatUnauthorizedAsReachable = true}) async {
    try {
      final request = _buildRequest(method: 'GET', path: '/health');
      final response = await _transport.send(request);
      await response.body.drain<void>();
      return response.statusCode == 200 ||
          (treatUnauthorizedAsReachable && (response.statusCode == 401 || response.statusCode == 403));
    } on DartclawApiException catch (error) {
      return treatUnauthorizedAsReachable && (error.statusCode == 401 || error.statusCode == 403);
    }
  }

  Stream<Map<String, dynamic>> streamEvents(
    String path, {
    Map<String, Object?>? queryParameters,
    Future<bool> Function(int attempt)? onDisconnect,
    int maxReconnects = 3,
    List<Duration> reconnectDelays = const [Duration(seconds: 1), Duration(seconds: 2), Duration(seconds: 4)],
  }) async* {
    var attempts = 0;
    while (true) {
      final response = await _transport.openStream(
        _buildRequest(path: path, method: 'GET', queryParameters: queryParameters),
      );
      if (response.statusCode != 200) {
        final body = await response.readAsString();
        throw _exceptionForResponse(path, response.statusCode, body);
      }

      var sawEvent = false;
      await for (final event in _parseSseFrames(response.body)) {
        sawEvent = true;
        attempts = 0;
        yield event;
      }

      if (onDisconnect == null) {
        return;
      }

      if (attempts >= maxReconnects) {
        throw DartclawApiException(
          'The event stream for $path disconnected and could not be reconnected.',
          code: 'SSE_RECONNECT_EXHAUSTED',
        );
      }

      attempts += 1;
      final shouldReconnect = await onDisconnect(attempts);
      if (!shouldReconnect) {
        return;
      }

      final delayIndex = attempts - 1;
      final delay = delayIndex < reconnectDelays.length ? reconnectDelays[delayIndex] : reconnectDelays.last;
      await Future<void>.delayed(delay);

      if (!sawEvent && attempts >= maxReconnects) {
        throw DartclawApiException(
          'The event stream for $path disconnected before any events were received.',
          code: 'SSE_RECONNECT_EXHAUSTED',
        );
      }
    }
  }

  Future<Object?> _requestJson(
    String method,
    String path, {
    Object? body,
    Map<String, Object?>? queryParameters,
  }) async {
    final response = await _transport.send(
      _buildRequest(method: method, path: path, body: body, queryParameters: queryParameters),
    );
    final responseBody = await response.readAsString();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw _exceptionForResponse(path, response.statusCode, responseBody);
    }
    if (responseBody.trim().isEmpty) {
      return null;
    }
    return jsonDecode(responseBody);
  }

  ApiRequest _buildRequest({
    required String method,
    required String path,
    Object? body,
    Map<String, Object?>? queryParameters,
  }) {
    final normalizedPath = path.startsWith('/') ? path : '/$path';
    final uri = baseUri.replace(
      path: _joinPaths(baseUri.path, normalizedPath),
      queryParameters: queryParameters == null
          ? null
          : {
              for (final entry in queryParameters.entries)
                if (entry.value != null) entry.key: entry.value.toString(),
            },
    );
    final headers = <String, String>{
      'accept': 'application/json',
      if (body != null) 'content-type': 'application/json; charset=utf-8',
      if (token != null) 'authorization': 'Bearer $token',
    };
    return ApiRequest(method: method, uri: uri, headers: headers, body: body == null ? null : jsonEncode(body));
  }

  DartclawApiException _exceptionForResponse(String path, int statusCode, String body) {
    final parsed = body.trim().isEmpty ? null : jsonDecode(body);
    String? code;
    String? message;
    Object? details;
    if (parsed is Map<String, dynamic>) {
      final error = parsed['error'];
      if (error is Map<String, dynamic>) {
        code = error['code'] as String?;
        message = error['message'] as String?;
        details = error['details'];
      } else if (error is String) {
        message = error;
      }
    }

    final friendlyMessage = switch (statusCode) {
      401 =>
        'Authentication failed for ${baseUri.toString()}. Run `dartclaw token show` or `dartclaw token rotate`, configure `gateway.token`, or pass `--token`.',
      404 =>
        'The server endpoint $path was not found at ${baseUri.toString()}. The CLI and server versions may be out of sync.',
      >= 500 => message ?? 'The DartClaw server returned an internal error while handling $path.',
      _ => message ?? 'Request to $path failed with HTTP $statusCode.',
    };

    return DartclawApiException(friendlyMessage, code: code, statusCode: statusCode, details: details);
  }

  Map<String, dynamic> _expectObject(Object? value, String path) {
    if (value is Map<String, dynamic>) {
      return value;
    }
    if (value is Map) {
      return Map<String, dynamic>.from(value);
    }
    throw DartclawApiException('Expected a JSON object from $path.', code: 'INVALID_RESPONSE');
  }

  List<dynamic> _expectList(Object? value, String path) {
    if (value is List<dynamic>) {
      return value;
    }
    if (value is List) {
      return List<dynamic>.from(value);
    }
    throw DartclawApiException('Expected a JSON array from $path.', code: 'INVALID_RESPONSE');
  }
}

class DartclawApiException implements Exception {
  final String message;
  final String? code;
  final int? statusCode;
  final Object? details;

  const DartclawApiException(this.message, {this.code, this.statusCode, this.details});

  @override
  String toString() => message;
}

class ApiRequest {
  final String method;
  final Uri uri;
  final Map<String, String> headers;
  final String? body;

  const ApiRequest({required this.method, required this.uri, required this.headers, this.body});
}

class ApiResponse {
  final int statusCode;
  final Map<String, String> headers;
  final Stream<List<int>> body;

  const ApiResponse({required this.statusCode, required this.headers, required this.body});

  Future<String> readAsString() async {
    return utf8.decode(await body.expand((chunk) => chunk).toList());
  }
}

abstract interface class ApiTransport {
  Future<ApiResponse> send(ApiRequest request);

  Future<ApiResponse> openStream(ApiRequest request);
}

class _IoApiTransport implements ApiTransport {
  final HttpClientFactory _httpClientFactory;

  _IoApiTransport({HttpClientFactory? httpClientFactory}) : _httpClientFactory = httpClientFactory ?? HttpClient.new;

  @override
  Future<ApiResponse> send(ApiRequest request) async {
    return _perform(request);
  }

  @override
  Future<ApiResponse> openStream(ApiRequest request) async {
    return _perform(request);
  }

  Future<ApiResponse> _perform(ApiRequest request) async {
    final client = _httpClientFactory();
    client.connectionTimeout = const Duration(seconds: 5);
    try {
      final httpRequest = await client.openUrl(request.method, request.uri);
      request.headers.forEach(httpRequest.headers.set);
      if (request.body != null) {
        httpRequest.write(request.body);
      }
      final response = await httpRequest.close();
      final responseHeaders = <String, String>{};
      response.headers.forEach((name, values) {
        responseHeaders[name.toLowerCase()] = values.join(',');
      });
      return ApiResponse(
        statusCode: response.statusCode,
        headers: responseHeaders,
        body: response.asBroadcastStream(
          onCancel: (subscription) {
            subscription.cancel();
            client.close(force: true);
          },
        ),
      );
    } on SocketException catch (error) {
      client.close(force: true);
      if (error.osError?.errorCode == 61 || error.osError?.errorCode == 111) {
        throw DartclawApiException(
          'Connection refused at ${request.uri.origin}. Is DartClaw running? Start it with `dartclaw serve`.',
          code: 'CONNECTION_REFUSED',
        );
      }
      throw DartclawApiException('Network error while connecting to ${request.uri.origin}: ${error.message}');
    } on HandshakeException catch (error) {
      client.close(force: true);
      throw DartclawApiException('TLS handshake failed for ${request.uri.origin}: $error');
    } catch (_) {
      client.close(force: true);
      rethrow;
    }
  }
}

String _joinPaths(String basePath, String nextPath) {
  final base = basePath.endsWith('/') ? basePath.substring(0, basePath.length - 1) : basePath;
  return '$base$nextPath';
}

Stream<Map<String, dynamic>> _parseSseFrames(Stream<List<int>> bytes) async* {
  var buffer = '';
  await for (final chunk in bytes.transform(utf8.decoder)) {
    buffer += chunk.replaceAll('\r\n', '\n');
    while (true) {
      final separator = buffer.indexOf('\n\n');
      if (separator == -1) {
        break;
      }
      final frame = buffer.substring(0, separator);
      buffer = buffer.substring(separator + 2);
      final parsed = _parseSseFrame(frame);
      if (parsed != null) {
        yield parsed;
      }
    }
  }
}

Map<String, dynamic>? _parseSseFrame(String frame) {
  final dataLines = <String>[];
  for (final line in frame.split('\n')) {
    if (line.startsWith('data:')) {
      dataLines.add(line.substring(5).trimLeft());
    }
  }
  if (dataLines.isEmpty) {
    return null;
  }
  final decoded = jsonDecode(dataLines.join('\n'));
  if (decoded is Map<String, dynamic>) {
    return decoded;
  }
  if (decoded is Map) {
    return Map<String, dynamic>.from(decoded);
  }
  return {'data': decoded};
}
