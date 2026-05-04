import 'dart:async';
import 'dart:io';

import 'package:dartclaw_cli/src/asset_downloader.dart';
import 'package:dartclaw_server/dartclaw_server.dart' show AssetResolver, dartclawVersion;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

String _repoRoot() {
  var current = Directory.current.absolute.path;
  while (true) {
    if (File(p.join(current, 'dev', 'tools', 'build.sh')).existsSync() &&
        Directory(p.join(current, 'apps')).existsSync()) {
      return current;
    }

    final parent = p.dirname(current);
    if (parent == current) {
      throw StateError('Unable to locate repository root from $current');
    }
    current = parent;
  }
}

Future<ProcessResult> _runCommand(
  String executable,
  List<String> arguments, {
  required String workingDirectory,
  Map<String, String>? environment,
}) {
  return Process.run(executable, arguments, workingDirectory: workingDirectory, environment: environment);
}

String _readFile(String path) => File(path).readAsStringSync();

String _hostOsName() {
  final result = Process.runSync('uname', ['-s']);
  if (result.exitCode != 0) {
    throw StateError('uname -s failed: ${result.stderr}');
  }
  final raw = (result.stdout as String).trim();
  return switch (raw) {
    'Darwin' => 'macos',
    'Linux' => 'linux',
    _ => raw.toLowerCase(),
  };
}

String _hostArchName() {
  final result = Process.runSync('uname', ['-m']);
  if (result.exitCode != 0) {
    throw StateError('uname -m failed: ${result.stderr}');
  }
  final raw = (result.stdout as String).trim();
  return switch (raw) {
    'x86_64' || 'amd64' => 'x64',
    'aarch64' || 'arm64' => 'arm64',
    _ => raw.toLowerCase(),
  };
}

String _hashFile(String path) {
  final sha256sum = Process.runSync('sha256sum', [path]);
  if (sha256sum.exitCode == 0) {
    return (sha256sum.stdout as String).trim().split(RegExp(r'\s+')).first;
  }

  final shasum = Process.runSync('shasum', ['-a', '256', path]);
  if (shasum.exitCode == 0) {
    return (shasum.stdout as String).trim().split(RegExp(r'\s+')).first;
  }

  throw StateError('No SHA-256 checksum tool found.');
}

