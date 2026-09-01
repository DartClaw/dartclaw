// Fitness function: every barrel export must carry an explicit `show` clause.
//
// What this enforces:
//   Every `export 'src/...'` line in a package's top-level barrel file
//   (packages/<X>/lib/<X>.dart or apps/<X>/lib/<X>.dart) must include a
//   `show` clause listing the exported symbols explicitly. Wholesale exports
//   (`export 'src/foo.dart'` with no `show`) are allowlisted in
//   `allowlist/barrel_show_clauses.txt` with mandatory rationale comments.
//
// Why:
//   Wholesale barrel exports silently surface all public symbols of the
//   re-exported file, making it impossible to tell at a glance what a package
//   advertises. Explicit `show` clauses are the machine-checkable counterpart
//   to code-review scrutiny: any new unexplained symbol causes a CI failure.
//
// How to resolve a failure:
//   Option A (preferred): Add a `show SymbolName` clause to the failing export
//   line in the barrel file.
//   Option B (intentional exception): Add an entry to
//   `allowlist/barrel_show_clauses.txt`
//   with the format `<file>:<line>  # <rationale>`. The rationale is mandatory
//   and will be reviewed at code-review time.

import 'dart:io';

import 'package:test/test.dart';

import '_internal/fitness_test_utils.dart';

void main() {
  late Allowlist allowlist;
  late String repoRoot;

  setUpAll(() {
    repoRoot = findRepoRoot();
    allowlist = readAllowlist(repoRoot, 'barrel_show_clauses.txt');
  });

  // A stale entry guards nothing; fail the gate that owns it rather than pass quietly.
  tearDownAll(() => allowlist.assertNoStaleEntries());

  test('allowlist entries have required rationale format', () {
    assertAllowlistFormat(allowlistFile(repoRoot, 'barrel_show_clauses.txt'));
  });

  test('all barrel exports have show clauses or are allowlisted', () {
    final violations = <String>[];

    for (final barrelFile in _findBarrels(repoRoot)) {
      final relativePath = relativeTo(barrelFile.path, repoRoot);
      final lines = barrelFile.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        if (!_wholesaleExport.hasMatch(line)) continue;
        final key = '$relativePath:${i + 1}';
        if (!allowlist.containsKey(key)) {
          violations.add(
            '$key: wholesale export missing show clause — add show clause or allowlist in barrel_show_clauses.txt',
          );
        }
      }
    }

    if (violations.isNotEmpty) {
      fail(
        'Barrel show-clause violations (see $fitnessReadmePath):\n'
        '  ${violations.join('\n  ')}',
      );
    }
  });
}

final _wholesaleExport = RegExp(r'''^export 'src/[^']+\.dart'\s*;''');

/// Finds every package/app barrel file in the repo.
Iterable<File> _findBarrels(String repoRoot) sync* {
  final packagesDir = Directory('$repoRoot/packages');
  for (final pkg in packagesDir.listSync().whereType<Directory>()) {
    final name = pkg.path.split('/').last;
    final barrel = File('${pkg.path}/lib/$name.dart');
    if (barrel.existsSync()) yield barrel;
  }

  final appsDir = Directory('$repoRoot/apps');
  if (appsDir.existsSync()) {
    for (final app in appsDir.listSync().whereType<Directory>()) {
      final name = app.path.split('/').last;
      final barrel = File('${app.path}/lib/$name.dart');
      if (barrel.existsSync()) yield barrel;
    }
  }
}
