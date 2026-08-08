// Fitness function: local test fake class names must not be redeclared.
//
// What this enforces:
//   A local fake/stub/mock/recording class name may appear in one test file.
//   Existing duplicates are allowlisted while they are migrated to shared
//   support such as dartclaw_testing or package-local test support files.
//
// Why:
//   Duplicate fakes drift from the real boundary and from each other. Shared
//   fakes keep test setup shorter and make behavior changes fail in one place.

import 'dart:io';

import 'package:test/test.dart';

import '_internal/fitness_test_utils.dart';

final _fakeClassPattern = RegExp(
  r'^\s*(?:final\s+|base\s+|sealed\s+|abstract\s+)?class\s+'
  r'(_?(?:Fake|Recording|Mock|Stub)\w+)\b',
  multiLine: true,
);

void main() {
  late Map<String, String> allowlist;
  late String repoRoot;

  setUpAll(() {
    repoRoot = findRepoRoot();
    allowlist = readAllowlist(repoRoot, 'no_duplicate_local_fakes.txt');
  });

  test('allowlist entries have required rationale format', () {
    final allowlistFile = File(
      '$repoRoot/packages/dartclaw_testing/test/fitness/allowlist/no_duplicate_local_fakes.txt',
    );
    assertAllowlistFormat(allowlistFile, entryFormat: '<ClassName>');
  });

  test('local fake class names are not redeclared across test files', () {
    final declarations = <String, Set<String>>{};

    for (final file in testDartFiles(repoRoot)) {
      final relativePath = relativeTo(file.path, repoRoot);
      final source = file.readAsStringSync();
      for (final match in _fakeClassPattern.allMatches(source)) {
        final className = match.group(1)!;
        declarations.putIfAbsent(className, () => <String>{}).add(relativePath);
      }
    }

    final violations = <String>[];
    for (final entry in declarations.entries) {
      if (entry.value.length < 2) continue;
      if (allowlist.containsKey(entry.key)) continue;
      violations.add(
        '${entry.key} declared in ${entry.value.length} test files:\n'
        '    ${entry.value.toList()..sort()}',
      );
    }

    if (violations.isNotEmpty) {
      fail(
        'Duplicate local fake declarations (see packages/dartclaw_testing/test/fitness/README.md):\n'
        '  ${violations.join('\n  ')}',
      );
    }
  });
}
