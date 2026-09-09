part of 'embedding_providers.dart';

abstract interface class _NativeEmbeddingEngine {
  Future<void> loadModel(String path);

  Future<List<double>> embed(String input);

  Future<List<List<double>>> embedBatch(List<String> inputs);

  Future<void> dispose();
}

final class _LlamadartEmbeddingEngine implements _NativeEmbeddingEngine {
  final LlamaEngine _engine = LlamaEngine(LlamaBackend());

  @override
  Future<void> loadModel(String path) => _engine.loadModel(path);

  @override
  Future<List<double>> embed(String input) => _engine.embed(input);

  @override
  Future<List<List<double>>> embedBatch(List<String> inputs) => _engine.embedBatch(inputs);

  @override
  Future<void> dispose() => _engine.dispose();
}

/// In-process EmbeddingGemma provider backed by a verified GGUF model.
final class NativeEmbeddingProvider implements EmbeddingProvider {
  /// Creates a lazy provider without reading or loading [modelPath].
  new({
    required String modelPath,
    required String expectedSha256,
    Duration initializationTimeout = const Duration(seconds: 60),
    Duration shutdownTimeout = const Duration(seconds: 10),
  }) : this._(
         modelPath: modelPath,
         expectedSha256: expectedSha256,
         initializationTimeout: initializationTimeout,
         shutdownTimeout: shutdownTimeout,
         engineFactory: _LlamadartEmbeddingEngine.new,
       );

  new _({
    required String modelPath,
    required String expectedSha256,
    required Duration initializationTimeout,
    required Duration shutdownTimeout,
    required _NativeEmbeddingEngine Function() engineFactory,
  }) : _modelPath = _requireModelPath(modelPath),
       _expectedSha256 = _requireSha256(expectedSha256),
       _initializationTimeout = _requirePositive(initializationTimeout, 'initializationTimeout'),
       _shutdownTimeout = _requirePositive(shutdownTimeout, 'shutdownTimeout'),
       _engineFactory = engineFactory,
       modelFingerprint = _fingerprint({
         'provider': 'native',
         'llamadart': '0.8.22',
         'modelSha256': expectedSha256.toLowerCase(),
         'inputConvention': _nativeConvention,
         'queryPrefix': _nativeQueryPrefix,
         'documentPrefix': _nativeDocumentPrefix,
       });

  final String _modelPath;
  final String _expectedSha256;
  final Duration _initializationTimeout;
  final Duration _shutdownTimeout;
  final _NativeEmbeddingEngine Function() _engineFactory;

  @override
  final String modelFingerprint;

  _NativeEmbeddingEngine? _engine;
  Future<_NativeEmbeddingEngine>? _initialization;
  Future<void>? _disposal;
  int? _dimension;
  bool _disposed = false;
  bool _poisoned = false;

  @override
  Future<List<double>> embedQuery(String query) async {
    final engine = await _engineForUse();
    try {
      final vector = _validateVector(await engine.embed('$_nativeQueryPrefix$query'), 'Native query embedding');
      _dimension = _validateDimension(_dimension, vector, 'Native query embedding');
      return vector;
    } catch (error) {
      if (error is _EmbeddingFailure) rethrow;
      throw const _EmbeddingFailure('Native query embedding failed');
    }
  }

  @override
  Future<List<List<double>>> embedDocuments(List<String> documents) async {
    _requireAvailable();
    if (documents.isEmpty) return const [];
    final engine = await _engineForUse();
    try {
      final raw = await engine.embedBatch([for (final document in documents) '$_nativeDocumentPrefix$document']);
      if (raw.length != documents.length) {
        throw const _EmbeddingFailure('Native document embedding returned the wrong result count');
      }
      final vectors = <List<double>>[];
      var dimension = _dimension;
      for (final value in raw) {
        final vector = _validateVector(value, 'Native document embedding');
        dimension = _validateDimension(dimension, vector, 'Native document embedding');
        vectors.add(vector);
      }
      _dimension = dimension;
      return List.unmodifiable(vectors);
    } catch (error) {
      if (error is _EmbeddingFailure) rethrow;
      throw const _EmbeddingFailure('Native document embedding failed');
    }
  }

  Future<_NativeEmbeddingEngine> _engineForUse() async {
    _requireAvailable();
    final loaded = _engine;
    if (loaded != null) return loaded;

    final existing = _initialization;
    if (existing != null) {
      final engine = await existing;
      _requireAvailable();
      return engine;
    }

    final raw = _initialize();
    late final Future<_NativeEmbeddingEngine> bounded;
    bounded = raw
        .timeout(
          _initializationTimeout,
          onTimeout: () {
            _poisoned = true;
            unawaited(
              raw.then<void>((lateEngine) => _disposeLateEngine(lateEngine), onError: (Object _, StackTrace _) {}),
            );
            throw const _EmbeddingFailure('Native embedding initialization timed out');
          },
        )
        .then((engine) async {
          if (_disposed) {
            await _disposeLateEngine(engine);
            throw const _EmbeddingFailure('Native embedding provider is disposed');
          }
          _engine = engine;
          return engine;
        });
    _initialization = bounded;
    try {
      final engine = await bounded;
      _initialization = null;
      _requireAvailable();
      return engine;
    } catch (error) {
      if (!_poisoned && identical(_initialization, bounded)) _initialization = null;
      if (error is _EmbeddingFailure) rethrow;
      throw const _EmbeddingFailure('Native embedding initialization failed');
    }
  }

