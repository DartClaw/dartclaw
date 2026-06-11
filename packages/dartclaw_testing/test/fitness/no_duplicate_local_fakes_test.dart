// Fitness function: local test fake class names must not be redeclared.
//
// What this enforces:
//   A local fake/stub/mock/recording class name may appear in one test file.
//   Existing duplicates are allowlisted while they are migrated to shared
//   support such as dartclaw_testing or package-local test support files.
//
// Why:
//   Duplicate fakes drift from the real boundary and from each other. Shared
//   fakes keep test setup shorter and make behavior changes fail in one place.

import 'dart:io';

import 'package:test/test.dart';

final _fakeClassPattern = RegExp(
  r'^\s*(?:final\s+|base\s+|sealed\s+|abstract\s+)?class\s+'
  r'(_?(?:Fake|Recording|Mock|Stub)\w+)\b',
  multiLine: true,
);

void main() {
  late Map<String, String> allowlist;
  late String repoRoot;

  setUpAll(() {
    repoRoot = _findRepoRoot();
    allowlist = _readAllowlist(repoRoot, 'no_duplicate_local_fakes.txt');
  });

  test('allowlist entries have required rationale format', () {
    final allowlistFile = File(
      '$repoRoot/packages/dartclaw_testing/test/fitness/allowlist/no_duplicate_local_fakes.txt',
    );
    _assertAllowlistFormat(allowlistFile);
  });

  test('local fake class names are not redeclared across test files', () {
    final declarations = <String, Set<String>>{};

    for (final file in _findTestFiles(repoRoot)) {
      final relativePath = _relativeTo(file.path, repoRoot);
      final source = file.readAsStringSync();
      for (final match in _fakeClassPattern.allMatches(source)) {
        final className = match.group(1)!;
        declarations.putIfAbsent(className, () => <String>{}).add(relativePath);
      }
    }

    final violations = <String>[];
    for (final entry in declarations.entries) {
      if (entry.value.length < 2) continue;
      if (allowlist.containsKey(entry.key)) continue;
      violations.add(
        '${entry.key} declared in ${entry.value.length} test files:\n'
        '    ${entry.value.toList()..sort()}',
      );
    }

    if (violations.isNotEmpty) {
      fail(
        'Duplicate local fake declarations (see packages/dartclaw_testing/test/fitness/README.md):\n'
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
      'Each non-comment line must be: <ClassName>  # <non-empty rationale>',
    );
  }
}

String _relativeTo(String path, String root) {
  final normalizedRoot = root.endsWith('/') ? root : '$root/';
  return path.startsWith(normalizedRoot) ? path.substring(normalizedRoot.length) : path;
}
