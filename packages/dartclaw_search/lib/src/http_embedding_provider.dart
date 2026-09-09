part of 'embedding_providers.dart';

/// OpenAI-compatible embedding provider for one explicitly selected endpoint.
final class HttpEmbeddingProvider implements EmbeddingProvider {
  /// Creates a provider after validating the complete endpoint shape.
  new({
    required Uri endpoint,
    required String model,
    required NetworkAccessCheck checkNetworkAccess,
    String? apiKey,
    Duration requestTimeout = const Duration(seconds: 30),
    HttpClientFactory? httpClientFactory,
  }) : _endpoint = _validateEndpoint(endpoint),
       _model = _requireHttpModel(model),
       _checkNetworkAccess = checkNetworkAccess,
       _apiKey = _validateHttpCredential(endpoint, apiKey),
       _requestTimeout = _requirePositive(requestTimeout, 'requestTimeout'),
       _httpClientFactory = httpClientFactory ?? HttpClient.new,
       modelFingerprint = _fingerprint({
         'provider': 'http',
         'endpoint': _normalizeEndpoint(endpoint).toString(),
         'model': model,
         'inputConvention': _httpConvention,
       });

  final Uri _endpoint;
  final String _model;
  final NetworkAccessCheck _checkNetworkAccess;
  final String? _apiKey;
  final Duration _requestTimeout;
  final HttpClientFactory _httpClientFactory;
  final MessageRedactor _redactor = MessageRedactor();

  @override
  final String modelFingerprint;

  int? _dimension;
  bool _disposed = false;

  @override
  Future<List<double>> embedQuery(String query) async {
    final vectors = await _embed([query], operation: 'HTTP query embedding');
    return vectors.single;
  }

  @override
  Future<List<List<double>>> embedDocuments(List<String> documents) async {
    _requireNotDisposed();
    if (documents.isEmpty) return const [];
    return _embed(List.unmodifiable(documents), operation: 'HTTP document embedding');
  }

  Future<List<List<double>>> _embed(List<String> inputs, {required String operation}) async {
    _requireNotDisposed();
    final stopwatch = Stopwatch()..start();
    HttpClient? client;
    try {
      await _checkNetworkAccess(_endpoint).timeout(_remaining(_requestTimeout, stopwatch, operation));
      client = _httpClientFactory()..connectionTimeout = _remaining(_requestTimeout, stopwatch, operation);
      final request = await client
          .openUrl('POST', _endpoint)
          .timeout(_remaining(_requestTimeout, stopwatch, operation));
      request.followRedirects = false;
      request.headers.contentType = ContentType.json;
      if (_apiKey != null) request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $_apiKey');
      request.add(utf8.encode(jsonEncode({'model': _model, 'input': inputs})));
      final response = await request.close().timeout(_remaining(_requestTimeout, stopwatch, operation));
      if (response.statusCode >= 300 && response.statusCode < 400) {
        throw _EmbeddingFailure('$operation to host "${_endpoint.host}" refused a redirect');
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw _EmbeddingFailure('$operation to host "${_endpoint.host}" failed with status ${response.statusCode}');
      }
      final bytes = await _readBoundedResponse(response, timeout: _remaining(_requestTimeout, stopwatch, operation));
      final decoded = jsonDecode(utf8.decode(bytes));
      return _decodeResponse(decoded, inputs.length, operation);
    } catch (error) {
      if (error is _EmbeddingFailure) throw _sanitize(error, inputs);
      throw _sanitize(_EmbeddingFailure('$operation to host "${_endpoint.host}" failed'), inputs);
    } finally {
      client?.close(force: true);
    }
  }