List<String> _tarEntries(String archivePath) {
  final result = Process.runSync('tar', ['-tzf', archivePath]);
  if (result.exitCode != 0) {
    throw StateError('tar -tzf failed for $archivePath: ${result.stderr}');
  }
  return (result.stdout as String).trim().split('\n').where((line) => line.isNotEmpty).toList();
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
  final repoRoot = _repoRoot();
  final buildScriptPath = p.join(repoRoot, 'dev', 'tools', 'build.sh');
  final buildDir = Directory(p.join(repoRoot, 'build'));
  final version = dartclawVersion;
  final osName = _hostOsName();
  final archName = _hostArchName();
  final platformArchive = p.join(buildDir.path, 'dartclaw-v$version-$osName-$archName.tar.gz');
  final platformSha = '$platformArchive.sha256';
  final assetArchive = p.join(buildDir.path, 'dartclaw-assets-v$version.tar.gz');
  final assetSha = '$assetArchive.sha256';
  final sumsFile = p.join(buildDir.path, 'SHA256SUMS.txt');

  tearDown(() {
    if (buildDir.existsSync()) {
      buildDir.deleteSync(recursive: true);
    }
  });

  test('produces the expected binary and release archives', () async {
    if (buildDir.existsSync()) {
      buildDir.deleteSync(recursive: true);
    }

    final result = await _runCommand('bash', [buildScriptPath], workingDirectory: repoRoot);
    expect(result.exitCode, 0, reason: result.stderr.toString());

    final binaryPath = p.join(buildDir.path, 'dartclaw');
    expect(File(binaryPath).existsSync(), isTrue);
    expect(File(platformArchive).existsSync(), isTrue);
    expect(File(platformSha).existsSync(), isTrue);
    expect(File(assetArchive).existsSync(), isTrue);
    expect(File(assetSha).existsSync(), isTrue);
    expect(File(sumsFile).existsSync(), isTrue);

    final platformEntries = _tarEntries(platformArchive);
    final assetEntries = _tarEntries(assetArchive);
    expect(platformEntries, contains('bin/dartclaw'));
    expect(platformEntries, contains('share/dartclaw/templates/layout.html'));
    expect(platformEntries, contains('share/dartclaw/static/app.js'));
    expect(platformEntries, contains('share/dartclaw/skills/dartclaw-discover-project/SKILL.md'));
    expect(platformEntries, contains('share/dartclaw/skills/dartclaw-validate-workflow/SKILL.md'));
    expect(platformEntries, contains('share/dartclaw/workflows/spec-and-implement.yaml'));
    expect(platformEntries, contains('share/dartclaw/workflows/plan-and-implement.yaml'));
    expect(platformEntries, contains('share/dartclaw/workflows/code-review.yaml'));
    expect(platformEntries, contains('VERSION'));

    expect(assetEntries, isNot(contains('bin/dartclaw')));
    expect(assetEntries, contains('templates/layout.html'));
    expect(assetEntries, contains('static/app.js'));
    expect(assetEntries, contains('skills/dartclaw-discover-project/SKILL.md'));
    expect(assetEntries, contains('skills/dartclaw-validate-workflow/SKILL.md'));
    expect(assetEntries, contains('workflows/spec-and-implement.yaml'));
    expect(assetEntries, contains('workflows/plan-and-implement.yaml'));
    expect(assetEntries, contains('workflows/code-review.yaml'));
    expect(assetEntries, contains('VERSION'));

    final platformHash = _hashFile(platformArchive);
    final assetHash = _hashFile(assetArchive);
    expect(
      _readFile(sumsFile).trim(),
      equals(
        '$platformHash  ${p.basename(platformArchive)}\n'
        '$assetHash  ${p.basename(assetArchive)}',
      ),
    );
    expect(_readFile(platformSha).trim(), equals('$platformHash  ${p.basename(platformArchive)}'));
    expect(_readFile(assetSha).trim(), equals('$assetHash  ${p.basename(assetArchive)}'));

    final tempHome = Directory.systemTemp.createTempSync('dartclaw_build_tool_test_');
    addTearDown(() {
      if (tempHome.existsSync()) {
        tempHome.deleteSync(recursive: true);
      }
    });

    final archiveBytes = File(assetArchive).readAsBytesSync();
    final checksumBody = _readFile(assetSha);
    final server = await _startReleaseServer((request) async {
      final response = request.response;
      switch (request.uri.path) {
        case '/releases/download/v$dartclawVersion/dartclaw-assets-v$dartclawVersion.tar.gz.sha256':
          response
            ..statusCode = HttpStatus.ok
            ..headers.contentType = ContentType.text
            ..write(checksumBody);
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

    final stderrLines = <String>[];
    final downloader = AssetDownloader(
      homeDir: tempHome.path,
      releaseBaseUri: _releaseBaseUri(server),
      stderrLine: stderrLines.add,
    );

    final installPath = await downloader.download();

    expect(installPath, p.join(tempHome.path, '.dartclaw', 'assets', 'v$dartclawVersion'));
    expect(stderrLines.single, startsWith('Downloading assets for v$dartclawVersion ('));
    expect(File(p.join(installPath, 'templates', 'layout.html')).existsSync(), isTrue);
    expect(File(p.join(installPath, 'static', 'app.js')).existsSync(), isTrue);
    expect(File(p.join(installPath, 'skills', 'dartclaw-discover-project', 'SKILL.md')).existsSync(), isTrue);
    expect(File(p.join(installPath, 'workflows', 'plan-and-implement.yaml')).existsSync(), isTrue);

    final resolved = AssetResolver(
      resolvedExecutable: p.join(tempHome.path, 'bin', 'dartclaw'),
      homeDir: tempHome.path,
    ).resolve();
    expect(resolved, isNotNull);
    expect(resolved!.root, installPath);
  }, timeout: const Timeout(Duration(minutes: 15)));
}
