import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

typedef NativeArtifactHttpClientFactory = HttpClient Function();

final class NativeArtifact {
  const new({
    required this.target,
    required this.bundle,
    required this.archive,
    required this.url,
    required this.size,
    required this.sha256,
  });

  final String target;
  final String bundle;
  final String archive;
  final Uri url;
  final int size;
  final String sha256;
}

final class VerifiedArtifact {
  const new({required this.basename, required this.url, required this.size, required this.sha256});

  final String basename;
  final Uri url;
  final int size;
  final String sha256;
}

final class NativeArtifactManifest {
  const new({required this.release, required this.repository, required this.model, required this.artifacts});

  static final _sha256Pattern = RegExp(r'^[0-9a-f]{64}$');
  static final _targetPattern = RegExp(r'^(?:linux|macos|windows)-(?:arm64|x64)$');

  final String release;
  final Uri repository;
  final VerifiedArtifact model;
  final Map<String, NativeArtifact> artifacts;

  static Future<NativeArtifactManifest> load(String path) async {
    Object? decoded;
    try {
      decoded = jsonDecode(await File(path).readAsString());
    } catch (_) {
      throw const FormatException('Native artifact manifest is not valid JSON');
    }
    if (decoded is! Map<String, Object?>) throw const FormatException('Native artifact manifest must be an object');
    final release = decoded['release'];
    final repository = decoded['repository'];
    final rawModel = decoded['model'];
    final rawArtifacts = decoded['artifacts'];
    if (release is! String || !RegExp(r'^v\d+\.\d+\.\d+$').hasMatch(release)) {
      throw const FormatException('Native artifact manifest has an invalid release');
    }
    final repositoryUri = repository is String ? Uri.tryParse(repository) : null;
    if (repositoryUri == null || repositoryUri.scheme != 'https' || repositoryUri.host.isEmpty) {
      throw const FormatException('Native artifact manifest has an invalid repository');
    }
    if (rawArtifacts is! Map<String, Object?> || rawArtifacts.isEmpty) {
      throw const FormatException('Native artifact manifest has no artifacts');
    }
    if (rawModel is! Map<String, Object?>) throw const FormatException('Native artifact manifest has no model');
    final modelBasename = rawModel['basename'];
    final rawModelUrl = rawModel['url'];
    final modelSize = rawModel['size'];
    final modelSha256 = rawModel['sha256'];
    final modelUrl = rawModelUrl is String ? Uri.tryParse(rawModelUrl) : null;
    if (modelBasename is! String ||
        modelBasename.isEmpty ||
        modelUrl == null ||
        modelUrl.scheme != 'https' ||
        modelUrl.host.isEmpty ||
        modelUrl.pathSegments.lastOrNull != modelBasename ||
        modelSize is! int ||
        modelSize <= 0 ||
        modelSha256 is! String ||
        !_sha256Pattern.hasMatch(modelSha256)) {
      throw const FormatException('Native artifact manifest has invalid model metadata');
    }
    final model = VerifiedArtifact(basename: modelBasename, url: modelUrl, size: modelSize, sha256: modelSha256);

    final artifacts = <String, NativeArtifact>{};
    for (final entry in rawArtifacts.entries) {
      final target = entry.key;
      final value = entry.value;
      if (!_targetPattern.hasMatch(target) || value is! Map<String, Object?>) {
        throw FormatException('Native artifact manifest has an invalid target: $target');
      }
      final bundle = value['bundle'];
      final archive = value['archive'];
      final rawUrl = value['url'];
      final size = value['size'];
      final rawSha256 = value['sha256'];
      final url = rawUrl is String ? Uri.tryParse(rawUrl) : null;
      if (bundle is! String || bundle.isEmpty || bundle.contains('/') || bundle.contains('\\')) {
        throw FormatException('Native artifact manifest has an invalid bundle for $target');
      }
      if (archive is! String || archive != 'llamadart-native-$bundle-$release.tar.gz') {
        throw FormatException('Native artifact manifest has an invalid archive for $target');
      }
      if (url == null || url.scheme != 'https' || url.host.isEmpty || url.pathSegments.lastOrNull != archive) {
        throw FormatException('Native artifact manifest has an invalid URL for $target');
      }
      if (size is! int || size <= 0) throw FormatException('Native artifact manifest has an invalid size for $target');
      if (rawSha256 is! String || !_sha256Pattern.hasMatch(rawSha256)) {
        throw FormatException('Native artifact manifest has an invalid SHA-256 for $target');
      }
      artifacts[target] = NativeArtifact(
        target: target,
        bundle: bundle,
        archive: archive,
        url: url,
        size: size,
        sha256: rawSha256,
      );
    }
    return NativeArtifactManifest(
      release: release,
      repository: repositoryUri,
      model: model,
      artifacts: Map.unmodifiable(artifacts),
    );
  }

