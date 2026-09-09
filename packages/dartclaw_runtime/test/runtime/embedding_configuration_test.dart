import 'dart:io';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart';
import 'package:dartclaw_search/dartclaw_search.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('embedding_configuration_'));

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  DartclawConfig config(EmbeddingConfig embedding) => DartclawConfig(
    server: ServerConfig(dataDir: root.path),
    search: SearchConfig(backend: 'hybrid', embedding: embedding),
  );

  test('derives the managed local artifact path from frozen model metadata', () {
    final value = config(const EmbeddingConfig());

    expect(defaultEmbeddingModelPath(value), p.join(root.path, 'models', DefaultEmbeddingModel.filename));
    expect(createConfiguredEmbeddingProvider(value), isA<NativeEmbeddingProvider>());
  });

  test('refuses directly constructed invalid local settings', () {
    final cases = [
      const EmbeddingConfig(model: 'arbitrary.gguf'),
      EmbeddingConfig(endpoint: Uri.parse('http://localhost/embeddings')),
      const EmbeddingConfig(credential: 'remote'),
    ];

    for (final embedding in cases) {
      expect(() => createConfiguredEmbeddingProvider(config(embedding)), throwsStateError);
    }
  });

  test('rejects unsafe HTTP endpoint before exposing endpoint or credential material', () {
    const secret = 'DistinctiveEmbeddingSecret';
    final endpoint = Uri.parse('https://user:password@example.com/embeddings?token=secret');
    final value = DartclawConfig(
      server: ServerConfig(dataDir: root.path),
      credentials: const CredentialsConfig(entries: {'remote': CredentialEntry(apiKey: secret)}),
      search: SearchConfig(
        backend: 'hybrid',
        embedding: EmbeddingConfig(
          provider: EmbeddingProviderKind.http,
          model: 'remote-model',
          endpoint: endpoint,
          credential: 'remote',
        ),
      ),
    );

    expect(
      () => createConfiguredEmbeddingProvider(value),
      throwsA(
        isA<ArgumentError>()
            .having((error) => '$error', 'message', isNot(contains(endpoint.toString())))
            .having((error) => '$error', 'message', isNot(contains(secret))),
      ),
    );
  });

  test('requires a present generic API key without exposing its value', () {
    const secret = 'WrongTypeSecret';
    final value = DartclawConfig(
      server: ServerConfig(dataDir: root.path),
      credentials: const CredentialsConfig(entries: {'remote': CredentialEntry.githubToken(token: secret)}),
      search: SearchConfig(
        backend: 'hybrid',
        embedding: EmbeddingConfig(
          provider: EmbeddingProviderKind.http,
          model: 'remote-model',
          endpoint: Uri.parse('http://localhost/embeddings'),
          credential: 'remote',
        ),
      ),
    );

    expect(
      () => createConfiguredEmbeddingProvider(value),
      throwsA(
        isA<StateError>()
            .having((error) => '$error', 'message', contains('remote'))
            .having((error) => '$error', 'message', isNot(contains(secret))),
      ),
    );
  });

  test('credential transport rules are enforced before any network access', () async {
    var networkChecks = 0;
    for (final transport in [
      (endpoint: 'http://example.com/embeddings', credential: true, allowed: false),
      (endpoint: 'http://example.com/embeddings', credential: false, allowed: true),
      (endpoint: 'https://example.com/embeddings', credential: true, allowed: true),
      (endpoint: 'http://localhost/embeddings', credential: true, allowed: true),
      (endpoint: 'http://127.0.0.1/embeddings', credential: true, allowed: true),
      (endpoint: 'http://[::1]/embeddings', credential: true, allowed: true),
      (endpoint: 'http://127.0.0.2/embeddings', credential: true, allowed: false),
    ]) {
      final value = DartclawConfig(
        credentials: const CredentialsConfig(entries: {'remote': CredentialEntry(apiKey: 'test-key')}),
        search: SearchConfig(
          backend: 'hybrid',
          embedding: EmbeddingConfig(
            provider: EmbeddingProviderKind.http,
            model: 'remote-model',
            endpoint: Uri.parse(transport.endpoint),
            credential: transport.credential ? 'remote' : null,
          ),
        ),
      );
      EmbeddingProvider construct() =>
          createConfiguredEmbeddingProvider(value, checkNetworkAccess: (_) async => networkChecks++);
      if (transport.allowed) {
        final provider = construct();
        expect(provider, isA<HttpEmbeddingProvider>());
        await provider.dispose();
      } else {
        expect(construct, throwsArgumentError);
      }
    }
    expect(networkChecks, 0);
  });

  test('literal loopback network checks require no DNS or SSRF policy result', () async {
    for (final host in ['localhost', '127.0.0.1', '::1']) {
      await checkEmbeddingNetworkAccess(Uri(scheme: 'http', host: host, path: '/embeddings'));
    }
  });
}
