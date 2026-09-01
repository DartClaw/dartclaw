import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// HTTP and SSE client for a running DartClaw server.
///
/// Construction takes the server's base URI and, unless the gateway runs with
/// authentication disabled, a bearer token. Every request carries
/// `accept: application/json`; failures surface as [DartclawApiException]
/// carrying the server's `code`/`statusCode`/`details` envelope.
class DartclawApiClient {
  /// Base URI of the DartClaw server, including any path prefix.
  final Uri baseUri;

  /// Bearer token sent on every request, or `null` for an unauthenticated gateway.
  final String? token;

  final ApiTransport _transport;

  /// Creates a client against [baseUri].
  ///
  /// [httpClientFactory] replaces the default `HttpClient` construction (an
  /// integration-test seam); [transport] replaces the whole `dart:io` transport.
  new({required this.baseUri, this.token, HttpClient Function()? httpClientFactory, ApiTransport? transport})
    : _transport = transport ?? _IoApiTransport(httpClientFactory: httpClientFactory);

  /// Sends a GET request to [path] and decodes the JSON body.
  ///
  /// Returns `null` for an empty body. Throws [DartclawApiException] on a
  /// non-2xx status.
  Future<Object?> get(String path, {Map<String, Object?>? queryParameters}) {
    return _requestJson('GET', path, queryParameters: queryParameters);
  }

  /// GET request that returns the raw response body as text. Use for
  /// endpoints that emit non-JSON content types (e.g. `application/yaml`).
  Future<String> getText(String path, {Map<String, Object?>? queryParameters}) async {
    final response = await _transport.send(_buildRequest(method: 'GET', path: path, queryParameters: queryParameters));
    final body = await response.readAsString();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw _exceptionForResponse(path, response.statusCode, body);
    }
    return body;
  }

  /// Sends a POST request with a JSON-encoded [body] and decodes the response.
  Future<Object?> post(String path, {Object? body, Map<String, Object?>? queryParameters}) {
    return _requestJson('POST', path, body: body, queryParameters: queryParameters);
  }

  /// Sends a PATCH request with a JSON-encoded [body] and decodes the response.
  Future<Object?> patch(String path, {Object? body, Map<String, Object?>? queryParameters}) {
    return _requestJson('PATCH', path, body: body, queryParameters: queryParameters);
  }

  /// Sends a DELETE request with an optional JSON-encoded [body].
  Future<Object?> delete(String path, {Object? body, Map<String, Object?>? queryParameters}) {
    return _requestJson('DELETE', path, body: body, queryParameters: queryParameters);
  }

  /// GETs [path] and requires a JSON object body.
  ///
  /// Throws [DartclawApiException] with code `INVALID_RESPONSE` when the body
  /// decodes to anything else.
  Future<Map<String, dynamic>> getObject(String path, {Map<String, Object?>? queryParameters}) async {
    return _expectObject(await get(path, queryParameters: queryParameters), path);
  }

  /// GETs [path] and requires a JSON array body.
  ///
  /// Throws [DartclawApiException] with code `INVALID_RESPONSE` when the body
  /// decodes to anything else.
  Future<List<dynamic>> getList(String path, {Map<String, Object?>? queryParameters}) async {
    return _expectList(await get(path, queryParameters: queryParameters), path);
  }

  /// POSTs to [path] and requires a JSON object body in the response.
  Future<Map<String, dynamic>> postObject(String path, {Object? body, Map<String, Object?>? queryParameters}) async {
    return _expectObject(await post(path, body: body, queryParameters: queryParameters), path);
  }

  /// PATCHes [path] and requires a JSON object body in the response.
  Future<Map<String, dynamic>> patchObject(String path, {Object? body, Map<String, Object?>? queryParameters}) async {
    return _expectObject(await patch(path, body: body, queryParameters: queryParameters), path);
  }

  /// DELETEs [path] and requires a JSON object body in the response.
  Future<Map<String, dynamic>> deleteObject(String path, {Object? body, Map<String, Object?>? queryParameters}) async {
    return _expectObject(await delete(path, body: body, queryParameters: queryParameters), path);
  }

  /// Reports whether `/health` answers.
  ///
  /// With [treatUnauthorizedAsReachable] a `401`/`403` counts as reachable —
  /// the server responded, the caller simply lacks a valid token.
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

  /// Streams decoded `data:` frames from the SSE endpoint at [path].
  ///
  /// When the stream drops, [onDisconnect] decides whether to reconnect; a
  /// `null` callback ends the stream on the first drop. Reconnect attempts are
  /// spaced by [reconnectDelays] (the last entry repeats) and capped at
  /// [maxReconnects], after which a [DartclawApiException] with code
  /// `SSE_RECONNECT_EXHAUSTED` is thrown. A frame carrying no `data:` line is
  /// skipped rather than aborting the stream.
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
    Object? parsed;
    if (body.trim().isNotEmpty) {
      try {
        parsed = jsonDecode(body);
      } on FormatException {
        parsed = null;
      }
    }
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
        message ??
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

/// Failure of a DartClaw API request.
///
/// [code], [statusCode] and [details] mirror the server's error envelope when
/// it sent one; transport failures carry a [code] and no [statusCode].
class DartclawApiException implements Exception {
  /// Human-readable message.
  ///
  /// Never contains the [DartclawApiClient.token] value. It can contain the
  /// client's base URI, so keep credentials out of `baseUri` — a `userInfo`
  /// component or a query parameter there would be printed.
  final String message;

  /// Machine-readable error code from the server envelope, or a transport code.
  final String? code;

  /// HTTP status of the failed response, or `null` for a transport failure.
  final int? statusCode;

  /// Structured error detail from the server envelope, when present.
  final Object? details;

  /// Creates an exception carrying [message] and the optional error envelope.
  const new(this.message, {this.code, this.statusCode, this.details});

  @override
  String toString() => message;
}

/// A prepared HTTP request, as handed to an [ApiTransport].
class ApiRequest {
  /// HTTP method, uppercase.
  final String method;

  /// Fully resolved request URI, including query parameters.
  final Uri uri;

  /// Request headers, lowercase keys.
  final Map<String, String> headers;

  /// Encoded request body, or `null` for a body-less request.
  final String? body;

  /// Creates a request.
  const new({required this.method, required this.uri, required this.headers, this.body});
}

/// An HTTP response with an unread body stream.
class ApiResponse {
  /// HTTP status code.
  final int statusCode;

  /// Response headers, lowercase keys.
  final Map<String, String> headers;

  /// Response body as a byte stream; consume it exactly once.
  final Stream<List<int>> body;

  /// Creates a response.
  const new({required this.statusCode, required this.headers, required this.body});

  /// Drains [body] and decodes it as UTF-8.
  Future<String> readAsString() async {
    return utf8.decode(await body.expand((chunk) => chunk).toList());
  }
}

/// The seam between [DartclawApiClient] and the wire.
///
/// Implement it to run the client against a fake in tests, or against a
/// transport other than `dart:io`.
abstract interface class ApiTransport {
  /// Performs [request] and returns the response once headers are available.
  Future<ApiResponse> send(ApiRequest request);

  /// Performs [request] for a long-lived response whose body stays open.
  Future<ApiResponse> openStream(ApiRequest request);
}

class _IoApiTransport implements ApiTransport {
  final HttpClient Function() _httpClientFactory;

  new({HttpClient Function()? httpClientFactory}) : _httpClientFactory = httpClientFactory ?? HttpClient.new;

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
      // Close client on any failure (network/cert/timeout) before bubbling the original error.
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
