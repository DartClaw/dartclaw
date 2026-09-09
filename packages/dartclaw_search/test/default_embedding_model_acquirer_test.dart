import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dartclaw_search/dartclaw_search.dart';
import 'package:dartclaw_search/src/default_embedding_model_acquirer.dart'
    show createDefaultEmbeddingModelAcquirerForTesting;
import 'package:test/test.dart';

import 'support/fake_http_client.dart';

void main() {
  late Directory temporaryDirectory;
  late File destination;
  late List<int> expectedBytes;
  late String expectedSha256;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp('dartclaw_model_acquirer_');
    destination = File('${temporaryDirectory.path}/model.gguf');
    expectedBytes = utf8.encode('verified model bytes');
    expectedSha256 = sha256.convert(expectedBytes).toString();
  });

  tearDown(() async {
    if (await temporaryDirectory.exists()) await temporaryDirectory.delete(recursive: true);
  });

  DefaultEmbeddingModelAcquirer createAcquirer({
    required RecordingHttpClient client,
    required Future<void> Function(Uri uri) checkNetworkAccess,
    int? expectedSize,
    String? expectedDigest,
  }) => createDefaultEmbeddingModelAcquirerForTesting(
    checkNetworkAccess: checkNetworkAccess,
    httpClientFactory: () => client,
    source: Uri.parse('https://models.example/default.gguf'),
    expectedSize: expectedSize ?? expectedBytes.length,
    expectedSha256: expectedDigest ?? expectedSha256,
  );

  Future<List<String>> downloadTemporaries() async => [
    await for (final entity in temporaryDirectory.list())
      if (entity is File && entity.path.contains('.download-')) entity.path,
  ];

  test('exports the exact frozen default model metadata', () {
    expect(DefaultEmbeddingModel.filename, 'embeddinggemma-300M-Q8_0.gguf');
    expect(DefaultEmbeddingModel.byteSize, 333590944);
    expect(DefaultEmbeddingModel.sha256, 'b5ce9d77a3fc4b3b39ccb5643c36777911cc4eb46a66962eadfa3f5f60490d63');
    expect(DefaultEmbeddingModel.sourceUrl, contains('/resolve/0f741b5a6585bd53aeb15cd1372c56f2a0f65e12/'));
    expect(DefaultEmbeddingModel.licenseName, 'Gemma Terms of Use');
    expect(DefaultEmbeddingModel.licenseUrl, 'https://ai.google.dev/gemma/terms');
  });

  test('reuses verified destination without policy check or request', () async {
    await destination.writeAsBytes(expectedBytes);
    var policyChecks = 0;
    final client = RecordingHttpClient(body: 'unused');
    final acquirer = createAcquirer(client: client, checkNetworkAccess: (_) async => policyChecks++);

    final result = await acquirer.acquire(destinationPath: destination.path);

    expect(result.path, destination.path);
    expect(result.status, ModelAcquisitionStatus.reused);
    expect(policyChecks, 0);
    expect(client.requests, isEmpty);
  });

  test('checks policy before request, streams, verifies and atomically publishes', () async {
    final client = RecordingHttpClient(chunks: [expectedBytes.sublist(0, 5), expectedBytes.sublist(5)]);
    final acquirer = createAcquirer(
      client: client,
      checkNetworkAccess: (uri) async {
        expect(uri.toString(), 'https://models.example/default.gguf');
        client.events.add('policy');
      },
    );

    final result = await acquirer.acquire(destinationPath: destination.path);

    expect(result.status, ModelAcquisitionStatus.downloaded);
    expect(await destination.readAsBytes(), expectedBytes);
    expect(client.events, ['policy', 'open', 'close']);
    expect(client.requests.single.method, 'GET');
    expect(client.requests.single.followRedirects, isFalse);
    expect(await downloadTemporaries(), isEmpty);
  });

  test('checks policy before every request and follows a validated signed HTTPS redirect', () async {
    final client = RecordingHttpClient(
      responses: [
        const RecordingHttpResponseSpec(
          statusCode: 302,
          location: 'https://cdn.example/artifact.gguf?signature=redirect-secret',
        ),
        RecordingHttpResponseSpec(statusCode: 200, chunks: [expectedBytes]),
      ],
    );
    final policyHosts = <String>[];
    final acquirer = createAcquirer(
      client: client,
      checkNetworkAccess: (uri) async {
        policyHosts.add(uri.host);
        client.events.add('policy:${uri.host}');
      },
    );

    final result = await acquirer.acquire(destinationPath: destination.path);

    expect(result.status, ModelAcquisitionStatus.downloaded);
    expect(policyHosts, ['models.example', 'cdn.example']);
    expect(client.requests.map((request) => request.uri.host), ['models.example', 'cdn.example']);
    expect(client.requests.every((request) => !request.followRedirects), isTrue);
    expect(client.events, ['policy:models.example', 'open', 'close', 'policy:cdn.example', 'open', 'close']);
    expect(await destination.readAsBytes(), expectedBytes);
  });

  test('a denied redirect target is checked but never requested', () async {
    final client = RecordingHttpClient(
      responses: [
        const RecordingHttpResponseSpec(
          statusCode: 302,
          location: 'https://denied.example/artifact.gguf?signature=redirect-secret',
        ),
      ],
    );
    final policyHosts = <String>[];
    final acquirer = createAcquirer(
      client: client,
      checkNetworkAccess: (uri) async {
        policyHosts.add(uri.host);
        if (uri.host == 'denied.example') throw StateError('credential=policy-secret');
      },
    );

    await expectLater(
      acquirer.acquire(destinationPath: destination.path),
      throwsA(
        predicate<Object>(
          (error) => !error.toString().contains('policy-secret') && !error.toString().contains('redirect-secret'),
        ),
      ),
    );
    expect(policyHosts, ['models.example', 'denied.example']);
    expect(client.requests.map((request) => request.uri.host), ['models.example']);
    expect(await downloadTemporaries(), isEmpty);
  });

  test('missing and unsafe redirect targets fail without requesting the target or exposing it', () async {
    for (final location in <String?>[
      null,
      'http://unsafe.example/artifact?signature=redirect-secret',
      'https://user:redirect-secret@unsafe.example/artifact',
      'https://unsafe.example/artifact#redirect-secret',
    ]) {
      final client = RecordingHttpClient(responses: [RecordingHttpResponseSpec(statusCode: 302, location: location)]);
      final acquirer = createAcquirer(client: client, checkNetworkAccess: (_) async {});

      await expectLater(
        acquirer.acquire(destinationPath: destination.path),
        throwsA(predicate<Object>((error) => !error.toString().contains('redirect-secret'))),
        reason: '$location',
      );
      expect(client.requests.length, 1, reason: '$location');
      expect(await downloadTemporaries(), isEmpty);
    }
  });

  test('a fourth redirect exhausts the limit without a fifth policy check or request', () async {
    final client = RecordingHttpClient(
      responses: [
        for (var index = 1; index <= 4; index++)
          RecordingHttpResponseSpec(statusCode: 302, location: '/hop-$index?signature=redirect-secret-$index'),
      ],
    );
    var policyChecks = 0;
    final acquirer = createAcquirer(client: client, checkNetworkAccess: (_) async => policyChecks++);

    await expectLater(
      acquirer.acquire(destinationPath: destination.path),
      throwsA(
        predicate<Object>(
          (error) => error.toString().contains('redirect') && !error.toString().contains('redirect-secret'),
        ),
      ),
    );
    expect(policyChecks, 4);
    expect(client.requests.length, 4);
    expect(client.requests.every((request) => !request.followRedirects), isTrue);
  });

  test('size and checksum remain mandatory after a redirect', () async {
    final previous = utf8.encode('previous bytes');
    final wrongChecksum = utf8.encode('different model bytes');
    final cases = [
      (
        client: RecordingHttpClient(
          responses: [
            const RecordingHttpResponseSpec(statusCode: 302, location: '/download'),
            RecordingHttpResponseSpec(statusCode: 200, chunks: [expectedBytes.sublist(0, expectedBytes.length - 1)]),
          ],
        ),
        expectedSize: expectedBytes.length,
      ),
      (
        client: RecordingHttpClient(
          responses: [
            const RecordingHttpResponseSpec(statusCode: 302, location: '/download'),
            RecordingHttpResponseSpec(statusCode: 200, chunks: [wrongChecksum]),
          ],
        ),
        expectedSize: wrongChecksum.length,
      ),
    ];

    for (final testCase in cases) {
      await destination.writeAsBytes(previous);
      final acquirer = createAcquirer(
        client: testCase.client,
        checkNetworkAccess: (_) async {},
        expectedSize: testCase.expectedSize,
      );
      await expectLater(acquirer.acquire(destinationPath: destination.path), throwsA(isA<Object>()));
      expect(await destination.readAsBytes(), previous);
      expect(testCase.client.requests.length, 2);
      expect(await downloadTemporaries(), isEmpty);
    }
  });

  test('policy denial preserves corrupt destination and creates no temporary', () async {
    final previous = utf8.encode('previous bytes');
    await destination.writeAsBytes(previous);
    final client = RecordingHttpClient(chunks: [expectedBytes]);
    final acquirer = createAcquirer(
      client: client,
      checkNetworkAccess: (_) async => throw StateError('credential=network-secret'),
    );

    await expectLater(
      acquirer.acquire(destinationPath: destination.path),
      throwsA(predicate<Object>((error) => !error.toString().contains('network-secret'))),
    );
    expect(await destination.readAsBytes(), previous);
    expect(client.requests, isEmpty);
    expect(await downloadTemporaries(), isEmpty);
  });

  test('redirect, interruption, wrong size and checksum preserve destination and clean only own temporary', () async {
    final previous = utf8.encode('previous bytes');
    final unrelated = File('${destination.path}.download-foreign')..writeAsStringSync('keep');
    final cases = <RecordingHttpClient>[
      RecordingHttpClient(statusCode: 302, body: 'redirect'),
      RecordingHttpClient()
        ..responseStream = Stream<List<int>>.multi((controller) {
          controller.add(expectedBytes.sublist(0, 4));
          controller.addError(StateError('interrupted credential=secret'));
        }),
      RecordingHttpClient(chunks: [expectedBytes.sublist(0, expectedBytes.length - 1)]),
      RecordingHttpClient(chunks: [utf8.encode('different model bytes')]),
    ];

    for (final client in cases) {
      await destination.writeAsBytes(previous);
      final acquirer = createAcquirer(
        client: client,
        checkNetworkAccess: (_) async {},
        expectedSize: client == cases.last ? utf8.encode('different model bytes').length : null,
      );
      await expectLater(
        acquirer.acquire(destinationPath: destination.path),
        throwsA(predicate<Object>((error) => !error.toString().contains('secret'))),
      );
      expect(await destination.readAsBytes(), previous);
      expect(await unrelated.readAsString(), 'keep');
      expect(await downloadTemporaries(), [unrelated.path]);
    }
  });
}
