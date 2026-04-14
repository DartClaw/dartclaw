import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:dartclaw_cli/src/asset_downloader.dart';
import 'package:dartclaw_server/dartclaw_server.dart' show dartclawVersion;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

Uint8List _buildArchive(Map<String, String> files) {
  final archive = Archive();
  for (final entry in files.entries) {
    archive.addFile(ArchiveFile.bytes(entry.key, utf8.encode(entry.value)));
  }
  final tarBytes = TarEncoder().encodeBytes(archive);
  return Uint8List.fromList(GZipEncoder().encode(tarBytes));
}

Future<HttpServer> _startReleaseServer(Future<void> Function(HttpRequest request) handler) {
  return HttpServer.bind(InternetAddress.loopbackIPv4, 0).then((server) {
    server.listen((request) => unawaited(handler(request)));
    return server;
  });
}

Uri _releaseBaseUri(HttpServer server) {
  return Uri.parse('http://${server.address.host}:${server.port}/releases/download/v$dartclawVersion/');
}

void main() {
  late Directory tempHome;

  setUp(() {
    tempHome = Directory.systemTemp.createTempSync('dartclaw_asset_downloader_test_');
  });

  tearDown(() {
    if (tempHome.existsSync()) {
      tempHome.deleteSync(recursive: true);
    }
  });

  test('downloads, verifies, and extracts the release archive', () async {
    final archiveBytes = _buildArchive({
      'templates/app.html': '<html>ok</html>',
      'static/app.js': 'console.log("ok");',
      'skills/dartclaw-test/SKILL.md': '# skill\n',
    });
    final checksum = sha256.convert(archiveBytes).toString();
    final stderrLines = <String>[];
    final server = await _startReleaseServer((request) async {
      final response = request.response;
      switch (request.uri.path) {
        case '/releases/download/v$dartclawVersion/dartclaw-assets-v$dartclawVersion.tar.gz.sha256':
          response
            ..statusCode = HttpStatus.ok
            ..headers.contentType = ContentType.text
            ..write('$checksum  dartclaw-assets-v$dartclawVersion.tar.gz\n');
          break;
        case '/releases/download/v$dartclawVersion/dartclaw-assets-v$dartclawVersion.tar.gz':
          response
            ..statusCode = HttpStatus.ok
            ..headers.contentType = ContentType.binary
            ..contentLength = archiveBytes.length
            ..add(archiveBytes);
          break;
        default:
          response.statusCode = HttpStatus.notFound;
      }
      await response.close();
    });
    addTearDown(() => server.close(force: true));

    final downloader = AssetDownloader(
      homeDir: tempHome.path,
      releaseBaseUri: _releaseBaseUri(server),
      stderrLine: stderrLines.add,
    );

    final installPath = await downloader.download();

    expect(installPath, p.join(tempHome.path, '.dartclaw', 'assets', 'v$dartclawVersion'));
    expect(stderrLines.single, startsWith('Downloading assets for v$dartclawVersion ('));
    expect(File(p.join(installPath, 'templates', 'app.html')).readAsStringSync(), '<html>ok</html>');
    expect(File(p.join(installPath, 'static', 'app.js')).readAsStringSync(), 'console.log("ok");');
    expect(File(p.join(installPath, 'skills', 'dartclaw-test', 'SKILL.md')).existsSync(), isTrue);
  });

  test('rejects a SHA256 mismatch before extracting', () async {
    final archiveBytes = _buildArchive({'templates/app.html': '<html>ok</html>'});
    final server = await _startReleaseServer((request) async {
      final response = request.response;
      switch (request.uri.path) {
        case '/releases/download/v$dartclawVersion/dartclaw-assets-v$dartclawVersion.tar.gz.sha256':
          response
            ..statusCode = HttpStatus.ok
            ..headers.contentType = ContentType.text
            ..write('${'0' * 64}  dartclaw-assets-v$dartclawVersion.tar.gz\n');
          break;
        case '/releases/download/v$dartclawVersion/dartclaw-assets-v$dartclawVersion.tar.gz':
          response
            ..statusCode = HttpStatus.ok
            ..headers.contentType = ContentType.binary
            ..contentLength = archiveBytes.length
            ..add(archiveBytes);
          break;
        default:
          response.statusCode = HttpStatus.notFound;
      }
      await response.close();
    });
    addTearDown(() => server.close(force: true));

    final downloader = AssetDownloader(homeDir: tempHome.path, releaseBaseUri: _releaseBaseUri(server));

    await expectLater(
      downloader.download(),
      throwsA(
        isA<AssetDownloadException>().having(
          (e) => e.message,
          'message',
          contains('SHA256 checksum mismatch for v$dartclawVersion.'),
        ),
      ),
    );

    expect(Directory(p.join(tempHome.path, '.dartclaw', 'assets', 'v$dartclawVersion')).existsSync(), isFalse);
  });

  test('rejects archive entries that traverse above the staging root', () async {
    final archiveBytes = _buildArchive({'../traversal.txt': 'nope'});
    final checksum = sha256.convert(archiveBytes).toString();
    final server = await _startReleaseServer((request) async {
      final response = request.response;
      switch (request.uri.path) {
        case '/releases/download/v$dartclawVersion/dartclaw-assets-v$dartclawVersion.tar.gz.sha256':
          response
            ..statusCode = HttpStatus.ok
            ..headers.contentType = ContentType.text
            ..write('$checksum  dartclaw-assets-v$dartclawVersion.tar.gz\n');
          break;
        case '/releases/download/v$dartclawVersion/dartclaw-assets-v$dartclawVersion.tar.gz':
          response
            ..statusCode = HttpStatus.ok
            ..headers.contentType = ContentType.binary
            ..contentLength = archiveBytes.length
            ..add(archiveBytes);
          break;
        default:
          response.statusCode = HttpStatus.notFound;
      }
      await response.close();
    });
    addTearDown(() => server.close(force: true));

    final downloader = AssetDownloader(homeDir: tempHome.path, releaseBaseUri: _releaseBaseUri(server));

    await expectLater(
      downloader.download(),
      throwsA(
        isA<AssetDownloadException>().having(
          (e) => e.message,
          'message',
          contains('outside the staging root'),
        ),
      ),
    );

    expect(File(p.join(tempHome.path, '.dartclaw', 'assets', 'traversal.txt')).existsSync(), isFalse);
    expect(Directory(p.join(tempHome.path, '.dartclaw', 'assets', 'v$dartclawVersion')).existsSync(), isFalse);
  });

  test('rejects archive entries with absolute paths', () async {
    final absolutePath = p.join(tempHome.path, 'absolute.txt');
    final archiveBytes = _buildArchive({absolutePath: 'nope'});
    final checksum = sha256.convert(archiveBytes).toString();
    final server = await _startReleaseServer((request) async {
      final response = request.response;
      switch (request.uri.path) {
        case '/releases/download/v$dartclawVersion/dartclaw-assets-v$dartclawVersion.tar.gz.sha256':
          response
            ..statusCode = HttpStatus.ok
            ..headers.contentType = ContentType.text
            ..write('$checksum  dartclaw-assets-v$dartclawVersion.tar.gz\n');
          break;
        case '/releases/download/v$dartclawVersion/dartclaw-assets-v$dartclawVersion.tar.gz':
          response
            ..statusCode = HttpStatus.ok
            ..headers.contentType = ContentType.binary
            ..contentLength = archiveBytes.length
            ..add(archiveBytes);
          break;
        default:
          response.statusCode = HttpStatus.notFound;
      }
      await response.close();
    });
    addTearDown(() => server.close(force: true));

    final downloader = AssetDownloader(homeDir: tempHome.path, releaseBaseUri: _releaseBaseUri(server));

    await expectLater(
      downloader.download(),
      throwsA(
        isA<AssetDownloadException>().having(
          (e) => e.message,
          'message',
          contains('outside the staging root'),
        ),
      ),
    );

    expect(File(absolutePath).existsSync(), isFalse);
    expect(Directory(p.join(tempHome.path, '.dartclaw', 'assets', 'v$dartclawVersion')).existsSync(), isFalse);
  });

  test('fails with the exact missing-sidecar message when the checksum file is absent', () async {
    final archiveBytes = _buildArchive({'templates/app.html': '<html>ok</html>'});
    final server = await _startReleaseServer((request) async {
      final response = request.response;
      switch (request.uri.path) {
        case '/releases/download/v$dartclawVersion/dartclaw-assets-v$dartclawVersion.tar.gz':
          response
            ..statusCode = HttpStatus.ok
            ..headers.contentType = ContentType.binary
            ..contentLength = archiveBytes.length
            ..add(archiveBytes);
          break;
        default:
          response.statusCode = HttpStatus.notFound;
      }
      await response.close();
    });
    addTearDown(() => server.close(force: true));

    final downloader = AssetDownloader(homeDir: tempHome.path, releaseBaseUri: _releaseBaseUri(server));

    await expectLater(
      downloader.download(),
      throwsA(
        isA<AssetDownloadException>().having(
          (e) => e.message,
          'message',
          'SHA256 checksum not available for v$dartclawVersion. Cannot verify asset integrity.',
        ),
      ),
    );

    expect(Directory(p.join(tempHome.path, '.dartclaw', 'assets', 'v$dartclawVersion')).existsSync(), isFalse);
  });
}
