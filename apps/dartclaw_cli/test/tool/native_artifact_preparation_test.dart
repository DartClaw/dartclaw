import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../tool/native_artifact_preparation.dart';

void main() {
  late Directory root;
  late List<int> bytes;
  late String digest;

  setUp(() {
    root = Directory.systemTemp.createTempSync('dartclaw-native-prepare-test');
    bytes = utf8.encode('tiny deterministic native archive');
    digest = sha256.convert(bytes).toString();
  });

  tearDown(() => root.deleteSync(recursive: true));

  test('production manifest pins exactly the five shipped targets', () async {
    final manifest = await NativeArtifactManifest.load(p.join(_repoRoot(), 'dev', 'native_artifacts.json'));
    expect(
      manifest.artifacts.keys,
      unorderedEquals(['macos-arm64', 'macos-x64', 'linux-arm64', 'linux-x64', 'windows-x64']),
    );
    expect(manifest.forTarget('macos-x64').bundle, 'macos-x86_64');
    expect(manifest.release, 'v0.3.0');
  });

  test('verified cache bytes publish only into operation-unique stages', () async {
    final manifest = _manifest(bytes, digest);
    final cache = Directory(p.join(root.path, 'cache'))..createSync();
    File(p.join(cache.path, manifest.forTarget('linux-x64').archive)).writeAsBytesSync(bytes);
    final preparer = NativeArtifactPreparer();
    final first = await preparer.prepare(
      manifest: manifest,
      target: 'linux-x64',
      cacheDirectory: cache.path,
      stageParent: root.path,
      allowDownload: false,
    );
    final second = await preparer.prepare(
      manifest: manifest,
      target: 'linux-x64',
      cacheDirectory: cache.path,
      stageParent: root.path,
      allowDownload: false,
    );
    expect(first.hookRoot, isNot(second.hookRoot));
    expect(File(first.stagedArchive).readAsBytesSync(), bytes);
    expect(first.stagedArchive, contains(p.join('v0.3.0', 'linux-x64')));
  });

  test('missing, wrong-size, wrong-hash and unknown targets never publish a stage', () async {
    final manifest = _manifest(bytes, digest);
    final cache = Directory(p.join(root.path, 'cache'))..createSync();
    final preparer = NativeArtifactPreparer();
    Future<void> expectFailure(String target) async {
      final before = root.listSync().map((entry) => entry.path).toSet();
      await expectLater(
        preparer.prepare(
          manifest: manifest,
          target: target,
          cacheDirectory: cache.path,
          stageParent: root.path,
          allowDownload: false,
        ),
        throwsA(anything),
      );
      expect(root.listSync().map((entry) => entry.path).toSet(), before);
    }

    await expectFailure('linux-x64');
    final cached = File(p.join(cache.path, manifest.forTarget('linux-x64').archive));
    cached.writeAsBytesSync(bytes.sublist(1));
    await expectFailure('linux-x64');
    cached.writeAsBytesSync(List<int>.filled(bytes.length, 0));
    await expectFailure('linux-x64');
    await expectFailure('plan9-x64');
  });

  test('online archive and model preparation follow bounded redirects and reuse verified bytes', () async {
    var archiveRequests = 0;
    var modelRequests = 0;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) {
      if (request.uri.path.startsWith('/archive')) {
        archiveRequests++;
        if (request.uri.path != '/archive-bytes') {
          request.response
            ..statusCode = HttpStatus.found
            ..headers.set(
              HttpHeaders.locationHeader,
              request.uri.path == '/archive' ? '/archive-hop' : '/archive-bytes',
            );
          request.response.close();
          return;
        }
      } else if (request.uri.path.startsWith('/model')) {
        modelRequests++;
        if (request.uri.path != '/model-bytes') {
          request.response
            ..statusCode = HttpStatus.temporaryRedirect
            ..headers.set(HttpHeaders.locationHeader, '/model-bytes');
          request.response.close();
          return;
        }
      }
      request.response.add(bytes);
      request.response.close();
    });
    final artifact = NativeArtifact(
      target: 'linux-x64',
      bundle: 'linux-x64',
      archive: 'llamadart-native-linux-x64-v0.3.0.tar.gz',
      url: Uri.parse('http://${server.address.host}:${server.port}/archive'),
      size: bytes.length,
      sha256: digest,
    );
    final manifest = NativeArtifactManifest(
      release: 'v0.3.0',
      repository: Uri.parse('https://example.test/native'),
      model: _model(bytes, digest),
      artifacts: {'linux-x64': artifact},
    );
    final cache = p.join(root.path, 'cache');
    final preparer = NativeArtifactPreparer();
    await preparer.prepare(
      manifest: manifest,
      target: 'linux-x64',
      cacheDirectory: cache,
      stageParent: root.path,
      allowDownload: true,
    );
    await preparer.prepare(
      manifest: manifest,
      target: 'linux-x64',
      cacheDirectory: cache,
      stageParent: root.path,
      allowDownload: false,
    );
    final modelPath = p.join(cache, 'tiny-model.gguf');
    final model = VerifiedArtifact(
      basename: 'tiny-model.gguf',
      url: Uri.parse('http://${server.address.host}:${server.port}/model'),
      size: bytes.length,
      sha256: digest,
    );
    await preparer.acquireVerified(artifact: model, destinationPath: modelPath);
    await preparer.acquireVerified(artifact: model, destinationPath: modelPath);
    expect(archiveRequests, 3);
    expect(modelRequests, 2);
    expect(File(p.join(cache, artifact.archive)).readAsBytesSync(), bytes);
    expect(File(modelPath).readAsBytesSync(), bytes);
    expect(root.listSync().whereType<File>().where((file) => file.path.contains('.download-')), isEmpty);
  });

  test('redirects beyond the limit publish neither cache entry nor temporary file', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) {
      final hop = int.tryParse(request.uri.pathSegments.last) ?? 0;
      request.response
        ..statusCode = HttpStatus.found
        ..headers.set(HttpHeaders.locationHeader, '/redirect/${hop + 1}')
        ..close();
    });
    final destination = p.join(root.path, 'cache', 'tiny-model.gguf');
    final model = VerifiedArtifact(
      basename: 'tiny-model.gguf',
      url: Uri.parse('http://${server.address.host}:${server.port}/redirect/0'),
      size: bytes.length,
      sha256: digest,
    );

    await expectLater(
      NativeArtifactPreparer().acquireVerified(artifact: model, destinationPath: destination),
      throwsA(isA<RedirectException>()),
    );
    expect(File(destination).existsSync(), isFalse);
    expect(Directory(p.dirname(destination)).listSync(), isEmpty);
  });

  test('failed online verification leaves neither cache entry nor temporary publication', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) {
      request.response.add(utf8.encode('bad'));
      request.response.close();
    });
    final manifest = _manifest(bytes, digest, url: Uri.parse('http://${server.address.host}:${server.port}/archive'));
    final cache = p.join(root.path, 'cache');
    await expectLater(
      NativeArtifactPreparer().prepare(
        manifest: manifest,
        target: 'linux-x64',
        cacheDirectory: cache,
        stageParent: root.path,
        allowDownload: true,
      ),
      throwsStateError,
    );
    expect(Directory(cache).listSync(), isEmpty);
    expect(
      root.listSync().whereType<Directory>().where(
        (directory) => p.basename(directory.path).startsWith('dartclaw-native-hook-'),
      ),
      isEmpty,
    );
  });
}

NativeArtifactManifest _manifest(List<int> bytes, String digest, {Uri? url}) {
  const archive = 'llamadart-native-linux-x64-v0.3.0.tar.gz';
  return NativeArtifactManifest(
    release: 'v0.3.0',
    repository: Uri.parse('https://example.test/native'),
    model: _model(bytes, digest),
    artifacts: {
      'linux-x64': NativeArtifact(
        target: 'linux-x64',
        bundle: 'linux-x64',
        archive: archive,
        url: url ?? Uri.parse('https://example.test/$archive'),
        size: bytes.length,
        sha256: digest,
      ),
    },
  );
}

VerifiedArtifact _model(List<int> bytes, String digest) => VerifiedArtifact(
  basename: 'tiny-model.gguf',
  url: Uri.parse('https://example.test/tiny-model.gguf'),
  size: bytes.length,
  sha256: digest,
);

String _repoRoot() {
  var current = Directory.current.absolute.path;
  while (!File(p.join(current, 'dev', 'native_artifacts.json')).existsSync()) {
    final parent = p.dirname(current);
    if (parent == current) throw StateError('Repository root not found');
    current = parent;
  }
  return current;
}
