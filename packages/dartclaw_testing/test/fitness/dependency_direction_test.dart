// Fitness function: workspace DartClaw package imports must follow the allowed edge table.
//
// How to resolve a failure:
//   If the new edge is intentional, add `<from> -> <to>  # <rationale>` to
//   allowlist/dependency_direction.txt. The rationale is mandatory and reviewed.
//   Do not add dartclaw_workflow -> dartclaw_storage; workflow must depend on
//   core-owned repository interfaces, not concrete SQLite storage.

import 'dart:io';

import 'package:test/test.dart';

import '_internal/fitness_test_utils.dart';

final _importLine = RegExp(r'''^\s*import\s+['"]([^'"]+)['"]''');
final _packageImport = RegExp(r'''^package:([a-zA-Z_][a-zA-Z0-9_]*)/''');
final _sqliteWorkflowRepoImport = RegExp(r'''^package:dartclaw_storage/.*sqlite_workflow_run_repository.*''');

void main() {
  late String repoRoot;
  late Map<String, String> allowedEdges;

  setUpAll(() {
    repoRoot = findRepoRoot();
    allowedEdges = readAllowlist(repoRoot, 'dependency_direction.txt');
  });

  test('allowlist entries have required rationale format', () {
    assertAllowlistFormat(File('$repoRoot/packages/dartclaw_testing/test/fitness/allowlist/dependency_direction.txt'));
  });

  test('workspace package imports match the allowed edge table', () {
    final violations = <String>[];

    for (final file in productionDartFiles(repoRoot)) {
      final owner = ownerPackageFor(repoRoot, file);
      final relative = relativeTo(file.path, repoRoot);
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final match = _importLine.firstMatch(lines[i]);
        if (match == null) continue;
        final uri = match.group(1)!;
        final pkg = _packageImport.firstMatch(uri)?.group(1);
        if (pkg == null || pkg == owner || !_isDartClawPackage(pkg)) continue;

        if (owner == 'dartclaw_workflow' && _sqliteWorkflowRepoImport.hasMatch(uri)) {
          violations.add('$relative:${i + 1}: workflow production code must not import SqliteWorkflowRunRepository');
          continue;
        }

        final edge = '$owner -> $pkg';
        if (!allowedEdges.containsKey(edge)) {
          violations.add(
            '$relative:${i + 1}: $owner -> $pkg edge not in allowed-edges table; '
            'see test/fitness/allowlist/dependency_direction.txt',
          );
        }
      }
    }

    if (violations.isNotEmpty) {
      fail('Dependency direction violations:\n  ${violations.join('\n  ')}');
    }
  });
}

bool _isDartClawPackage(String package) =>
    package == 'dartclaw' || package == 'dartclaw_cli' || package.startsWith('dartclaw_');
