import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dartclaw_search/dartclaw_search.dart';
import 'package:dartclaw_search/src/embedding_providers.dart' show createNativeEmbeddingProviderForTesting;
import 'package:test/test.dart';

void main() {
  late Directory temporaryDirectory;
  late File model;
  late String modelSha256;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp('dartclaw_native_provider_');
    model = File('${temporaryDirectory.path}/model.gguf');
    await model.writeAsBytes([1, 2, 3, 4]);
    modelSha256 = sha256.convert([1, 2, 3, 4]).toString();
  });

  tearDown(() async {
    if (await temporaryDirectory.exists()) await temporaryDirectory.delete(recursive: true);
  });

  NativeEmbeddingProvider createProvider({
    Future<void> Function(String path)? loadModel,
    Future<List<double>> Function(String input)? embed,
    Future<List<List<double>>> Function(List<String> inputs)? embedBatch,
    Future<void> Function()? dispose,
    Duration initializationTimeout = const Duration(seconds: 1),
    Duration shutdownTimeout = const Duration(seconds: 1),
  }) => createNativeEmbeddingProviderForTesting(
    modelPath: model.path,
    expectedSha256: modelSha256,
    loadModel: loadModel ?? (_) async {},
    embed: embed ?? (_) async => [1, 2],
    embedBatch:
        embedBatch ??
        (inputs) async => [
          for (final _ in inputs) [1, 2],
        ],
    disposeEngine: dispose ?? () async {},
    initializationTimeout: initializationTimeout,
    shutdownTimeout: shutdownTimeout,
  );

  test('construction and an empty document batch perform no file or engine I/O', () async {
    var loads = 0;
    final provider = createNativeEmbeddingProviderForTesting(
      modelPath: '${temporaryDirectory.path}/absent.gguf',
      expectedSha256: modelSha256,
      loadModel: (_) async => loads++,
      embed: (_) async => [1],
      embedBatch: (_) async => const [],
      disposeEngine: () async {},
    );

    expect(provider.modelFingerprint, matches(RegExp(r'^[0-9a-f]{64}$')));
    expect(await provider.embedDocuments(const []), isEmpty);
    expect(loads, 0);
  });

  test('concurrent first calls share one verified load and use exact prefixes', () async {
    final loading = Completer<void>();
    final loadStarted = Completer<void>();
    var loads = 0;
    final received = <String>[];
    final provider = createProvider(
      loadModel: (_) {
        loads++;
        loadStarted.complete();
        return loading.future;
      },
      embed: (input) async {
        received.add(input);
        return [1, 2];
      },
    );

    final first = provider.embedQuery('first');
    final second = provider.embedQuery('second');
    await loadStarted.future;
    expect(loads, 1);
    loading.complete();

    expect(await first, [1, 2]);
    expect(await second, [1, 2]);
    expect(received, ['task: search result | query: first', 'task: search result | query: second']);
  });

  test('document batch preserves order and applies the frozen document prefix', () async {
    List<String>? received;
    final provider = createProvider(
      embedBatch: (inputs) async {
        received = inputs;
        return [
          [1, 2],
          [3, 4],
        ];
      },
    );

    expect(await provider.embedDocuments(const ['alpha', 'beta']), [
      [1, 2],
      [3, 4],
    ]);
    expect(received, ['title: none | text: alpha', 'title: none | text: beta']);
  });

  test('ordinary initialization failure is cleared for a later explicit retry', () async {
    var loads = 0;
    var disposals = 0;
    final provider = createProvider(
      loadModel: (_) async {
        loads++;
        if (loads == 1) throw StateError('model unavailable at ${model.path}');
      },
      dispose: () async => disposals++,
    );

    await expectLater(provider.embedQuery('first'), throwsA(hasSafeMessage('Native embedding initialization failed')));
    expect(await provider.embedQuery('second'), [1, 2]);
    expect(loads, 2);
    expect(disposals, 1);
  });

  test('model verification failure performs no load and recovers after bytes appear', () async {
    await model.writeAsBytes([9]);
    var loads = 0;
    final provider = createProvider(loadModel: (_) async => loads++);

    await expectLater(provider.embedQuery('first'), throwsA(hasSafeMessage('verification failed')));
    expect(loads, 0);

    await model.writeAsBytes([1, 2, 3, 4]);
    expect(await provider.embedQuery('second'), [1, 2]);
    expect(loads, 1);
  });

  test('initialization timeout poisons the provider and late load is disposed', () async {
    final loading = Completer<void>();
    var loads = 0;
    var disposals = 0;
    final provider = createProvider(
      loadModel: (_) {
        loads++;
        return loading.future;
      },
      dispose: () async => disposals++,
      initializationTimeout: const Duration(milliseconds: 20),
    );

    await expectLater(provider.embedQuery('first'), throwsA(hasSafeMessage('initialization timed out')));
    await expectLater(provider.embedQuery('second'), throwsA(hasSafeMessage('must be reconstructed')));
    expect(loads, 1);

    loading.complete();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(disposals, 1);
  });

  test('shutdown owns one disposal while concurrent queries await initialization', () async {
    final loading = Completer<void>();
    final loadStarted = Completer<void>();
    var embeds = 0;
    var disposals = 0;
    final provider = createProvider(
      loadModel: (_) {
        loadStarted.complete();
        return loading.future;
      },
      embed: (_) async {
        embeds++;
        return [1, 2];
      },
      dispose: () async => disposals++,
    );

    final first = provider.embedQuery('first');
    final second = provider.embedQuery('second');
    final firstFailure = expectLater(first, throwsA(hasSafeMessage('provider is disposed')));
    final secondFailure = expectLater(second, throwsA(hasSafeMessage('provider is disposed')));
    await loadStarted.future;
    final shutdown = provider.dispose();
    loading.complete();

    await Future.wait([shutdown, firstFailure, secondFailure]);
    expect(embeds, 0);
    expect(disposals, 1);
    await provider.dispose();
    expect(disposals, 1);
  });

  test('dispose is terminal and reports a sanitized bounded timeout', () async {
    final disposal = Completer<void>();
    final provider = createProvider(dispose: () => disposal.future, shutdownTimeout: const Duration(milliseconds: 20));
    expect(await provider.embedQuery('query'), [1, 2]);

    await expectLater(provider.dispose(), throwsA(hasSafeMessage('shutdown timed out')));
    await expectLater(provider.embedQuery('later'), throwsA(hasSafeMessage('provider is disposed')));
    disposal.complete();
  });

  test('provider edge rejects wrong count, empty, non-finite and changed dimensions', () async {
    final wrongCount = createProvider(embedBatch: (_) async => const []);
    await expectLater(wrongCount.embedDocuments(const ['one']), throwsA(hasSafeMessage('wrong result count')));

    final empty = createProvider(embed: (_) async => const []);
    await expectLater(empty.embedQuery('query'), throwsA(hasSafeMessage('invalid embedding')));

    final nonFinite = createProvider(embed: (_) async => [double.nan]);
    await expectLater(nonFinite.embedQuery('query'), throwsA(hasSafeMessage('invalid embedding')));

    final changedDimension = createProvider(
      embed: (_) async => [1, 2],
      embedBatch: (_) async => const [
        [1],
      ],
    );
    expect(await changedDimension.embedQuery('query'), [1, 2]);
    await expectLater(
      changedDimension.embedDocuments(const ['document']),
      throwsA(hasSafeMessage('inconsistent embedding dimensions')),
    );

    final noPartialDimension = createProvider(
      embed: (_) async => [5, 6],
      embedBatch: (_) async => const [
        [1],
        [2, 3],
      ],
    );
    await expectLater(
      noPartialDimension.embedDocuments(const ['first', 'second']),
      throwsA(hasSafeMessage('inconsistent embedding dimensions')),
    );
    expect(await noPartialDimension.embedQuery('valid later call'), [5, 6]);
  });
}

Matcher hasSafeMessage(String text) => predicate<Object>(
  (error) => error.toString().contains(text) && !error.toString().contains('dartclaw_native_provider_'),
  'has sanitized message containing "$text"',
);
