import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_search/dartclaw_search.dart';
import 'package:path/path.dart' as p;

import '../mcp/web_fetch_tool.dart';

/// Returns the managed path for the only supported local embedding model.
String defaultEmbeddingModelPath(DartclawConfig config) =>
    p.join(config.server.dataDir, 'models', DefaultEmbeddingModel.filename);

/// Applies the runtime network policy to one explicit embedding endpoint.
Future<void> checkEmbeddingNetworkAccess(Uri uri) async {
  if (isLoopbackHost(uri.host)) return;
  final failure = await WebFetchTool.checkSsrfPolicy(uri);
  if (failure != null) {
    throw StateError('Embedding endpoint is not permitted by the configured network policy.');
  }
}

/// Creates the single embedding provider selected by [config].
EmbeddingProvider createConfiguredEmbeddingProvider(
  DartclawConfig config, {
  CredentialRegistry? credentials,
  NetworkAccessCheck? checkNetworkAccess,
}) {
  final embedding = config.search.embedding;
  return switch (embedding.provider) {
    EmbeddingProviderKind.local => _createLocalProvider(config, embedding),
    EmbeddingProviderKind.http => _createHttpProvider(
      embedding,
      credentials ?? CredentialRegistry(credentials: config.credentials),
      checkNetworkAccess ?? checkEmbeddingNetworkAccess,
    ),
  };
}

EmbeddingProvider _createLocalProvider(DartclawConfig config, EmbeddingConfig embedding) {
  if (embedding.model != DefaultEmbeddingModel.filename || embedding.endpoint != null || embedding.credential != null) {
    throw StateError('The configured local embedding settings are invalid.');
  }
  return NativeEmbeddingProvider(
    modelPath: defaultEmbeddingModelPath(config),
    expectedSha256: DefaultEmbeddingModel.sha256,
  );
}

EmbeddingProvider _createHttpProvider(
  EmbeddingConfig embedding,
  CredentialRegistry credentials,
  NetworkAccessCheck checkNetworkAccess,
) {
  final endpoint = embedding.endpoint;
  if (!isValidEmbeddingCredentialEndpoint(endpoint, embedding.credential)) {
    throw ArgumentError('The configured embedding endpoint is invalid.');
  }
  final model = embedding.model.trim();
  if (model.isEmpty) throw StateError('The configured HTTP embedding model is empty.');

  String? apiKey;
  final credential = embedding.credential;
  if (credential != null) {
    final entry = credentials.namedEntry(credential);
    if (entry == null || !entry.isApiKeyCredential || !entry.isPresent) {
      throw StateError('Embedding credential "$credential" must be a present generic API key.');
    }
    apiKey = entry.secret;
  }
  return HttpEmbeddingProvider(
    endpoint: endpoint!,
    model: model,
    apiKey: apiKey,
    checkNetworkAccess: checkNetworkAccess,
  );
}
