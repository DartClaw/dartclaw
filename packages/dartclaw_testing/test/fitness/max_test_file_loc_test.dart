// Fitness function: no test file may exceed 1300 LOC unless allowlisted.
//
// What this enforces:
//   Every `*_test.dart` file under packages/ and apps/ must have <= 1300 lines.
//   Known baseline violators are listed in `allowlist/max_test_file_loc.txt`
//   with a shrink-target rationale.
//
// Why:
//   Large tests hide redundant cases and discourage behavior-focused additions.
//   The ceiling prevents new mega-tests while the existing reduction plan pays
//   down the current baseline.
//
// 1200 -> 1300 on 2026-08-12: the 0.24 execution-isolation work left
// `harness_wiring_test.dart` with no story headroom under 1200. Per the
// standing "LOC fitness ceilings get headroom, not allowlist churn" decision
// (dev/state/DECISIONS.md), the ceiling moves rather than the allowlist
// growing another entry with an unfunded shrink target.

import 'dart:io';

import 'package:test/test.dart';

import '_internal/fitness_test_utils.dart';

const _locLimit = 1300;

void main() {
  late Map<String, String> allowlist;
  late String repoRoot;

  setUpAll(() {
    repoRoot = findRepoRoot();
    allowlist = readAllowlist(repoRoot, 'max_test_file_loc.txt');
  });

  test('allowlist entries have required rationale format', () {
    final allowlistFile = File('$repoRoot/packages/dartclaw_testing/test/fitness/allowlist/max_test_file_loc.txt');
    assertAllowlistFormat(allowlistFile, entryFormat: '<relative-path>');
  });

  test('no *_test.dart file exceeds $_locLimit lines unless allowlisted', () {
    final violations = <String>[];

    for (final file in testDartFiles(repoRoot)) {
      final relativePath = relativeTo(file.path, repoRoot);
      if (allowlist.containsKey(relativePath)) continue;
      final loc = file.readAsLinesSync().length;
      if (loc > _locLimit) {
        violations.add(
          '$relativePath: $loc lines (limit $_locLimit) - '
          'table-drive, extract fixtures, split, or add a shrink-target allowlist entry',
        );
      }
    }

    if (violations.isNotEmpty) {
      fail(
        'Test file LOC violations (see packages/dartclaw_testing/test/fitness/README.md):\n'
        '  ${violations.join('\n  ')}',
      );
    }
  });
}
