import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:dartclaw_server/dartclaw_server.dart' show dartclawVersion;
import 'package:path/path.dart' as p;

typedef HttpClientFactory = HttpClient Function();

class AssetDownloadException implements Exception {
  final String message;

  const AssetDownloadException(this.message);

  @override
  String toString() => message;
}

/// Downloads and extracts the external DartClaw asset archive.
class AssetDownloader {
  final String version;
  final Uri releaseBaseUri;
  final String? homeDir;
  final HttpClientFactory _httpClientFactory;
  final void Function(String) _stderrLine;

  AssetDownloader({
    String? version,
    Uri? releaseBaseUri,
    this.homeDir,
    HttpClientFactory? httpClientFactory,
    void Function(String)? stderrLine,
  }) : version = version ?? dartclawVersion,
       releaseBaseUri =
           releaseBaseUri ??
           Uri.parse('https://github.com/DartClaw/dartclaw/releases/download/v${version ?? dartclawVersion}/'),
       _httpClientFactory = httpClientFactory ?? HttpClient.new,
       _stderrLine = stderrLine ?? stderr.writeln;

  Future<String> download() async {
    final installRoot = Directory(resolveInstallPath(homeDir: homeDir, version: version));
    final parentDir = installRoot.parent;
    parentDir.createSync(recursive: true);

    final checksumUri = _assetUri('dartclaw-assets-v$version.tar.gz.sha256');
    final archiveUri = _assetUri('dartclaw-assets-v$version.tar.gz');
    final checksumBody = await _downloadText(checksumUri, missingChecksumMessage: _missingChecksumMessage());
    final expectedHash = _parseChecksum(checksumBody);

    final archiveBytes = await _downloadBytes(archiveUri, announceProgress: true);
    final actualHash = sha256.convert(archiveBytes).toString();
    if (actualHash != expectedHash) {
      throw AssetDownloadException(
        'SHA256 checksum mismatch for v$version. Expected $expectedHash but got $actualHash.',
      );
    }

    final stagingRoot = Directory(
      p.join(parentDir.path, '.dartclaw-assets-v$version-${DateTime.now().microsecondsSinceEpoch}-$pid'),
    )..createSync(recursive: true);

    try {
      _extractArchive(archiveBytes, stagingRoot);
      if (installRoot.existsSync()) {
        installRoot.deleteSync(recursive: true);
      }
      stagingRoot.renameSync(installRoot.path);
    } catch (error) {
      if (stagingRoot.existsSync()) {
        stagingRoot.deleteSync(recursive: true);
      }
      if (error is AssetDownloadException) {
        rethrow;
      }
      throw AssetDownloadException(
        'Failed to install assets for v$version: $error. Verify the release archive at '
        'https://github.com/DartClaw/dartclaw/releases',
      );
    }

    return installRoot.path;
  }

  static String resolveInstallPath({String? homeDir, String? version}) {
    final resolvedHomeDir = _resolveHomeDir(homeDir: homeDir);
    if (resolvedHomeDir == null) {
      throw const AssetDownloadException('Unable to determine a home directory for asset installation.');
    }
    final resolvedVersion = version ?? dartclawVersion;
    return p.join(resolvedHomeDir, '.dartclaw', 'assets', 'v$resolvedVersion');
  }

  static String? _resolveHomeDir({String? homeDir}) {
    final override = homeDir?.trim();
    if (override != null && override.isNotEmpty) {
      return override;
    }

    final envHome = Platform.environment['HOME']?.trim();
    if (envHome != null && envHome.isNotEmpty) {
      return envHome;
    }

    final userProfile = Platform.environment['USERPROFILE']?.trim();
    if (userProfile != null && userProfile.isNotEmpty) {
      return userProfile;
    }

    return null;
  }

  Uri _assetUri(String filename) => releaseBaseUri.resolve(filename);

  Future<String> _downloadText(Uri uri, {required String missingChecksumMessage}) async {
    final bytes = await _downloadBytes(uri, announceProgress: false, missingMessageOverride: missingChecksumMessage);
    return utf8.decode(bytes);
  }