  NativeArtifact forTarget(String target) {
    final artifact = artifacts[target];
    if (artifact == null) throw ArgumentError.value(target, 'target', 'Unknown native release target');
    return artifact;
  }
}

final class NativeArtifactPreparation {
  const new({required this.artifact, required this.hookRoot, required this.stagedArchive});

  final NativeArtifact artifact;
  final String hookRoot;
  final String stagedArchive;
}

final class NativeArtifactPreparer {
  new({NativeArtifactHttpClientFactory? httpClientFactory}) : _httpClientFactory = httpClientFactory ?? HttpClient.new;

  static const _maxRedirects = 5;
  static const _networkTimeout = Duration(seconds: 60);
  final NativeArtifactHttpClientFactory _httpClientFactory;

  Future<void> acquireVerified({required VerifiedArtifact artifact, required String destinationPath}) async {
    final file = File(destinationPath);
    final nativeArtifact = NativeArtifact(
      target: 'verified-file',
      bundle: 'verified-file',
      archive: artifact.basename,
      url: artifact.url,
      size: artifact.size,
      sha256: artifact.sha256,
    );
    if (await file.exists()) {
      await _verify(file, nativeArtifact, context: 'Cached verified artifact');
      return;
    }
    await file.parent.create(recursive: true);
    await _download(file, nativeArtifact);
  }

  Future<NativeArtifactPreparation> prepare({
    required NativeArtifactManifest manifest,
    required String target,
    required String cacheDirectory,
    required String stageParent,
    required bool allowDownload,
  }) async {
    final artifact = manifest.forTarget(target);
    if (cacheDirectory.isEmpty) throw ArgumentError('cacheDirectory must not be empty');
    if (stageParent.isEmpty) throw ArgumentError('stageParent must not be empty');
    final cache = Directory(cacheDirectory);
    await cache.create(recursive: true);
    final cached = File(_join(cache.path, artifact.archive));

    if (await cached.exists()) {
      await _verify(cached, artifact, context: 'Cached native archive');
    } else {
      if (!allowDownload) {
        throw StateError('Missing native archive ${artifact.archive}; expected ${artifact.sha256} in ${cache.path}');
      }
      await _download(cached, artifact);
    }

    final stage = await Directory(stageParent).createTemp('dartclaw-native-hook-');
    try {
      final bundleDirectory = Directory(_joinAll(stage.path, [manifest.release, artifact.bundle]));
      await bundleDirectory.create(recursive: true);
      final staged = File(_join(bundleDirectory.path, artifact.archive));
      await cached.copy(staged.path);
      await _verify(staged, artifact, context: 'Staged native archive');
      return NativeArtifactPreparation(artifact: artifact, hookRoot: stage.path, stagedArchive: staged.path);
    } catch (_) {
      try {
        await stage.delete(recursive: true);
      } catch (_) {}
      rethrow;
    }
  }

