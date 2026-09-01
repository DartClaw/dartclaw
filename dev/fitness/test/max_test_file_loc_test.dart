// Fitness function: no test file may exceed 1300 LOC unless allowlisted, and
// allowlist entries ratchet.
//
// What this enforces:
//   1. Every `*_test.dart` file `testDartFiles` yields - under packages/, apps/
//      and this suite's own test/ tree - that is NOT allowlisted must have
//      <= 1300 lines.
//   2. Each allowlist entry records the file's baseline LOC (the leading
//      integer of its rationale). The check FAILS when:
//        - the file has grown past that recorded baseline (the ratchet), or
//        - the entry points at a file that no longer exists, or
//        - the file has dropped back to <= 1300 (it no longer needs an
//          exception - remove the entry).
//   Shrinking is always allowed; refresh the recorded number downward when a
//   file shrinks so the ratchet keeps tightening.
//
// Why:
//   Large tests hide redundant cases and discourage behavior-focused additions.
//   Without the ratchet the recorded LOC values were inert - an allowlisted
//   file could grow unbounded (M-r/CT-11). The ratchet freezes each baseline
//   and only ever lets it move down.
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

int? _recordedLoc(String rationale) {
  final match = RegExp(r'^(\d+)').firstMatch(rationale.trim());
  return match == null ? null : int.parse(match.group(1)!);
}

void main() {
  late Allowlist allowlist;
  late String repoRoot;

  setUpAll(() {
    repoRoot = findRepoRoot();
    allowlist = readAllowlist(repoRoot, 'max_test_file_loc.txt');
  });

  // A stale entry guards nothing; fail the gate that owns it rather than pass quietly.
  tearDownAll(() => allowlist.assertNoStaleEntries());

  test('allowlist entries have required rationale format', () {
    assertAllowlistFormat(allowlistFile(repoRoot, 'max_test_file_loc.txt'), entryFormat: '<relative-path>');
  });

  test('no *_test.dart file exceeds $_locLimit lines unless allowlisted', () {
    final violations = <String>[];

    for (final file in testDartFiles(repoRoot)) {
      final relativePath = relativeTo(file.path, repoRoot).replaceAll('\\', '/');
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
        'Test file LOC violations (see $fitnessReadmePath):\n'
        '  ${violations.join('\n  ')}',
      );
    }
  });

  test('allowlist entries ratchet: file exists, stays over the ceiling, and does not grow past its recorded LOC', () {
    final violations = <String>[];

    allowlist.forEach((relativePath, rationale) {
      final file = File('$repoRoot/$relativePath');
      if (!file.existsSync()) {
        violations.add('$relativePath: allowlisted but file does not exist - remove the stale entry');
        return;
      }
      final loc = file.readAsLinesSync().length;
      if (loc <= _locLimit) {
        violations.add(
          '$relativePath: now $loc lines (<= $_locLimit) - remove it from the allowlist, '
          'it no longer needs an exception',
        );
        return;
      }
      final recorded = _recordedLoc(rationale);
      if (recorded == null) {
        violations.add('$relativePath: rationale must begin with the recorded LOC (e.g. "1908 LOC; ...")');
        return;
      }
      if (loc > recorded) {
        violations.add(
          '$relativePath: grew to $loc lines, past its recorded baseline of $recorded - '
          'shrink it back under $recorded (refresh the recorded LOC downward only)',
        );
      }
    });

    if (violations.isNotEmpty) {
      fail(
        'Test file LOC ratchet violations (see $fitnessReadmePath):\n'
        '  ${violations.join('\n  ')}',
      );
    }
  });
}
