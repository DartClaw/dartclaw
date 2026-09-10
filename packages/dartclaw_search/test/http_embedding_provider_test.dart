import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_search/dartclaw_search.dart';
import 'package:test/test.dart';

import 'support/fake_http_client.dart';

void main() {
  test('sends exact raw inputs and model after policy, refuses redirects and restores indexed order', () async {
    final client = RecordingHttpClient(
      body: jsonEncode({
        'data': [
          {
            'index': 1,
            'embedding': [3, 4],
          },
          {
            'index': 0,
            'embedding': [1, 2],
          },
        ],
      }),
    );
    final provider = HttpEmbeddingProvider(
      endpoint: Uri.parse('https://embeddings.example/v1/embeddings'),
      model: 'embeddinggemma-looking-name',
      apiKey: 'bearer-secret',
      checkNetworkAccess: (uri) async {
        expect(uri.toString(), 'https://embeddings.example/v1/embeddings');
        client.events.add('policy');
      },
      httpClientFactory: () => client,
    );

    expect(await provider.embedDocuments(const ['raw query-shaped input', 'raw document']), [
      [1, 2],
      [3, 4],
    ]);
    expect(client.events, ['policy', 'open', 'close']);
    final request = client.requests.single;
    expect(request.method, 'POST');
    expect(request.followRedirects, isFalse);
    expect(request.recordedHeaders.values[HttpHeaders.authorizationHeader], 'Bearer bearer-secret');
    final body = jsonDecode(utf8.decode(request.bodyBytes)) as Map<String, dynamic>;
    expect(body['model'], 'embeddinggemma-looking-name');
    expect(body['input'], ['raw query-shaped input', 'raw document']);
    expect(utf8.decode(request.bodyBytes), isNot(contains('task: search result')));
    expect(utf8.decode(request.bodyBytes), isNot(contains('title: none')));
  });

  test('query uses one raw indexed input and policy runs before every request', () async {
    final client = RecordingHttpClient(
      body: jsonEncode({
        'data': [
          {
            'index': 0,
            'embedding': [1],
          },
        ],
      }),
    );
    var policyChecks = 0;
    final provider = HttpEmbeddingProvider(
      endpoint: Uri.parse('https://example.com/embeddings'),
      model: 'model',
      checkNetworkAccess: (_) async => policyChecks++,
      httpClientFactory: () => client,
    );

    expect(await provider.embedQuery('exact query'), [1]);
    expect(await provider.embedQuery('second query'), [1]);
    expect(policyChecks, 2);
    expect(client.requests, hasLength(2));
    expect((jsonDecode(utf8.decode(client.requests.first.bodyBytes)) as Map)['input'], ['exact query']);
  });

  test('rejects unsafe endpoint shapes before policy or request without echoing them', () {
    final unsafe = [
      'https://user:password@example.com/embeddings',
      'https://example.com/embeddings?api_key=query-secret',
      'https://example.com/embeddings#token-fragment',
      'file:///tmp/model',
      '/relative/embeddings',
    ];
    for (final raw in unsafe) {
      var policyChecks = 0;
      final client = RecordingHttpClient();
      expect(
        () => HttpEmbeddingProvider(
          endpoint: Uri.parse(raw),
          model: 'model',
          checkNetworkAccess: (_) async => policyChecks++,
          httpClientFactory: () => client,
        ),
        throwsA(
          predicate<Object>(
            (error) =>
                !error.toString().contains(raw) &&
                !error.toString().contains('password') &&
                !error.toString().contains('query-secret') &&
                !error.toString().contains('token-fragment'),
          ),
        ),
      );
      expect(policyChecks, 0);
      expect(client.requests, isEmpty);
    }
  });

  test('bearer credential requires HTTPS except for literal loopback hosts', () {
    Future<void> allow(Uri _) async {}
    expect(
      () => HttpEmbeddingProvider(
        endpoint: Uri.parse('https://example.com/embeddings'),
        model: 'model',
        apiKey: '',
        checkNetworkAccess: allow,
      ),
      throwsA(containsMessage('apiKey must not be empty')),
    );
    expect(
      () => HttpEmbeddingProvider(
        endpoint: Uri.parse('http://example.com/embeddings'),
        model: 'model',
        apiKey: 'secret',
        checkNetworkAccess: allow,
      ),
      throwsA(predicate<Object>((error) => !error.toString().contains('secret'))),
    );
    for (final endpoint in ['http://localhost/embeddings', 'http://127.0.0.1/embeddings', 'http://[::1]/embeddings']) {
      expect(
        HttpEmbeddingProvider(
          endpoint: Uri.parse(endpoint),
          model: 'model',
          apiKey: 'secret',
          checkNetworkAccess: allow,
        ).modelFingerprint,
        matches(RegExp(r'^[0-9a-f]{64}$')),
      );
    }
  });

  test('redirect and non-success failures expose safe context but no response body', () async {
    for (final entry in [(302, 'redirect-secret'), (503, 'upstream bearer-secret raw-content')]) {
      final client = RecordingHttpClient(statusCode: entry.$1, body: entry.$2);
      final provider = HttpEmbeddingProvider(
        endpoint: Uri.parse('https://safe.example/embeddings'),
        model: 'model',
        apiKey: 'bearer-secret',
        checkNetworkAccess: (_) async {},
        httpClientFactory: () => client,
      );
      await expectLater(
        provider.embedQuery('raw-content'),
        throwsA(
          predicate<Object>(
            (error) =>
                error.toString().contains('safe.example') &&
                !error.toString().contains(entry.$2) &&
                !error.toString().contains('bearer-secret') &&
                !error.toString().contains('raw-content'),
          ),
        ),
      );
    }
  });

  test('transport and network-policy exceptions are sanitized', () async {
    final client = RecordingHttpClient(openError: StateError('bearer-secret raw-content response-secret'));
    final provider = HttpEmbeddingProvider(
      endpoint: Uri.parse('https://safe.example/embeddings'),
      model: 'model',
      apiKey: 'bearer-secret',
      checkNetworkAccess: (_) async {},
      httpClientFactory: () => client,
    );
    await expectLater(provider.embedQuery('raw-content'), throwsA(isSanitized));

    final denied = HttpEmbeddingProvider(
      endpoint: Uri.parse('https://safe.example/embeddings'),
      model: 'model',
      apiKey: 'bearer-secret',
      checkNetworkAccess: (_) async => throw StateError('bearer-secret raw-content'),
      httpClientFactory: () => RecordingHttpClient(),
    );
    await expectLater(denied.embedQuery('raw-content'), throwsA(isSanitized));
  });

  test('rejects malformed JSON, bad indices, cardinality and vector shape without partial results', () async {
    final bodies = [
      'not-json bearer-secret raw-content',
      '{}',
      '{"data":[{"embedding":[1]}]}',
      '{"data":[{"index":0,"embedding":[1]},{"index":0,"embedding":[2]}]}',
      '{"data":[{"index":2,"embedding":[1]}]}',
      '{"data":[{"index":0,"embedding":[]}]}',
      '{"data":[{"index":0,"embedding":[1e999]}]}',
      '{"data":[{"index":0,"embedding":[1]},{"index":1,"embedding":[1,2]}]}',
    ];
    for (final body in bodies) {
      final client = RecordingHttpClient(body: body);
      final provider = HttpEmbeddingProvider(
        endpoint: Uri.parse('https://safe.example/embeddings'),
        model: 'model',
        apiKey: 'bearer-secret',
        checkNetworkAccess: (_) async {},
        httpClientFactory: () => client,
      );
      await expectLater(provider.embedDocuments(const ['raw-content', 'second']), throwsA(isSanitized));
    }
  });

  test('response timeout is bounded and sanitized', () async {
    final controller = StreamController<List<int>>();
    final client = RecordingHttpClient()..responseStream = controller.stream;
    final provider = HttpEmbeddingProvider(
      endpoint: Uri.parse('https://safe.example/embeddings'),
      model: 'model',
      checkNetworkAccess: (_) async {},
      requestTimeout: const Duration(milliseconds: 20),
      httpClientFactory: () => client,
    );

    await expectLater(provider.embedQuery('raw-content'), throwsA(isSanitized));
    await controller.close();
  });

  test('response bytes are capped before JSON decoding', () async {
    final client = RecordingHttpClient(chunks: [List.filled(8 * 1024 * 1024 + 1, 0x20)]);
    final provider = HttpEmbeddingProvider(
      endpoint: Uri.parse('https://safe.example/embeddings'),
      model: 'model',
      checkNetworkAccess: (_) async {},
      httpClientFactory: () => client,
    );

    await expectLater(provider.embedQuery('raw-content'), throwsA(containsMessage('size limit')));
    expect(client.forceClosed, isTrue);
  });

  test('malformed response cannot retain a partial embedding dimension', () async {
    final client = RecordingHttpClient(body: '{"data":[{"index":0,"embedding":[1]}]}');
    final provider = HttpEmbeddingProvider(
      endpoint: Uri.parse('https://safe.example/embeddings'),
      model: 'model',
      checkNetworkAccess: (_) async {},
      httpClientFactory: () => client,
    );

    await expectLater(
      provider.embedDocuments(const ['first', 'second']),
      throwsA(containsMessage('wrong result count')),
    );
    client.responseChunks = [utf8.encode('{"data":[{"index":0,"embedding":[1,2]}]}')];
    expect(await provider.embedQuery('later'), [1, 2]);
  });

  test('empty document batch avoids I/O and disposal is terminal', () async {
    var policyChecks = 0;
    final client = RecordingHttpClient();
    final provider = HttpEmbeddingProvider(
      endpoint: Uri.parse('https://safe.example/embeddings'),
      model: 'model',
      checkNetworkAccess: (_) async => policyChecks++,
      httpClientFactory: () => client,
    );

    expect(await provider.embedDocuments(const []), isEmpty);
    expect(policyChecks, 0);
    await provider.dispose();
    await expectLater(provider.embedQuery('query'), throwsA(containsMessage('disposed')));
    await expectLater(provider.embedDocuments(const []), throwsA(containsMessage('disposed')));
  });
}

final Matcher isSanitized = predicate<Object>(
  (error) =>
      !error.toString().contains('bearer-secret') &&
      !error.toString().contains('raw-content') &&
      !error.toString().contains('response-secret'),
  'contains no credential, request content or response content',
);

Matcher containsMessage(String text) => predicate<Object>((error) => error.toString().contains(text));
