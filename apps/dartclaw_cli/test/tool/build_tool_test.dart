@Tags(['slow'])
library;

import 'dart:io';

import 'package:dartclaw_server/dartclaw_server.dart' show dartclawVersion;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

String _repoRoot() {
  final start =
      Platform.environment['DARTCLAW_REPO_ROOT'] ??
      Platform.environment['GITHUB_WORKSPACE'] ??
      Platform.environment['PWD'] ??
      Directory.current.absolute.path;
  var current = start;
  while (true) {
    if (File(p.join(current, 'dev', 'tools', 'build.sh')).existsSync() &&
        Directory(p.join(current, 'apps')).existsSync()) {
      return current;
    }
    final parent = p.dirname(current);
    if (parent == current) throw StateError('Unable to locate repository root from $start');
    current = parent;
  }
}

String _hostOsName() => switch ((Process.runSync('uname', ['-s']).stdout as String).trim()) {
  'Darwin' => 'macos',
  'Linux' => 'linux',
  final value => value.toLowerCase(),
};

String _hostArchName() => switch ((Process.runSync('uname', ['-m']).stdout as String).trim()) {
  'x86_64' || 'amd64' => 'x64',
  'aarch64' || 'arm64' => 'arm64',
  final value => value.toLowerCase(),
};

String _hostLibraryName() => _hostOsName() == 'macos' ? 'libsqlite3.dylib' : 'libsqlite3.so';

String _hashFile(String path) {
  for (final command in [
    ('sha256sum', [path]),
    ('shasum', ['-a', '256', path]),
  ]) {
    try {
      final result = Process.runSync(command.$1, command.$2);
      if (result.exitCode == 0) return (result.stdout as String).trim().split(RegExp(r'\s+')).first;
    } on ProcessException {
      continue;
    }
  }
  throw StateError('No SHA-256 checksum tool found.');
}

List<String> _tarEntries(String archivePath) {
  final result = Process.runSync('tar', ['-tzf', archivePath]);
  if (result.exitCode != 0) throw StateError('tar failed: ${result.stderr}');
  return (result.stdout as String).trim().split('\n').where((line) => line.isNotEmpty).toList();
}

void main() {
  final repoRoot = _repoRoot();
  final buildScript = p.join(repoRoot, 'dev', 'tools', 'build.sh');
  final buildDir = Directory(p.join(repoRoot, 'build'));
  final version = dartclawVersion;

  tearDown(() {
    if (buildDir.existsSync()) buildDir.deleteSync(recursive: true);
  });

  test('produces a bundled-binary platform archive and checksums', () async {
    final result = await Process.run('bash', [buildScript], workingDirectory: repoRoot);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');

    final archive = p.join(buildDir.path, 'dartclaw-v$version-${_hostOsName()}-${_hostArchName()}.tar.gz');
    final archiveSha = '$archive.sha256';
    final sums = p.join(buildDir.path, 'SHA256SUMS.txt');
    final binaryPath = p.join(buildDir.path, 'bin', 'dartclaw');
    expect(File(binaryPath).existsSync(), isTrue);
    expect(File(archive).existsSync(), isTrue);
    expect(File(archiveSha).existsSync(), isTrue);
    expect(File(sums).existsSync(), isTrue);
    expect(
      buildDir.listSync().whereType<File>().any((file) => p.basename(file.path).startsWith('dartclaw-assets-')),
      isFalse,
    );

    final retiredCommand = Process.runSync(binaryPath, ['assets']);
    expect(retiredCommand.exitCode, 64);
    expect(retiredCommand.stderr, contains('Could not find a command named "assets".'));

    final entries = _tarEntries(archive);
    expect(entries, containsAll(['VERSION', 'bin/', 'bin/dartclaw', 'lib/', 'lib/${_hostLibraryName()}']));
    expect(entries.any((entry) => entry.startsWith('share/')), isFalse);

    final checksumLine = '${_hashFile(archive)}  ${p.basename(archive)}';
    expect(File(archiveSha).readAsStringSync().trim(), checksumLine);
    expect(File(sums).readAsStringSync().trim(), checksumLine);

    // Regression guard for the bundled-SQLite migration: a binary built without
    // the native sqlite asset resolves no `sqlite3_*` symbols and crashes at the
    // first SQLite call. rebuild-index opens the FTS5 search DB, so a clean
    // `Rebuilt index:` proves the bundled libsqlite3 loaded and initialized.
    final smokeDir = Directory.systemTemp.createTempSync('dartclaw-build-smoke');
    addTearDown(() => smokeDir.deleteSync(recursive: true));
    Directory(p.join(smokeDir.path, 'workspace')).createSync(recursive: true);
    File(
      p.join(smokeDir.path, 'workspace', 'MEMORY.md'),
    ).writeAsStringSync('## general\n- [2026-02-23 10:00] Bundled sqlite smoke entry\n');
    final configPath = p.join(smokeDir.path, 'dartclaw.yaml');
    File(configPath).writeAsStringSync('data_dir: ${smokeDir.path}\n');

    final rebuild = Process.runSync(binaryPath, ['--config', configPath, 'rebuild-index']);
    expect(rebuild.exitCode, 0, reason: '${rebuild.stdout}\n${rebuild.stderr}');
    expect(rebuild.stdout, contains('Rebuilt index:'));
  }, timeout: const Timeout(Duration(minutes: 15)));

  test('produces target-stamped stub archives without a bundled library', () {
    for (final target in ['macos-arm64', 'macos-x64', 'linux-x64', 'linux-arm64']) {
      final result = Process.runSync(
        'bash',
        [buildScript],
        workingDirectory: repoRoot,
        environment: {'DARTCLAW_RELEASE_TARGET': target, 'DARTCLAW_BUILD_SKIP_COMPILE': '1'},
      );
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');

      final archive = File(p.join(buildDir.path, 'dartclaw-v$version-$target.tar.gz'));
      expect(archive.existsSync(), isTrue);
      expect(File('${archive.path}.sha256').existsSync(), isTrue);
      expect(File(p.join(buildDir.path, 'bin', 'dartclaw')).existsSync(), isTrue);

      final entries = _tarEntries(archive.path);
      expect(entries, containsAll(['VERSION', 'bin/', 'bin/dartclaw']));
      // The compile stub emits no native library, so no lib/ is staged.
      expect(entries.any((entry) => entry.startsWith('lib/')), isFalse);
      expect(entries.any((entry) => entry.startsWith('share/')), isFalse);
      expect(File(p.join(buildDir.path, 'SHA256SUMS.txt')).readAsStringSync().trim().split('\n'), hasLength(1));
    }
  });
}
