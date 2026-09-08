import 'dart:io';

import 'package:test/test.dart';

import '_internal/fitness_test_utils.dart';

final _sqliteImport = RegExp(r'''^[ \t]*import\s+['"]package:sqlite3/[^'"]+['"]''', multiLine: true);

void main() {
  late String repoRoot;
  late Allowlist allowlist;

  setUpAll(() {
    repoRoot = findRepoRoot();
    allowlist = readAllowlist(repoRoot, 'sqlite3_import_surface.txt');
  });
  tearDownAll(() => allowlist.assertNoStaleEntries());

  test('allowlist entries have required rationale format', () {
    assertAllowlistFormat(allowlistFile(repoRoot, 'sqlite3_import_surface.txt'));
  });

  test('production driver imports stay inside the sanctioned stores', () {
    expect(_violations(repoRoot, allowlist), isEmpty);
  });

  for (final import in ['import "package:sqlite3/sqlite3.dart";', "import\n  'package:sqlite3/sqlite3.dart';"]) {
    test('scanner names a stray import and rejects a stale entry: $import', () {
      final fixture = Directory.systemTemp.createTempSync('sqlite-import-surface-');
      addTearDown(() => fixture.deleteSync(recursive: true));
      const allowed = 'packages/example/lib/backend.dart';
      const stray = 'apps/example/lib/main.dart';
      const missing = 'packages/example/lib/missing.dart';
      final allowedFile = File('${fixture.path}/$allowed')..createSync(recursive: true);
      allowedFile.writeAsStringSync("import 'package:sqlite3/sqlite3.dart';\n");
      final strayFile = File('${fixture.path}/$stray')..createSync(recursive: true);
      strayFile.writeAsStringSync('// fixture\n\n$import\n');
      final entries = allowlistFile(fixture.path, 'sqlite3_import_surface.txt')..createSync(recursive: true);
      entries.writeAsStringSync('$allowed  # Test driver owner.\n$missing  # Planted stale entry.\n');
      final fixtureAllowlist = readAllowlist(fixture.path, 'sqlite3_import_surface.txt');

      expect(_violations(fixture.path, fixtureAllowlist), [
        '$stray:3: use DatabaseBackend instead of importing sqlite3',
      ]);
      expect(
        fixtureAllowlist.assertNoStaleEntries,
        throwsA(
          isA<TestFailure>().having(
            (error) => error.message,
            'message',
            allOf(contains('sqlite3_import_surface.txt'), contains(missing), isNot(contains(allowed))),
          ),
        ),
      );
    });
  }
}

List<String> _violations(String repoRoot, Allowlist allowlist) {
  final violations = <String>[];
  for (final file in productionDartFiles(repoRoot)) {
    final relative = relativeTo(file.path, repoRoot);
    final source = file.readAsStringSync();
    for (final match in _sqliteImport.allMatches(source)) {
      if (allowlist.containsKey(relative)) continue;
      final line = '\n'.allMatches(source.substring(0, match.start)).length + 1;
      violations.add('$relative:$line: use DatabaseBackend instead of importing sqlite3');
    }
  }
  return violations..sort();
}