  Future<void> _download(File destination, NativeArtifact artifact) async {
    final temporary = File('${destination.path}.download-$pid-${DateTime.now().microsecondsSinceEpoch}');
    HttpClient? client;
    IOSink? sink;
    var published = false;
    try {
      client = _httpClientFactory()..connectionTimeout = _networkTimeout;
      final request = await client.getUrl(artifact.url).timeout(_networkTimeout);
      request
        ..followRedirects = true
        ..maxRedirects = _maxRedirects;
      final response = await request.close().timeout(_networkTimeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw StateError('Native archive download failed with status ${response.statusCode}');
      }
      await temporary.create(exclusive: true);
      sink = temporary.openWrite();
      var received = 0;
      await for (final chunk in response.timeout(_networkTimeout)) {
        received += chunk.length;
        if (received > artifact.size) throw StateError('Downloaded native archive has the wrong size');
        sink.add(chunk);
      }
      await sink.close();
      sink = null;
      await _verify(temporary, artifact, context: 'Downloaded native archive');
      if (await destination.exists()) {
        await _verify(destination, artifact, context: 'Concurrent cached native archive');
        await temporary.delete();
      } else {
        await temporary.rename(destination.path);
      }
      published = true;
    } on TimeoutException {
      throw StateError('Native archive download timed out');
    } finally {
      client?.close(force: true);
      if (sink != null) {
        try {
          await sink.close();
        } catch (_) {}
      }
      if (!published) {
        try {
          if (await temporary.exists()) await temporary.delete();
        } catch (_) {}
      }
    }
  }

  Future<void> _verify(File file, NativeArtifact artifact, {required String context}) async {
    final stat = await file.stat();
    if (stat.type != FileSystemEntityType.file || stat.size != artifact.size) {
      throw StateError('$context ${artifact.archive} has the wrong size; expected ${artifact.size} bytes');
    }
    final actual = (await sha256.bind(file.openRead()).first).toString();
    if (actual != artifact.sha256) {
      throw StateError('$context ${artifact.archive} failed SHA-256 verification; expected ${artifact.sha256}');
    }
  }
}

String _join(String first, String second) => '$first${Platform.pathSeparator}$second';

String _joinAll(String first, Iterable<String> rest) => rest.fold(first, _join);

extension on List<String> {
  String? get lastOrNull => isEmpty ? null : last;
}

Future<void> main(List<String> arguments) async {
  final options = _parseArguments(arguments);
  final manifest = await NativeArtifactManifest.load(options.manifest);
  final result = await NativeArtifactPreparer().prepare(
    manifest: manifest,
    target: options.target,
    cacheDirectory: options.cache,
    stageParent: options.stageParent,
    allowDownload: options.allowDownload,
  );
  if (arguments.contains('--hook-root-only')) {
    stdout.writeln(result.hookRoot);
  } else {
    stdout.writeln(
      jsonEncode({
        'target': result.artifact.target,
        'release': manifest.release,
        'archive': result.artifact.archive,
        'size': result.artifact.size,
        'sha256': result.artifact.sha256,
        'hookRoot': result.hookRoot,
        'stagedArchive': result.stagedArchive,
      }),
    );
  }
}

({String manifest, String target, String cache, String stageParent, bool allowDownload}) _parseArguments(
  List<String> arguments,
) {
  String? value(String name) {
    final index = arguments.indexOf(name);
    if (index < 0 || index + 1 >= arguments.length) return null;
    return arguments[index + 1];
  }

  final manifest = value('--manifest') ?? 'dev/native_artifacts.json';
  final target = value('--target');
  final cache = value('--cache');
  final stageParent = value('--stage-parent');
  if (target == null || cache == null || stageParent == null) {
    throw ArgumentError('Usage: native_artifact_preparation.dart --target <target> --cache <dir> --stage-parent <dir>');
  }
  return (
    manifest: manifest,
    target: target,
    cache: cache,
    stageParent: stageParent,
    allowDownload: arguments.contains('--allow-download'),
  );
}
