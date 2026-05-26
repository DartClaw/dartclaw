// Fitness function: production files stay below the method-count ceiling.
//
// How to resolve a failure:
//   Split the file by responsibility. Temporary breaches must be allowlisted as
//   `<relative-path>  # <count> methods; shrink to <=40 by <story/version>`.

import 'dart:io';

import 'package:test/test.dart';

import '_internal/fitness_test_utils.dart';

const _limit = 40;

final _methodLike = RegExp(
  r'^\s{2,}(?:static\s+|external\s+)?(?:[A-Za-z_<][A-Za-z0-9_<>, ?]*\s+)?(?:get|set|operator|[A-Za-z_][A-Za-z0-9_]*)\s+[A-Za-z_+\-*/%<>=~\[\]][A-Za-z0-9_+\-*/%<>=~\[\]]*\s*[\(<]',
);

void main() {
  late String repoRoot;
  late Map<String, String> allowlist;

  setUpAll(() {
    repoRoot = findRepoRoot();
    allowlist = readAllowlist(repoRoot, 'max_method_count_per_file.txt');
  });

  test('allowlist entries have required rationale format', () {
    assertAllowlistFormat(
      File('$repoRoot/packages/dartclaw_testing/test/fitness/allowlist/max_method_count_per_file.txt'),
    );
  });

  test('production source files stay under the method-count ceiling', () {
    final violations = <String>[];

    for (final file in productionDartFiles(repoRoot, srcOnly: true)) {
      final relative = relativeTo(file.path, repoRoot);
      final count = _methodCount(file);
      if (count <= _limit) continue;
      final allowedCount = _allowedCount(allowlist[relative]);
      if (allowedCount != null && count <= allowedCount) continue;
      violations.add('$relative: $count methods (limit $_limit); see allowlist/max_method_count_per_file.txt');
    }

    if (violations.isNotEmpty) {
      fail('Method-count violations:\n  ${violations.join('\n  ')}');
    }
  });
}

int? _allowedCount(String? rationale) {
  if (rationale == null) return null;
  final match = RegExp(r'^(\d+)\s+methods\b').firstMatch(rationale);
  return match == null ? null : int.parse(match.group(1)!);
}

int _methodCount(File file) {
  var count = 0;
  for (final line in file.readAsLinesSync()) {
    final trimmed = line.trimLeft();
    if (trimmed.startsWith('//') || trimmed.startsWith('*') || trimmed.startsWith('typedef ')) continue;
    if (_methodLike.hasMatch(line)) count += 1;
  }
  return count;
}
