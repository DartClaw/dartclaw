import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'embedding_providers.dart' show NetworkAccessCheck;

/// Frozen metadata for DartClaw's default local embedding model.
abstract final class DefaultEmbeddingModel {
  /// Published GGUF filename.
  static const filename = 'embeddinggemma-300M-Q8_0.gguf';

  /// Immutable source selected before held-out evaluation.
  static const sourceUrl =
      'https://huggingface.co/ggml-org/embeddinggemma-300M-GGUF/resolve/'
      '0f741b5a6585bd53aeb15cd1372c56f2a0f65e12/embeddinggemma-300M-Q8_0.gguf';

  /// Exact verified file size.
  static const byteSize = 333590944;

  /// Lowercase SHA-256 of the verified file.
  static const sha256 = 'b5ce9d77a3fc4b3b39ccb5643c36777911cc4eb46a66962eadfa3f5f60490d63';

  /// Licence governing the selected model.
  static const licenseName = 'Gemma Terms of Use';

  /// Licence URL governing the selected model.
  static const licenseUrl = 'https://ai.google.dev/gemma/terms';
}

/// Outcome of explicit default-model acquisition.
enum ModelAcquisitionStatus {
  /// The destination already held the exact verified bytes.
  reused,

  /// Verified bytes were downloaded and atomically published.
  downloaded,
}

/// Verified path and publication outcome for one acquisition.
final class ModelAcquisitionResult {
  const new _({required this.path, required this.status});

  /// Requested destination containing verified model bytes.
  final String path;

  /// Whether existing bytes were reused or new bytes published.
  final ModelAcquisitionStatus status;
}

/// Explicit downloader for the frozen default embedding model.
final class DefaultEmbeddingModelAcquirer {
  /// Creates an acquirer using the runtime's injected network authority.
  new({required NetworkAccessCheck checkNetworkAccess, HttpClientFactory? httpClientFactory})
    : this._(
        checkNetworkAccess: checkNetworkAccess,
        httpClientFactory: httpClientFactory ?? HttpClient.new,
        source: Uri.parse(DefaultEmbeddingModel.sourceUrl),
        expectedSize: DefaultEmbeddingModel.byteSize,
        expectedSha256: DefaultEmbeddingModel.sha256,
      );

  new _({
    required NetworkAccessCheck checkNetworkAccess,
    required HttpClientFactory httpClientFactory,
    required Uri source,
    required int expectedSize,
    required String expectedSha256,
  }) : _checkNetworkAccess = checkNetworkAccess,
       _httpClientFactory = httpClientFactory,
       _source = source,
       _expectedSize = expectedSize,
       _expectedSha256 = expectedSha256;

  static const _networkTimeout = Duration(seconds: 30);
  static const _maximumRedirects = 3;
  static int _temporarySequence = 0;

  final NetworkAccessCheck _checkNetworkAccess;
  final HttpClientFactory _httpClientFactory;
  final Uri _source;
  final int _expectedSize;
  final String _expectedSha256;

