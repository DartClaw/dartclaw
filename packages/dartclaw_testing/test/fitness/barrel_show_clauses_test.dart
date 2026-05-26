// Fitness function: every barrel export must carry an explicit `show` clause.
//
// What this enforces:
//   Every `export 'src/...'` line in a package's top-level barrel file
//   (packages/<X>/lib/<X>.dart or apps/<X>/lib/<X>.dart) must include a
//   `show` clause listing the exported symbols explicitly. Wholesale exports
//   (`export 'src/foo.dart'` with no `show`) are allowlisted in
//   `allowlist/barrel_show_clauses.txt` with mandatory rationale comments.
//
// Why:
//   Wholesale barrel exports silently surface all public symbols of the
//   re-exported file, making it impossible to tell at a glance what a package
//   advertises. Explicit `show` clauses are the machine-checkable counterpart
//   to code-review scrutiny: any new unexplained symbol causes a CI failure.
//
// How to resolve a failure:
//   Option A (preferred): Add a `show SymbolName` clause to the failing export
//   line in the barrel file.
//   Option B (intentional exception): Add an entry to
//   `packages/dartclaw_testing/test/fitness/allowlist/barrel_show_clauses.txt`
//   with the format `<file>:<line>  # <rationale>`. The rationale is mandatory
//   and will be reviewed at code-review time.

import 'dart:io';

import 'package:test/test.dart';

void main() {
  late Map<String, String> allowlist;
  late String repoRoot;

  setUpAll(() {
    repoRoot = _findRepoRoot();
    allowlist = _readAllowlist(repoRoot, 'barrel_show_clauses.txt');
  });

  test('allowlist entries have required rationale format', () {
    final allowlistFile = File('$repoRoot/packages/dartclaw_testing/test/fitness/allowlist/barrel_show_clauses.txt');
    _assertAllowlistFormat(allowlistFile);
  });

  test('all barrel exports have show clauses or are allowlisted', () {
    final violations = <String>[];

    for (final barrelFile in _findBarrels(repoRoot)) {
      final relativePath = _relativeTo(barrelFile.path, repoRoot);
      final lines = barrelFile.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        if (!_wholesaleExport.hasMatch(line)) continue;
        final key = '$relativePath:${i + 1}';
        if (!allowlist.containsKey(key)) {
          violations.add(
            '$key: wholesale export missing show clause — add show clause or allowlist in barrel_show_clauses.txt',
          );
        }
      }
    }

    if (violations.isNotEmpty) {
      fail(
        'Barrel show-clause violations (see packages/dartclaw_testing/test/fitness/README.md):\n'
        '  ${violations.join('\n  ')}',
      );
    }
  });
}

final _wholesaleExport = RegExp(r'''^export 'src/[^']+\.dart'\s*;''');

/// Finds every package/app barrel file in the repo.
Iterable<File> _findBarrels(String repoRoot) sync* {
  final packagesDir = Directory('$repoRoot/packages');
  for (final pkg in packagesDir.listSync().whereType<Directory>()) {
    final name = pkg.path.split('/').last;
    final barrel = File('${pkg.path}/lib/$name.dart');
    if (barrel.existsSync()) yield barrel;
  }

  final appsDir = Directory('$repoRoot/apps');
  if (appsDir.existsSync()) {
    for (final app in appsDir.listSync().whereType<Directory>()) {
      final name = app.path.split('/').last;
      final barrel = File('${app.path}/lib/$name.dart');
      if (barrel.existsSync()) yield barrel;
    }
  }
}

String _findRepoRoot() {
  for (var dir = Directory.current; dir.parent.path != dir.path; dir = dir.parent) {
    if (File('${dir.path}/pubspec.yaml').existsSync() && Directory('${dir.path}/packages').existsSync()) {
      return dir.path;
    }
  }
  throw StateError('Could not locate repo root from ${Directory.current.path}');
}

/// Reads allowlist; keys are `<relative-path>:<line>`, values are rationale.
Map<String, String> _readAllowlist(String repoRoot, String filename) {
  final file = File('$repoRoot/packages/dartclaw_testing/test/fitness/allowlist/$filename');
  if (!file.existsSync()) return {};
  final result = <String, String>{};
  for (final line in file.readAsLinesSync()) {
    final stripped = line.trim();
    if (stripped.isEmpty || stripped.startsWith('#')) continue;
    final sep = stripped.indexOf('  # ');
    if (sep < 0) continue; // format errors caught by separate test
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
      'Each non-comment line must be: <pattern>  # <non-empty rationale>',
    );
  }
}

String _relativeTo(String path, String root) {
  final normalizedRoot = root.endsWith('/') ? root : '$root/';
  return path.startsWith(normalizedRoot) ? path.substring(normalizedRoot.length) : path;
}
