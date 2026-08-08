// Fitness function: ProcessEnvironmentPlan implementations must live in dartclaw_security.
//
// What this enforces:
//   Any class that implements `ProcessEnvironmentPlan` must live inside
//   `packages/dartclaw_security/`. Implementations in other packages duplicate
//   the canonical type from dartclaw_security and create drift risk.
//   Genuine exceptions (e.g. credential-carrying impls that belong with the
//   credential logic) are listed in `allowlist/no_cross_package_env_plan_duplicates.txt`.
//
// Why (see Shared Decision #12):
//   `InlineProcessEnvironmentPlan` and `ProcessEnvironmentPlan.empty` are the
//   canonical concrete types. Duplicating them across packages causes
//   behavioural divergence and makes security auditing harder. S32 promoted
//   all non-security impls to dartclaw_security; this fitness test prevents
//   re-introduction.
//
// How to resolve a failure:
//   Option A (preferred): Delete the cross-package impl and use
//   `InlineProcessEnvironmentPlan` from `dartclaw_security` instead.
//   Option B (genuine credential-carrying impl): Add an entry to
//   `packages/dartclaw_testing/test/fitness/allowlist/no_cross_package_env_plan_duplicates.txt`
//   with format `<ClassName>@<relative-file-path>  # <rationale>`. The
//   rationale must explain why this impl cannot live in dartclaw_security.

import 'dart:io';

import 'package:test/test.dart';

import '_internal/fitness_test_utils.dart';

void main() {
  late Map<String, String> allowlist;
  late String repoRoot;

  setUpAll(() {
    repoRoot = findRepoRoot();
    allowlist = readAllowlist(repoRoot, 'no_cross_package_env_plan_duplicates.txt');
  });

  test('allowlist entries have required rationale format', () {
    final allowlistFile = File(
      '$repoRoot/packages/dartclaw_testing/test/fitness/allowlist/no_cross_package_env_plan_duplicates.txt',
    );
    assertAllowlistFormat(allowlistFile, entryFormat: '<ClassName>@<relative-path>');
  });

  test('ProcessEnvironmentPlan implementations only in dartclaw_security or allowlisted', () {
    final violations = <String>[];
    final implPattern = RegExp(r'class\s+(\w+)[^{]*\bimplements\b[^{]*\bProcessEnvironmentPlan\b');
    final securityPrefix = 'packages/dartclaw_security/';

    for (final baseDir in ['packages', 'apps']) {
      final dir = Directory('$repoRoot/$baseDir');
      if (!dir.existsSync()) continue;
      for (final pkg in dir.listSync().whereType<Directory>()) {
        final libDir = Directory('${pkg.path}/lib');
        if (!libDir.existsSync()) continue;
        for (final file in libDir.listSync(recursive: true).whereType<File>()) {
          if (!file.path.endsWith('.dart')) continue;
          // Exclude test files.
          if (file.path.contains('/test/')) continue;

          final relativePath = relativeTo(file.path, repoRoot);
          if (relativePath.startsWith(securityPrefix)) continue;

          final source = file.readAsStringSync();
          for (final match in implPattern.allMatches(source)) {
            final className = match.group(1)!;
            final key = '$className@$relativePath';
            if (!allowlist.containsKey(key)) {
              final line = '\n'.allMatches(source.substring(0, match.start)).length + 1;
              violations.add(
                '$relativePath:$line: $className implements ProcessEnvironmentPlan outside dartclaw_security — '
                'use InlineProcessEnvironmentPlan or add to allowlist/no_cross_package_env_plan_duplicates.txt',
              );
            }
          }
        }
      }
    }

    if (violations.isNotEmpty) {
      fail(
        'Cross-package ProcessEnvironmentPlan violations (see packages/dartclaw_testing/test/fitness/README.md):\n'
        '  ${violations.join('\n  ')}',
      );
    }
  });
}