  Future<Uint8List> _downloadBytes(Uri uri, {required bool announceProgress, String? missingMessageOverride}) async {
    final client = _httpClientFactory();
    try {
      final request = await client.getUrl(uri);
      request.followRedirects = true;
      request.maxRedirects = 5;

      final response = await request.close();
      if (response.statusCode == HttpStatus.notFound && missingMessageOverride != null) {
        throw AssetDownloadException(missingMessageOverride);
      }
      if (response.statusCode != HttpStatus.ok) {
        throw AssetDownloadException(_downloadFailureMessage(response.statusCode));
      }

      if (announceProgress) {
        final size = response.contentLength >= 0 ? _formatBytes(response.contentLength) : 'unknown size';
        _stderrLine('Downloading assets for v$version ($size)...');
      }

      final builder = BytesBuilder(copy: false);
      await for (final chunk in response) {
        builder.add(chunk);
      }
      return builder.takeBytes();
    } on AssetDownloadException {
      rethrow;
    } on SocketException catch (error) {
      throw AssetDownloadException(
        'Failed to download assets for v$version: $error. Verify the version exists at '
        'https://github.com/DartClaw/dartclaw/releases',
      );
    } on HttpException catch (error) {
      throw AssetDownloadException(
        'Failed to download assets for v$version: $error. Verify the version exists at '
        'https://github.com/DartClaw/dartclaw/releases',
      );
    } catch (error) {
      throw AssetDownloadException(
        'Failed to download assets for v$version: $error. Verify the version exists at '
        'https://github.com/DartClaw/dartclaw/releases',
      );
    } finally {
      client.close(force: true);
    }
  }

  void _extractArchive(Uint8List archiveBytes, Directory targetRoot) {
    final tarBytes = GZipDecoder().decodeBytes(archiveBytes);
    final archive = TarDecoder().decodeBytes(tarBytes);

    for (final file in archive.files) {
      final normalizedEntryPath = p.normalize(file.name);
      if (p.isAbsolute(normalizedEntryPath)) {
        throw AssetDownloadException('Refusing to extract archive entry outside the staging root: ${file.name}');
      }

      final targetPath = p.normalize(p.join(targetRoot.path, normalizedEntryPath));
      if (!p.isWithin(targetRoot.path, targetPath) && !p.equals(targetRoot.path, targetPath)) {
        throw AssetDownloadException('Refusing to extract archive entry outside the staging root: ${file.name}');
      }

      if (file.isDirectory) {
        Directory(targetPath).createSync(recursive: true);
        continue;
      }

      final parent = Directory(p.dirname(targetPath));
      parent.createSync(recursive: true);
      File(targetPath).writeAsBytesSync(file.content, flush: true);
    }
  }

  String _downloadFailureMessage(int statusCode) {
    return 'Failed to download assets for v$version: HTTP $statusCode. Verify the version exists at '
        'https://github.com/DartClaw/dartclaw/releases';
  }

  String _missingChecksumMessage() {
    return 'SHA256 checksum not available for v$version. Cannot verify asset integrity.';
  }

  String _parseChecksum(String body) {
    final trimmed = body.trim();
    if (trimmed.isEmpty) {
      throw AssetDownloadException(_missingChecksumMessage());
    }
    final hash = trimmed.split(RegExp(r'\s+')).first;
    if (!RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(hash)) {
      throw AssetDownloadException(
        'Invalid SHA256 checksum for v$version at ${_assetUri('dartclaw-assets-v$version.tar.gz.sha256')}.',
      );
    }
    return hash.toLowerCase();
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) {
      return '$bytes B';
    }

    const units = ['KB', 'MB', 'GB', 'TB'];
    double value = bytes / 1024.0;
    var unitIndex = 0;
    while (value >= 1024 && unitIndex < units.length - 1) {
      value /= 1024.0;
      unitIndex += 1;
    }

    final display = value.truncateToDouble() == value ? value.toStringAsFixed(0) : value.toStringAsFixed(1);
    return '$display ${units[unitIndex]}';
  }
}
