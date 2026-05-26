// Fitness function: no raw git Process.run/Process.start in production code.
//
// What this enforces:
//   Production code under packages/<X>/lib/ and apps/<X>/lib/ must not call
//   `Process.run('git', ...)` or `Process.start('git', ...)` directly.
//   All git subprocess invocations must go through `SafeProcess.git(...)`.
//   The canonical implementation (safe_process.dart) is the only allowed site.
//
// Why:
//   Raw git subprocesses bypass SafeProcess's environment isolation (credential
//   stripping, path sanitization). This fitness test freezes the post-S47
//   baseline where zero production files invoke git directly, acting as a
//   regression guard.
//
// How to resolve a failure:
//   Replace `await Process.run('git', args)` / `Process.start('git', args)`
//   with `await SafeProcess.git(args, environment: ...)` from
//   `package:dartclaw_security/dartclaw_security.dart`.
//   If the call site genuinely must spawn git directly (e.g. a new canonical
//   wrapper), add an entry to
//   `packages/dartclaw_testing/test/fitness/allowlist/safe_process_usage.txt`
//   with format `<relative-path>  # <rationale>`.

import 'dart:io';

import 'package:test/test.dart';

void main() {
  late Set<String> allowlist;
  late String repoRoot;

  setUpAll(() {
    repoRoot = _findRepoRoot();
    allowlist = _readAllowlist(repoRoot, 'safe_process_usage.txt');
  });

  test('allowlist entries have required rationale format', () {
    final allowlistFile = File('$repoRoot/packages/dartclaw_testing/test/fitness/allowlist/safe_process_usage.txt');
    _assertAllowlistFormat(allowlistFile);
  });

  test('no raw git Process.run/Process.start in production code', () {
    final violations = <String>[];
    final rawGitPattern = RegExp(r'''Process\.(run|start)\s*\(\s*['"]git''');

    for (final baseDir in ['packages', 'apps']) {
      final dir = Directory('$repoRoot/$baseDir');
      if (!dir.existsSync()) continue;
      for (final pkg in dir.listSync().whereType<Directory>()) {
        final libDir = Directory('${pkg.path}/lib');
        if (!libDir.existsSync()) continue;
        for (final file in libDir.listSync(recursive: true).whereType<File>()) {
          if (!file.path.endsWith('.dart')) continue;

          final relativePath = _relativeTo(file.path, repoRoot);
          if (allowlist.contains(relativePath)) continue;

          final lines = file.readAsLinesSync();
          for (var i = 0; i < lines.length; i++) {
            if (rawGitPattern.hasMatch(lines[i])) {
              violations.add(
                '$relativePath:${i + 1}: raw git Process.run/start — '
                'use SafeProcess.git instead (see packages/dartclaw_testing/test/fitness/README.md)',
              );
            }
          }
        }
      }
    }

    if (violations.isNotEmpty) {
      fail(
        'Raw git subprocess violations (see packages/dartclaw_testing/test/fitness/README.md):\n'
        '  ${violations.join('\n  ')}',
      );
    }
  });
}

String _findRepoRoot() {
  for (var dir = Directory.current; dir.parent.path != dir.path; dir = dir.parent) {
    if (File('${dir.path}/pubspec.yaml').existsSync() && Directory('${dir.path}/packages').existsSync()) {
      return dir.path;
    }
  }
  throw StateError('Could not locate repo root from ${Directory.current.path}');
}

Set<String> _readAllowlist(String repoRoot, String filename) {
  final file = File('$repoRoot/packages/dartclaw_testing/test/fitness/allowlist/$filename');
  if (!file.existsSync()) return {};
  final result = <String>{};
  for (final line in file.readAsLinesSync()) {
    final stripped = line.trim();
    if (stripped.isEmpty || stripped.startsWith('#')) continue;
    final sep = stripped.indexOf('  # ');
    if (sep < 0) continue;
    result.add(stripped.substring(0, sep));
  }
  return result;
}

void _assertAllowlistFormat(File allowlistFile) {
  if (!allowlistFile.existsSync()) return;
  final bad = <String>[];
  final lines = allowlistFile.readAsLinesSync();
  for (var i = 0; i < lines.length; i++) {
    final stripped = lines[i].trim();
    if (stripped.isEmpty || stripped.startsWith('#')) continue;
    final sep = stripped.indexOf('  # ');
    if (sep < 0) {
      bad.add('line ${i + 1}: missing "  # " separator');
      continue;
    }
    if (stripped.substring(sep + 4).trim().isEmpty) {
      bad.add('line ${i + 1}: rationale is empty');
    }
  }
  if (bad.isNotEmpty) {
    fail(
      'Malformed allowlist ${allowlistFile.path}:\n'
      '  ${bad.join('\n  ')}\n'
      'Each non-comment line must be: <relative-path>  # <non-empty rationale>',
    );
  }
}

String _relativeTo(String path, String root) {
  final normalizedRoot = root.endsWith('/') ? root : '$root/';
  return path.startsWith(normalizedRoot) ? path.substring(normalizedRoot.length) : path;
}
