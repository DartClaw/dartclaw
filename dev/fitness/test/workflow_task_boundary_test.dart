// Fitness function: the workflow package's dependency set is narrower than its
// tier position allows.
//
// What this enforces:
//   Every `.dart` file under `packages/dartclaw_workflow/lib/src/` may import
//   only `dart:*`, relative siblings, `package:dartclaw_kernel/`,
//   `package:dartclaw_core/`, and the third-party packages the workflow pubspec
//   already declares.
//
// Why (ADR-023, docs/adrs/023-workflow-task-boundary.md in dartclaw-private):
//   The workflow engine orchestrates the task system; it does not replace it.
//   The tier order in dev/package_tiers.txt already forbids the upward edge to
//   `dartclaw_runtime` and the same-tier edges to the channel packages, and
//   dependency_direction_test.dart is the one authority for those. What it does
//   NOT forbid is a downward edge to `dartclaw_bridge` or `dartclaw_client`,
//   which are a legal tier below. ADR-023 says kernel and core only, so that
//   narrower rule lives here.
//
// How to resolve a legitimate violation:
//   1. A type needed from another DartClaw package: extract an interface into
//      `dartclaw_core` or `dartclaw_kernel` and depend on that.
//   2. A new third-party import: add it to
//      `packages/dartclaw_workflow/pubspec.yaml` `dependencies:` and to
//      `_allowedThirdParty` below, in the same change.
//   There is no allowlist. An edge that cannot be expressed here needs an ADR.

import 'dart:io';

import 'package:test/test.dart';

import '_internal/fitness_test_utils.dart';

/// Third-party packages already declared in `dartclaw_workflow`'s `pubspec.yaml`.
const _allowedThirdParty = <String>{'logging', 'path', 'sqlite3', 'uuid', 'yaml'};

/// Internal DartClaw packages the workflow layer may depend on.
const _allowedInternal = <String>{'dartclaw_core', 'dartclaw_kernel'};

final _importLine = RegExp(r'''^\s*import\s+['"]([^'"]+)['"]''');
final _packageImport = RegExp(r'''^package:([a-zA-Z_][a-zA-Z0-9_]*)/''');

void main() {
  test('the workflow package imports kernel, core and its declared third-party packages only', () {
    final repoRoot = findRepoRoot();
    final workflowLib = Directory('$repoRoot/packages/dartclaw_workflow/lib');
    if (!workflowLib.existsSync()) fail('Missing ${relativeTo(workflowLib.path, repoRoot)}');

    final dartFiles =
        workflowLib.listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart')).toList()
          ..sort((a, b) => a.path.compareTo(b.path));

    final unexpected = <String>[];
    for (final file in dartFiles) {
      final relative = relativeTo(file.path, repoRoot);
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final uri = _importLine.firstMatch(lines[i])?.group(1);
        if (uri == null || !uri.startsWith('package:')) continue;
        final pkg = _packageImport.firstMatch(uri)?.group(1);
        if (pkg == null) continue;

        if (isDartclawPackage(pkg)) {
          if (!_allowedInternal.contains(pkg)) unexpected.add('$relative:${i + 1}: unlisted internal dep $uri');
        } else if (!_allowedThirdParty.contains(pkg)) {
          unexpected.add('$relative:${i + 1}: unlisted third-party dep $uri');
        }
      }
    }

    if (unexpected.isNotEmpty) {
      fail(
        'Workflow dependency-set violations (ADR-023; direction itself is $packageTiersPath\'s):\n'
        '  ${unexpected.join('\n  ')}',
      );
    }
  });
}
