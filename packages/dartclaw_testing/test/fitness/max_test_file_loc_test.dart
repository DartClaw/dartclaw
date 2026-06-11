// Fitness function: no test file may exceed 800 LOC unless allowlisted.
//
// What this enforces:
//   Every `*_test.dart` file under packages/ and apps/ must have <= 800 lines.
//   Known baseline violators are listed in `allowlist/max_test_file_loc.txt`
//   with a shrink-target rationale.
//
// Why:
//   Large tests hide redundant cases and discourage behavior-focused additions.
//   The ceiling prevents new mega-tests while the existing reduction plan pays
//   down the current baseline.

import 'dart:io';

import 'package:test/test.dart';

const _locLimit = 800;

void main() {
  late Set<String> allowlist;
  late String repoRoot;

  setUpAll(() {
    repoRoot = _findRepoRoot();
    allowlist = _readAllowlist(repoRoot, 'max_test_file_loc.txt');
  });

  test('allowlist entries have required rationale format', () {
    final allowlistFile = File('$repoRoot/packages/dartclaw_testing/test/fitness/allowlist/max_test_file_loc.txt');
    _assertAllowlistFormat(allowlistFile);
  });

  test('no *_test.dart file exceeds $_locLimit lines unless allowlisted', () {
    final violations = <String>[];

    for (final file in _findTestFiles(repoRoot)) {
      final relativePath = _relativeTo(file.path, repoRoot);
      if (allowlist.contains(relativePath)) continue;
      final loc = file.readAsLinesSync().length;
      if (loc > _locLimit) {
        violations.add(
          '$relativePath: $loc lines (limit $_locLimit) - '
          'table-drive, extract fixtures, split, or add a shrink-target allowlist entry',
        );
      }
    }

    if (violations.isNotEmpty) {
      fail(
        'Test file LOC violations (see packages/dartclaw_testing/test/fitness/README.md):\n'
        '  ${violations.join('\n  ')}',
      );
    }
  });
}

Iterable<File> _findTestFiles(String repoRoot) sync* {
  for (final baseDir in ['packages', 'apps']) {
    final dir = Directory('$repoRoot/$baseDir');
    if (!dir.existsSync()) continue;
    for (final file in dir.listSync(recursive: true).whereType<File>()) {
      if (file.path.endsWith('_test.dart')) yield file;
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

Set<String> _readAllowlist(String repoRoot, String filename) {
  final file = File('$repoRoot/packages/dartclaw_testing/test/fitness/allowlist/$filename');
  if (!file.existsSync()) return {};
  final result = <String>{};
  for (final line in file.readAsLinesSync()) {
    final stripped = line.trim();
    if (stripped.isEmpty || stripped.startsWith('#')) continue;
    final sep = stripped.indexOf('  # ');
    if (sep < 0) continue;
    result.add(stripped.substring(0, sep));
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
      'Each non-comment line must be: <relative-path>  # <non-empty rationale>',
    );
  }
}

String _relativeTo(String path, String root) {
  final normalizedRoot = root.endsWith('/') ? root : '$root/';
  return path.startsWith(normalizedRoot) ? path.substring(normalizedRoot.length) : path;
}
