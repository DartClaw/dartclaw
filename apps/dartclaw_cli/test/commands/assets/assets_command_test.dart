import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:args/command_runner.dart';
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:dartclaw_cli/src/asset_downloader.dart';
import 'package:dartclaw_cli/src/commands/assets/assets_command.dart';
import 'package:dartclaw_cli/src/commands/assets/assets_download_command.dart';
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
    tempHome = Directory.systemTemp.createTempSync('dartclaw_assets_command_test_');
  });

  tearDown(() {
    if (tempHome.existsSync()) {
      tempHome.deleteSync(recursive: true);
    }
  });

  test('registers the download subcommand', () {
    final command = AssetsCommand();
    expect(command.subcommands.keys, contains('download'));
  });

  test('assets download prints the install path after a successful download', () async {
    final archiveBytes = _buildArchive({'templates/app.html': '<html>ok</html>'});
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

    final stdoutLines = <String>[];
    final stderrLines = <String>[];
    final downloader = AssetDownloader(
      homeDir: tempHome.path,
      releaseBaseUri: _releaseBaseUri(server),
      stderrLine: stderrLines.add,
    );
    final command = AssetsDownloadCommand(
      downloader: downloader,
      stdoutLine: stdoutLines.add,
      stderrLine: stderrLines.add,
    );
    final runner = CommandRunner<void>('dartclaw', 'test')..addCommand(AssetsCommand(downloadCommand: command));

    await runner.run(['assets', 'download']);

    expect(stdoutLines.single, p.join(tempHome.path, '.dartclaw', 'assets', 'v$dartclawVersion'));
    expect(stderrLines.single, startsWith('Downloading assets for v$dartclawVersion ('));
  });
}
