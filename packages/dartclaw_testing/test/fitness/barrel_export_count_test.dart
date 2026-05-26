// Fitness function: package barrels stay below public export-count ceilings.
//
// How to resolve a failure:
//   Prefer sub-barrels or narrower public surfaces. Temporary breaches must be
//   allowlisted as `<barrel-path>  # <count>; shrink target`.

import 'dart:io';

import 'package:test/test.dart';

import '_internal/fitness_test_utils.dart';

const _caps = {'dartclaw_core': 80, 'dartclaw_config': 50, 'dartclaw_workflow': 35};
const _defaultCap = 25;

void main() {
  late String repoRoot;
  late Map<String, String> allowlist;

  setUpAll(() {
    repoRoot = findRepoRoot();
    allowlist = readAllowlist(repoRoot, 'barrel_export_count.txt');
  });

  test('allowlist entries have required rationale format', () {
    assertAllowlistFormat(File('$repoRoot/packages/dartclaw_testing/test/fitness/allowlist/barrel_export_count.txt'));
  });

  test('barrel export counts stay within package ceilings', () {
    final violations = <String>[];

    for (final barrel in _barrels(repoRoot)) {
      final relative = relativeTo(barrel.path, repoRoot);
      final package = barrel.parent.parent.path.split('/').last;
      final count = barrel.readAsLinesSync().where((line) => line.startsWith('export ')).length;
      final limit = _caps[package] ?? _defaultCap;
      if (count <= limit) continue;
      final allowedCount = _allowedCount(allowlist[relative]);
      if (allowedCount != null && count <= allowedCount) continue;
      violations.add('$relative: $count exports (limit $limit)');
    }

    if (violations.isNotEmpty) {
      fail('Barrel export count violations:\n  ${violations.join('\n  ')}');
    }
  });
}

int? _allowedCount(String? rationale) {
  if (rationale == null) return null;
  final match = RegExp(r'^(\d+)\s+exports\b').firstMatch(rationale);
  return match == null ? null : int.parse(match.group(1)!);
}

Iterable<File> _barrels(String repoRoot) sync* {
  final packagesDir = Directory('$repoRoot/packages');
  for (final pkg in packagesDir.listSync().whereType<Directory>()) {
    final name = pkg.path.split('/').last;
    final barrel = File('${pkg.path}/lib/$name.dart');
    if (barrel.existsSync()) yield barrel;
  }
}
