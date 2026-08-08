// Fitness function: no production file under lib/src/ may exceed 1,500 LOC.
//
// What this enforces:
//   Every `.dart` file under `packages/<X>/lib/src/**` must have ≤ 1,500 lines.
//   Known intentional violators are listed in `allowlist/max_file_loc.txt` with
//   a shrink-target rationale — they are tracked for remediation, not forgotten.
//
// Why:
//   Files exceeding 1,500 LOC are a reliable signal of insufficient
//   decomposition. The ceiling prevents gradual drift toward monolithic files
//   that are expensive to review, test, and understand.
//
// How to resolve a failure:
//   Option A (preferred): Decompose the file into smaller focused modules so
//   that each stays under 1,500 lines.
//   Option B (intentional exception with shrink target): Add an entry to
//   `packages/dartclaw_testing/test/fitness/allowlist/max_file_loc.txt` with
//   the format `<relative-path-from-repo-root>  # <LOC>; <shrink-target>`.
//   The rationale is mandatory, must name the current LOC and a target story
//   or deadline, and will be reviewed at code-review time.

import 'dart:io';

import 'package:test/test.dart';

import '_internal/fitness_test_utils.dart';

const _locLimit = 1500;

void main() {
  late Map<String, String> allowlist;
  late String repoRoot;

  setUpAll(() {
    repoRoot = findRepoRoot();
    allowlist = readAllowlist(repoRoot, 'max_file_loc.txt');
  });

  test('allowlist entries have required rationale format', () {
    final allowlistFile = File('$repoRoot/packages/dartclaw_testing/test/fitness/allowlist/max_file_loc.txt');
    assertAllowlistFormat(allowlistFile, entryFormat: '<relative-path>');
  });

  test('no lib/src/**/*.dart file exceeds $_locLimit lines', () {
    final violations = <String>[];

    final packagesDir = Directory('$repoRoot/packages');
    for (final pkg in packagesDir.listSync().whereType<Directory>()) {
      final srcDir = Directory('${pkg.path}/lib/src');
      if (!srcDir.existsSync()) continue;
      for (final entity in srcDir.listSync(recursive: true).whereType<File>()) {
        if (!entity.path.endsWith('.dart')) continue;
        final relativePath = relativeTo(entity.path, repoRoot).replaceAll('\\', '/');
        if (relativePath.contains('/lib/src/generated/')) continue;
        if (allowlist.containsKey(relativePath)) continue;
        final loc = entity.readAsLinesSync().length;
        if (loc > _locLimit) {
          violations.add(
            '$relativePath: $loc lines (limit $_locLimit) — '
            'decompose or add to allowlist/max_file_loc.txt with rationale',
          );
        }
      }
    }

    if (violations.isNotEmpty) {
      fail(
        'File LOC violations (see packages/dartclaw_testing/test/fitness/README.md):\n'
        '  ${violations.join('\n  ')}',
      );
    }
  });
}
