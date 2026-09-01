// Fitness function: production code must not import another package's `src/`.
//
// How to resolve a failure:
//   Use the dependency package barrel instead. If the needed type is not public,
//   promote a narrow public API with an explicit `show` export in that package.

import 'package:test/test.dart';

import '_internal/fitness_test_utils.dart';

final _srcImport = RegExp(r'''^\s*import\s+['"]package:([a-zA-Z_][a-zA-Z0-9_]*)/src/[^'"]+['"]''');

void main() {
  late String repoRoot;
  late Allowlist allowlist;

  setUpAll(() {
    repoRoot = findRepoRoot();
    allowlist = readAllowlist(repoRoot, 'src_import_hygiene.txt');
  });

  // A stale entry guards nothing; fail the gate that owns it rather than pass quietly.
  tearDownAll(() => allowlist.assertNoStaleEntries());

  test('allowlist entries have required rationale format', () {
    assertAllowlistFormat(allowlistFile(repoRoot, 'src_import_hygiene.txt'));
  });

  test('no cross-package src imports in production libraries', () {
    final violations = <String>[];

    for (final file in productionDartFiles(repoRoot)) {
      final owner = ownerPackageFor(repoRoot, file);
      final relative = relativeTo(file.path, repoRoot);
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final imported = _srcImport.firstMatch(lines[i])?.group(1);
        if (imported == null || imported == owner) continue;
        final key = '$relative:${i + 1}';
        if (!allowlist.containsKey(key)) {
          violations.add('$key: cross-package src/ import to $imported (use barrel)');
        }
      }
    }

    if (violations.isNotEmpty) {
      fail('Cross-package src import violations:\n  ${violations.join('\n  ')}');
    }
  });
}
