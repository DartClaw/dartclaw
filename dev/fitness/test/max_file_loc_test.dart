// Fitness function: production files fail at 110% of the 1,500-line target.
//
// What this enforces:
//   Every `.dart` file under `packages/<X>/lib/src/**` must stay below 1,650 lines.
//   Known intentional violators are listed in `allowlist/max_file_loc.txt` with
//   a shrink-target rationale — they are tracked for remediation, not forgotten.
//
// Why:
//   Files reaching 1,650 LOC are a reliable signal of insufficient
//   decomposition. The target prevents gradual drift toward monolithic files
//   that are expensive to review, test, and understand.
//
// How to resolve a failure:
//   Option A (preferred): Decompose the file into smaller focused modules so
//   that each stays under the 1,500-line target.
//   Option B (intentional exception with shrink target): Add an entry to
//   `allowlist/max_file_loc.txt` with
//   the format `<relative-path-from-repo-root>  # <LOC>; <shrink-target>`.
//   The rationale is mandatory, must name the current LOC and a target story
//   or deadline, and will be reviewed at code-review time.

import 'dart:io';

import 'package:test/test.dart';

import '_internal/fitness_test_utils.dart';
import '../../tools/loc_target.dart';

const _locLimit = 1500;

void main() {
  late Allowlist allowlist;
  late String repoRoot;

  setUpAll(() {
    repoRoot = findRepoRoot();
    allowlist = readAllowlist(repoRoot, 'max_file_loc.txt');
  });

  // A stale entry guards nothing; fail the gate that owns it rather than pass quietly.
  tearDownAll(() => allowlist.assertNoStaleEntries());

  test('allowlist entries have required rationale format', () {
    assertAllowlistFormat(allowlistFile(repoRoot, 'max_file_loc.txt'), entryFormat: '<relative-path>');
  });

  test('no lib/src/**/*.dart file reaches 110% of the $_locLimit-line target', () {
    final violations = <String>[];

    final packagesDir = Directory('$repoRoot/packages');
    for (final pkg in packagesDir.listSync().whereType<Directory>()) {
      final srcDir = Directory('${pkg.path}/lib/src');
      if (!srcDir.existsSync()) continue;
      for (final entity in srcDir.listSync(recursive: true).whereType<File>()) {
        if (!entity.path.endsWith('.dart')) continue;
        final relativePath = relativeTo(entity.path, repoRoot).replaceAll('\\', '/');
        if (relativePath.contains('/lib/src/generated/')) continue;
        final loc = entity.readAsLinesSync().length;
        // Consulted only once the file reaches the failure margin, so an entry
        // for a file that has since shrunk reads as stale instead of silent.
        if (locExceedsTarget(loc, _locLimit) && !allowlist.containsKey(relativePath)) {
          violations.add(
            '$relativePath: $loc lines (target $_locLimit; fails at 110%) — '
            'decompose or add to allowlist/max_file_loc.txt with rationale',
          );
        }
      }
    }

    if (violations.isNotEmpty) {
      fail(
        'File LOC violations (see $fitnessReadmePath):\n'
        '  ${violations.join('\n  ')}',
      );
    }
  });
}
