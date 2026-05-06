// Fitness function: enforces the workflow <-> task architectural boundary.
//
// What this enforces:
//   Every `.dart` file under `packages/dartclaw_workflow/lib/src/` may only
//   import from:
//     - `dart:*`
//     - `package:dartclaw_models/...`
//     - `package:dartclaw_core/...`
//     - `package:dartclaw_config/...`
//     - `package:dartclaw_security/...`
//     - third-party packages already declared in dartclaw_workflow's pubspec
//       (currently `logging`, `path`, `uuid`, `yaml`)
//     - relative imports (siblings inside the workflow package)
//
//   It is forbidden to import from:
//     - `package:dartclaw_server/...` (the task/server implementation layer)
//     - `package:dartclaw_storage/...` (concrete SQLite repositories; use the
//       abstract repository interfaces from `dartclaw_core` instead)
//
// Why (see docs/adrs/023-workflow-task-boundary.md in dartclaw-private):
//   The workflow engine orchestrates the task system, it does not replace it.
//   ADR-023 formalises the behavioral contract; this fitness function is the
//   machine-checkable half of that contract for the import direction. Without
//   it, a casual PR could re-couple the workflow package to concrete storage
//   or to the task implementation package and silently undo the decomposition
//   that ADR-021 / ADR-022 / S12 paid for.
//
// How to resolve a legitimate violation:
//   1. If workflow code needs a type from `dartclaw_server` or
//      `dartclaw_storage`, extract an interface into `dartclaw_core` and
//      depend on the interface. `WorkflowRunRepository` (0.16.5 S12) is the
//      reference pattern: abstract in `dartclaw_core`, concrete
//      (`SqliteWorkflowRunRepository`) in `dartclaw_storage`, and workflow
//      code imports the abstract type only.
//   2. If a third-party import is needed, add it to
//      `packages/dartclaw_workflow/pubspec.yaml` `dependencies:` and to the
//      `_allowedThirdParty` set below in the same PR.
//   3. Do not grow `_knownViolations`. That allowlist documents pre-existing
//      debt with a named remediation story; new entries require a new ADR.

import 'dart:io';

import 'package:test/test.dart';

/// Third-party packages already declared in `dartclaw_workflow`'s `pubspec.yaml`.
const _allowedThirdParty = <String>{'logging', 'path', 'uuid', 'yaml'};

/// Internal DartClaw packages the workflow layer may depend on.
const _allowedInternal = <String>{'dartclaw_models', 'dartclaw_core', 'dartclaw_config', 'dartclaw_security'};

/// Packages the workflow layer MUST NOT import from.
const _forbiddenInternal = <String>{'dartclaw_server', 'dartclaw_storage'};

/// Known pre-existing violations, tracked for remediation.
///
/// Each entry is a relative path under `packages/dartclaw_workflow/lib/` and
/// maps to the forbidden package it imports. Entries are removed as the
/// linked story lands. Do not add new entries without an ADR.
const _knownViolations = <String, Set<String>>{};

final _importLine = RegExp(r'''^\s*import\s+['"]([^'"]+)['"]''');
final _packageImport = RegExp(r'''^package:([a-zA-Z_][a-zA-Z0-9_]*)/''');

void main() {
  test('workflow package must not import from dartclaw_server or dartclaw_storage', () {
    final workflowLib = _findWorkflowLib();
    final dartFiles =
        workflowLib.listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart')).toList()
          ..sort((a, b) => a.path.compareTo(b.path));

    final unexpected = <String>[];

    for (final file in dartFiles) {
      final relative = _relativeTo(file.path, workflowLib.path);
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final match = _importLine.firstMatch(lines[i]);
        if (match == null) continue;
        final uri = match.group(1)!;
        if (!uri.startsWith('package:')) continue;

        final pkgMatch = _packageImport.firstMatch(uri);
        if (pkgMatch == null) continue;
        final pkg = pkgMatch.group(1)!;

        if (_forbiddenInternal.contains(pkg)) {
          final whitelisted = _knownViolations[relative]?.contains(pkg) ?? false;
          if (!whitelisted) {
            unexpected.add('$relative:${i + 1}: forbidden import $uri');
          }
          continue;
        }

        if (pkg.startsWith('dartclaw_') && !_allowedInternal.contains(pkg)) {
          unexpected.add('$relative:${i + 1}: unlisted internal dep $uri');
          continue;
        }

        if (!pkg.startsWith('dartclaw_') && !_allowedThirdParty.contains(pkg)) {
          unexpected.add('$relative:${i + 1}: unlisted third-party dep $uri');
        }
      }
    }

    if (unexpected.isNotEmpty) {
      fail(
        'Workflow<->task boundary violations (see ADR-023, '
        'docs/adrs/023-workflow-task-boundary.md):\n  ${unexpected.join('\n  ')}',
      );
    }
  });
}

/// Resolves `packages/dartclaw_workflow/lib/` by walking up from the current
/// working directory. `dart test` may be invoked from either the repo root or
/// from a package directory, so we check both.
Directory _findWorkflowLib() {
  final candidates = <Directory>[];
  for (var dir = Directory.current; dir.parent.path != dir.path; dir = dir.parent) {
    candidates.add(Directory('${dir.path}/packages/dartclaw_workflow/lib'));
    candidates.add(Directory('${dir.path}/../dartclaw_workflow/lib'));
  }
  for (final c in candidates) {
    if (c.existsSync()) return c;
  }
  throw StateError('Could not locate packages/dartclaw_workflow/lib from ${Directory.current.path}');
}

String _relativeTo(String path, String root) {
  final normalizedRoot = root.endsWith('/') ? root : '$root/';
  return path.startsWith(normalizedRoot) ? path.substring(normalizedRoot.length) : path;
}
