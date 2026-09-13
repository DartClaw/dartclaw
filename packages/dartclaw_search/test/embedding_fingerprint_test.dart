import 'package:dartclaw_search/dartclaw_search.dart';
import 'package:test/test.dart';

void main() {
  final checksumA = List.filled(64, 'a').join();
  final checksumB = List.filled(64, 'b').join();
  Future<void> allow(Uri _) async {}

  test('native fingerprint is stable, path-free and changes with model checksum', () {
    final first = NativeEmbeddingProvider(modelPath: '/private/first', expectedSha256: checksumA);
    final equivalent = NativeEmbeddingProvider(modelPath: '/other/secret/path', expectedSha256: checksumA);
    final changed = NativeEmbeddingProvider(modelPath: '/private/first', expectedSha256: checksumB);

    expect(first.modelFingerprint, equivalent.modelFingerprint);
    expect(first.modelFingerprint, isNot(changed.modelFingerprint));
    expect(first.modelFingerprint, matches(RegExp(r'^[0-9a-f]{64}$')));
    expect(first.modelFingerprint, isNot(contains('/private/first')));
  });

  test('HTTP fingerprint normalizes endpoint and excludes API keys and timeouts', () {
    final first = HttpEmbeddingProvider(
      endpoint: Uri.parse('HTTPS://EXAMPLE.COM:443/v1/../embeddings'),
      model: 'model-a',
      apiKey: 'first-secret',
      checkNetworkAccess: allow,
    );
    final equivalent = HttpEmbeddingProvider(
      endpoint: Uri.parse('https://example.com/embeddings'),
      model: 'model-a',
      apiKey: 'second-secret',
      requestTimeout: const Duration(seconds: 1),
      checkNetworkAccess: allow,
    );
    final changedEndpoint = HttpEmbeddingProvider(
      endpoint: Uri.parse('https://example.com/other'),
      model: 'model-a',
      checkNetworkAccess: allow,
    );
    final changedModel = HttpEmbeddingProvider(
      endpoint: Uri.parse('https://example.com/embeddings'),
      model: 'model-b',
      checkNetworkAccess: allow,
    );

    expect(first.modelFingerprint, equivalent.modelFingerprint);
    expect(first.modelFingerprint, isNot(changedEndpoint.modelFingerprint));
    expect(first.modelFingerprint, isNot(changedModel.modelFingerprint));
    expect(first.modelFingerprint, matches(RegExp(r'^[0-9a-f]{64}$')));
    expect(first.modelFingerprint, isNot(anyOf(contains('secret'), contains('example.com'))));
  });
}
