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

void main() {
  late Map<String, String> allowlist;
  late String repoRoot;

  setUpAll(() {
    repoRoot = _findRepoRoot();
    allowlist = _readAllowlist(repoRoot, 'no_cross_package_env_plan_duplicates.txt');
  });

  test('allowlist entries have required rationale format', () {
    final allowlistFile = File(
      '$repoRoot/packages/dartclaw_testing/test/fitness/allowlist/no_cross_package_env_plan_duplicates.txt',
    );
    _assertAllowlistFormat(allowlistFile);
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

          final relativePath = _relativeTo(file.path, repoRoot);
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

String _findRepoRoot() {
  for (var dir = Directory.current; dir.parent.path != dir.path; dir = dir.parent) {
    if (File('${dir.path}/pubspec.yaml').existsSync() && Directory('${dir.path}/packages').existsSync()) {
      return dir.path;
    }
  }
  throw StateError('Could not locate repo root from ${Directory.current.path}');
}

Map<String, String> _readAllowlist(String repoRoot, String filename) {
  final file = File('$repoRoot/packages/dartclaw_testing/test/fitness/allowlist/$filename');
  if (!file.existsSync()) return {};
  final result = <String, String>{};
  for (final line in file.readAsLinesSync()) {
    final stripped = line.trim();
    if (stripped.isEmpty || stripped.startsWith('#')) continue;
    final sep = stripped.indexOf('  # ');
    if (sep < 0) continue;
    result[stripped.substring(0, sep)] = stripped.substring(sep + 4);
  }
  return result;
}

void _assertAllowlistFormat(File allowlistFile) {
  if (!allowlistFile.existsSync()) return;
  final bad = <String>[];
  final lines = allowlistFile.readAsLinesSync();
  for (var i = 0; i < lines.length; i++) {
    final stripped = lines[i].trim();
    if (stripped.isEmpty || stripped.startsWith('#')) continue;
    final sep = stripped.indexOf('  # ');
    if (sep < 0) {
      bad.add('line ${i + 1}: missing "  # " separator');
      continue;
    }
    if (stripped.substring(sep + 4).trim().isEmpty) {
      bad.add('line ${i + 1}: rationale is empty');
    }
  }
  if (bad.isNotEmpty) {
    fail(
      'Malformed allowlist ${allowlistFile.path}:\n'
      '  ${bad.join('\n  ')}\n'
      'Each non-comment line must be: <ClassName>@<relative-path>  # <non-empty rationale>',
    );
  }
}

String _relativeTo(String path, String root) {
  final normalizedRoot = root.endsWith('/') ? root : '$root/';
  return path.startsWith(normalizedRoot) ? path.substring(normalizedRoot.length) : path;
}