  List<List<double>> _decodeResponse(Object? decoded, int expectedCount, String operation) {
    if (decoded is! Map<String, dynamic> || decoded['data'] is! List) {
      throw _EmbeddingFailure('$operation returned malformed JSON');
    }
    final ordered = List<List<double>?>.filled(expectedCount, null);
    var dimension = _dimension;
    for (final rawEntry in decoded['data'] as List) {
      if (rawEntry is! Map<String, dynamic>) throw _EmbeddingFailure('$operation returned malformed JSON');
      final index = rawEntry['index'];
      if (index is! int || index < 0 || index >= expectedCount || ordered[index] != null) {
        throw _EmbeddingFailure('$operation returned invalid embedding indices');
      }
      final vector = _validateVector(rawEntry['embedding'], operation);
      dimension = _validateDimension(dimension, vector, operation);
      ordered[index] = vector;
    }
    if (ordered.any((vector) => vector == null)) {
      throw _EmbeddingFailure('$operation returned the wrong result count');
    }
    _dimension = dimension;
    return List.unmodifiable(ordered.cast<List<double>>());
  }

  _EmbeddingFailure _sanitize(_EmbeddingFailure failure, List<String> inputs) {
    final safe = _redactor.redact(failure.message, sensitiveValues: [if (_apiKey != null) _apiKey, ...inputs]);
    return _EmbeddingFailure(safe);
  }

  void _requireNotDisposed() {
    if (_disposed) throw const _EmbeddingFailure('HTTP embedding provider is disposed');
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
  }
}

const _maxEmbeddingResponseBytes = 8 * 1024 * 1024;

Future<List<int>> _readBoundedResponse(Stream<List<int>> response, {required Duration timeout}) {
  final completer = Completer<List<int>>();
  final bytes = <int>[];
  late StreamSubscription<List<int>> subscription;
  late Timer deadline;

  void fail(_EmbeddingFailure failure) {
    if (completer.isCompleted) return;
    deadline.cancel();
    unawaited(subscription.cancel());
    completer.completeError(failure);
  }

  deadline = Timer(timeout, () => fail(const _EmbeddingFailure('HTTP embedding response timed out')));
  subscription = response.listen(
    (chunk) {
      if (bytes.length + chunk.length > _maxEmbeddingResponseBytes) {
        fail(const _EmbeddingFailure('HTTP embedding response exceeded the size limit'));
        return;
      }
      bytes.addAll(chunk);
    },
    onError: (Object _, StackTrace _) => fail(const _EmbeddingFailure('HTTP embedding response failed')),
    onDone: () {
      if (completer.isCompleted) return;
      deadline.cancel();
      completer.complete(List.unmodifiable(bytes));
    },
    cancelOnError: true,
  );
  return completer.future;
}

Uri _validateEndpoint(Uri endpoint) {
  final scheme = endpoint.scheme.toLowerCase();
  if ((scheme != 'http' && scheme != 'https') ||
      !endpoint.hasAuthority ||
      endpoint.host.isEmpty ||
      endpoint.userInfo.isNotEmpty ||
      endpoint.hasQuery ||
      endpoint.hasFragment) {
    throw ArgumentError('endpoint must be an absolute HTTP(S) URI without userinfo, query, or fragment');
  }
  return _normalizeEndpoint(endpoint);
}

Uri _normalizeEndpoint(Uri endpoint) {
  final normalized = endpoint.normalizePath();
  final defaultPort =
      (normalized.scheme.toLowerCase() == 'https' && normalized.hasPort && normalized.port == 443) ||
      (normalized.scheme.toLowerCase() == 'http' && normalized.hasPort && normalized.port == 80);
  return Uri(
    scheme: normalized.scheme.toLowerCase(),
    host: normalized.host.toLowerCase(),
    port: normalized.hasPort && !defaultPort ? normalized.port : null,
    path: normalized.path,
  );
}

String _requireHttpModel(String model) {
  if (model.trim().isEmpty) throw ArgumentError('model must not be empty');
  return model;
}

String? _validateHttpCredential(Uri endpoint, String? apiKey) {
  if (apiKey == null) return null;
  if (apiKey.isEmpty) throw ArgumentError('apiKey must not be empty');
  if (endpoint.scheme.toLowerCase() != 'https' && !isLoopbackHost(endpoint.host)) {
    throw ArgumentError('apiKey requires HTTPS except for a literal loopback host');
  }
  return apiKey;
}