  /// Reuses verified bytes or downloads, verifies and publishes the model.
  Future<ModelAcquisitionResult> acquire({required String destinationPath}) async {
    if (destinationPath.isEmpty) throw ArgumentError('destinationPath must not be empty');
    final destination = File(destinationPath);
    if (await _isVerified(destination)) {
      return ModelAcquisitionResult._(path: destinationPath, status: ModelAcquisitionStatus.reused);
    }

    await destination.parent.create(recursive: true);
    final temporary = File(
      '$destinationPath.download-$pid-${DateTime.now().microsecondsSinceEpoch}-${_temporarySequence++}',
    );
    HttpClient? client;
    IOSink? output;
    var published = false;
    try {
      client = _httpClientFactory()..connectionTimeout = _networkTimeout;
      final response = await _openResponse(client);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw _ModelAcquisitionFailure('Default embedding model download failed with status ${response.statusCode}');
      }

      await temporary.create(exclusive: true);
      output = temporary.openWrite();
      Digest? digest;
      final digestSink = sha256.startChunkedConversion(
        ChunkedConversionSink.withCallback((values) => digest = values.single),
      );
      var received = 0;
      await for (final chunk in response.timeout(_networkTimeout)) {
        received += chunk.length;
        if (received > _expectedSize) {
          throw const _ModelAcquisitionFailure('Default embedding model download has the wrong size');
        }
        digestSink.add(chunk);
        output.add(chunk);
      }
      digestSink.close();
      await output.close();
      output = null;
      if (received != _expectedSize) {
        throw const _ModelAcquisitionFailure('Default embedding model download has the wrong size');
      }
      if (digest?.toString() != _expectedSha256) {
        throw const _ModelAcquisitionFailure('Default embedding model download failed verification');
      }

      await temporary.rename(destinationPath);
      published = true;
      return ModelAcquisitionResult._(path: destinationPath, status: ModelAcquisitionStatus.downloaded);
    } on _ModelAcquisitionFailure {
      rethrow;
    } on TimeoutException {
      throw const _ModelAcquisitionFailure('Default embedding model download timed out');
    } catch (_) {
      throw const _ModelAcquisitionFailure('Default embedding model download failed');
    } finally {
      client?.close(force: true);
      if (output != null) {
        try {
          await output.close();
        } catch (_) {}
      }
      if (!published) {
        try {
          if (await temporary.exists()) await temporary.delete();
        } catch (_) {}
      }
    }
  }

  Future<HttpClientResponse> _openResponse(HttpClient client) async {
    var uri = _source;
    var redirects = 0;
    while (true) {
      await _authorize(uri);
      final request = await client.getUrl(uri).timeout(_networkTimeout);
      request.followRedirects = false;
      final response = await request.close().timeout(_networkTimeout);
      if (response.statusCode < 300 || response.statusCode >= 400) return response;
      if (redirects >= _maximumRedirects) {
        throw const _ModelAcquisitionFailure('Default embedding model download exceeded the redirect limit');
      }
      final location = response.headers.value(HttpHeaders.locationHeader);
      if (location == null || location.isEmpty) {
        throw const _ModelAcquisitionFailure('Default embedding model download received a redirect without a location');
      }
      try {
        uri = uri.resolve(location);
      } on FormatException {
        throw const _ModelAcquisitionFailure('Default embedding model download received an unsafe redirect');
      }
      if (uri.scheme != 'https' || uri.host.isEmpty || uri.userInfo.isNotEmpty || uri.fragment.isNotEmpty) {
        throw const _ModelAcquisitionFailure('Default embedding model download received an unsafe redirect');
      }
      redirects++;
    }
  }

  Future<void> _authorize(Uri uri) async {
    try {
      await _checkNetworkAccess(uri).timeout(_networkTimeout);
    } catch (_) {
      throw const _ModelAcquisitionFailure('Default embedding model network access was denied');
    }
  }

  Future<bool> _isVerified(File file) async {
    try {
      if (!await file.exists()) return false;
      if (await file.length() != _expectedSize) return false;
      return (await sha256.bind(file.openRead()).first).toString() == _expectedSha256;
    } catch (_) {
      return false;
    }
  }
}

/// Creates an acquirer with small deterministic artifact metadata for tests.
DefaultEmbeddingModelAcquirer createDefaultEmbeddingModelAcquirerForTesting({
  required NetworkAccessCheck checkNetworkAccess,
  required HttpClientFactory httpClientFactory,
  required Uri source,
  required int expectedSize,
  required String expectedSha256,
}) => DefaultEmbeddingModelAcquirer._(
  checkNetworkAccess: checkNetworkAccess,
  httpClientFactory: httpClientFactory,
  source: source,
  expectedSize: expectedSize,
  expectedSha256: expectedSha256,
);

final class _ModelAcquisitionFailure implements Exception {
  final String message;

  const new(this.message);

  @override
  String toString() => message;
}