  Future<_NativeEmbeddingEngine> _initialize() async {
    final file = File(_modelPath);
    try {
      if (!await file.exists()) throw const _EmbeddingFailure('Native embedding model is unavailable');
      final stat = await file.stat();
      if (stat.type != FileSystemEntityType.file) {
        throw const _EmbeddingFailure('Native embedding model is unavailable');
      }
      final actual = await sha256.bind(file.openRead()).first;
      if (actual.toString() != _expectedSha256) {
        throw const _EmbeddingFailure('Native embedding model verification failed');
      }
    } on _EmbeddingFailure {
      rethrow;
    } catch (_) {
      throw const _EmbeddingFailure('Native embedding model verification failed');
    }

    final engine = _engineFactory();
    try {
      await engine.loadModel(_modelPath);
      return engine;
    } catch (_) {
      try {
        await engine.dispose().timeout(_shutdownTimeout);
      } catch (_) {
        _poisoned = true;
      }
      throw const _EmbeddingFailure('Native embedding initialization failed');
    }
  }

  void _requireAvailable() {
    if (_disposed) throw const _EmbeddingFailure('Native embedding provider is disposed');
    if (_poisoned) {
      throw const _EmbeddingFailure('Native embedding provider must be reconstructed after initialization timeout');
    }
  }

  Future<void> _disposeLateEngine(_NativeEmbeddingEngine engine) async {
    try {
      await engine.dispose().timeout(_shutdownTimeout);
    } catch (_) {}
  }

  @override
  Future<void> dispose() => _disposal ??= _dispose();

  Future<void> _dispose() async {
    _disposed = true;
    final stopwatch = Stopwatch()..start();
    final initializing = _initialization;
    if (_engine == null && initializing != null) {
      try {
        await initializing.timeout(_remaining(_shutdownTimeout, stopwatch, 'Native embedding shutdown'));
      } on TimeoutException {
        throw const _EmbeddingFailure('Native embedding shutdown timed out');
      } catch (_) {}
    }
    final engine = _engine;
    _engine = null;
    if (engine == null) return;
    try {
      await engine.dispose().timeout(_remaining(_shutdownTimeout, stopwatch, 'Native embedding shutdown'));
    } on TimeoutException {
      throw const _EmbeddingFailure('Native embedding shutdown timed out');
    } on _EmbeddingFailure {
      rethrow;
    } catch (_) {
      throw const _EmbeddingFailure('Native embedding shutdown failed');
    }
  }
}

/// Creates a native provider with callback-based engine behavior for tests.
NativeEmbeddingProvider createNativeEmbeddingProviderForTesting({
  required String modelPath,
  required String expectedSha256,
  required Future<void> Function(String path) loadModel,
  required Future<List<double>> Function(String input) embed,
  required Future<List<List<double>>> Function(List<String> inputs) embedBatch,
  required Future<void> Function() disposeEngine,
  Duration initializationTimeout = const Duration(seconds: 60),
  Duration shutdownTimeout = const Duration(seconds: 10),
}) => NativeEmbeddingProvider._(
  modelPath: modelPath,
  expectedSha256: expectedSha256,
  initializationTimeout: initializationTimeout,
  shutdownTimeout: shutdownTimeout,
  engineFactory: () =>
      _CallbackEmbeddingEngine(loadModel: loadModel, embed: embed, embedBatch: embedBatch, dispose: disposeEngine),
);

final class _CallbackEmbeddingEngine implements _NativeEmbeddingEngine {
  new({
    required Future<void> Function(String path) loadModel,
    required Future<List<double>> Function(String input) embed,
    required Future<List<List<double>>> Function(List<String> inputs) embedBatch,
    required Future<void> Function() dispose,
  }) : _loadModel = loadModel,
       _embed = embed,
       _embedBatch = embedBatch,
       _dispose = dispose;

  final Future<void> Function(String path) _loadModel;
  final Future<List<double>> Function(String input) _embed;
  final Future<List<List<double>>> Function(List<String> inputs) _embedBatch;
  final Future<void> Function() _dispose;

  @override
  Future<void> loadModel(String path) => _loadModel(path);

  @override
  Future<List<double>> embed(String input) => _embed(input);

  @override
  Future<List<List<double>>> embedBatch(List<String> inputs) => _embedBatch(inputs);

  @override
  Future<void> dispose() => _dispose();
}

String _requireModelPath(String value) {
  if (value.isEmpty) throw ArgumentError('modelPath must not be empty');
  return value;
}

String _requireSha256(String value) {
  final normalized = value.toLowerCase();
  if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(normalized)) {
    throw ArgumentError('expectedSha256 must be a SHA-256 digest');
  }
  return normalized;
}

Duration _requirePositive(Duration value, String name) {
  if (value <= Duration.zero) throw ArgumentError('$name must be positive');
  return value;
}
