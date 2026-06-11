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
    if (File(p.join(current, 'package', 'homebrew', 'dartclaw.rb')).existsSync() &&
        Directory(p.join(current, 'apps')).existsSync()) {
      return current;
    }

    final parent = p.dirname(current);
    if (parent == current) {
      throw StateError('Unable to locate repository root from $start');
    }
    current = parent;
  }
}

void main() {
  final repoRoot = _repoRoot();
  final formula = File(p.join(repoRoot, 'package', 'homebrew', 'dartclaw.rb')).readAsStringSync();

  test('Homebrew formula installs release assets and verifies runtime version', () {
    expect(formula, contains('version "$dartclawVersion"'));
    expect(formula, isNot(contains('REPLACE_WITH')));
    expect(RegExp(r'sha256 "[0-9a-f]{64}"').allMatches(formula), hasLength(4));

    for (final target in ['macos-arm64', 'macos-x64', 'linux-x64', 'linux-arm64']) {
      expect(formula, contains('dartclaw-v#{version}-$target.tar.gz'));
    }

    expect(formula, contains('bin.install "bin/dartclaw"'));
    expect(formula, contains('pkgshare.install Dir["share/dartclaw/*"]'));
    expect(formula, contains('test do'));
    expect(formula, contains('shell_output("#{bin}/dartclaw --version").strip'));
    expect(formula, contains('version.to_s'));

    for (final provider in ['claude', 'codex', 'goose', 'vibe']) {
      expect(formula.toLowerCase(), isNot(contains('depends_on "$provider"')));
      expect(formula.toLowerCase(), isNot(contains("depends_on '$provider'")));
    }
  });

  test('render_homebrew_formula injects the four real platform digests', () {
    final digests = {
      'macos-arm64': '1a' * 32,
      'macos-x64': '2b' * 32,
      'linux-x64': '3c' * 32,
      'linux-arm64': '4d' * 32,
    };

    final tempDir = Directory.systemTemp.createTempSync('dc-formula-render');
    addTearDown(() => tempDir.deleteSync(recursive: true));

    for (final entry in digests.entries) {
      final archive = 'dartclaw-v$dartclawVersion-${entry.key}.tar.gz';
      File(p.join(tempDir.path, '$archive.sha256')).writeAsStringSync('${entry.value}  $archive\n');
    }

    final outPath = p.join(tempDir.path, 'rendered.rb');
    final result = Process.runSync(Platform.resolvedExecutable, [
      'run',
      p.join(repoRoot, 'dev', 'tools', 'render_homebrew_formula.dart'),
      '--formula',
      p.join(repoRoot, 'package', 'homebrew', 'dartclaw.rb'),
      '--checksums-dir',
      tempDir.path,
      '--version',
      dartclawVersion,
      '--output',
      outPath,
    ], workingDirectory: repoRoot);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');

    final rendered = File(outPath).readAsStringSync();
    expect(rendered, contains('version "$dartclawVersion"'));
    // No placeholder digests survive, and each target maps to its own digest.
    for (final placeholder in ['1', '2', '3', '4']) {
      expect(rendered, isNot(contains('sha256 "${placeholder * 64}"')));
    }
    for (final entry in digests.entries) {
      final block = RegExp('url "[^"]*-${entry.key}\\.tar\\.gz"\\s*\\n\\s*sha256 "${entry.value}"');
      expect(block.hasMatch(rendered), isTrue, reason: 'digest for ${entry.key} not injected');
    }
  });

  test('render_homebrew_formula fails on version lockstep drift', () {
    final tempDir = Directory.systemTemp.createTempSync('dc-formula-drift');
    addTearDown(() => tempDir.deleteSync(recursive: true));

    final result = Process.runSync(Platform.resolvedExecutable, [
      'run',
      p.join(repoRoot, 'dev', 'tools', 'render_homebrew_formula.dart'),
      '--formula',
      p.join(repoRoot, 'package', 'homebrew', 'dartclaw.rb'),
      '--checksums-dir',
      tempDir.path,
      '--version',
      '0.0.0-nonmatching',
    ], workingDirectory: repoRoot);
    expect(result.exitCode, isNonZero);
    expect('${result.stderr}', contains('lockstep'));
  });
}
