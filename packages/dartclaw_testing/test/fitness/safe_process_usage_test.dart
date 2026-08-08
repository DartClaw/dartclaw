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

import '_internal/fitness_test_utils.dart';

void main() {
  late Map<String, String> allowlist;
  late String repoRoot;

  setUpAll(() {
    repoRoot = findRepoRoot();
    allowlist = readAllowlist(repoRoot, 'safe_process_usage.txt');
  });

  test('allowlist entries have required rationale format', () {
    final allowlistFile = File('$repoRoot/packages/dartclaw_testing/test/fitness/allowlist/safe_process_usage.txt');
    assertAllowlistFormat(allowlistFile, entryFormat: '<relative-path>');
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

          final relativePath = relativeTo(file.path, repoRoot);
          if (allowlist.containsKey(relativePath)) continue;

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
