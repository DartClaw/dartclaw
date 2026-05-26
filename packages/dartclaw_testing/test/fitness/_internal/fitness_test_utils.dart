import 'dart:io';

import 'package:test/test.dart';

String findRepoRoot() {
  for (var dir = Directory.current; dir.parent.path != dir.path; dir = dir.parent) {
    if (File('${dir.path}/pubspec.yaml').existsSync() && Directory('${dir.path}/packages').existsSync()) {
      return dir.path;
    }
  }
  throw StateError('Could not locate repo root from ${Directory.current.path}');
}

Map<String, String> readAllowlist(String repoRoot, String filename) {
  final file = File('$repoRoot/packages/dartclaw_testing/test/fitness/allowlist/$filename');
  if (!file.existsSync()) return {};
  assertAllowlistFormat(file);
  final result = <String, String>{};
  for (final line in file.readAsLinesSync()) {
    final stripped = line.trim();
    if (stripped.isEmpty || stripped.startsWith('#')) continue;
    final sep = stripped.indexOf('  # ');
    result[stripped.substring(0, sep)] = stripped.substring(sep + 4).trim();
  }
  return result;
}

void assertAllowlistFormat(File allowlistFile) {
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

Iterable<File> productionDartFiles(String repoRoot, {bool srcOnly = false}) sync* {
  for (final rootName in const ['packages', 'apps']) {
    final root = Directory('$repoRoot/$rootName');
    if (!root.existsSync()) continue;
    for (final member in root.listSync().whereType<Directory>()) {
      final lib = Directory('${member.path}/lib${srcOnly ? '/src' : ''}');
      if (!lib.existsSync()) continue;
      yield* lib.listSync(recursive: true).whereType<File>().where((file) => file.path.endsWith('.dart'));
    }
  }
}

String ownerPackageFor(String repoRoot, File file) {
  final relative = relativeTo(file.path, repoRoot);
  final parts = relative.split('/');
  if (parts.length >= 3 && (parts.first == 'packages' || parts.first == 'apps')) {
    return parts[1];
  }
  throw StateError('Cannot determine owner package for $relative');
}

String relativeTo(String path, String root) {
  final normalizedRoot = root.endsWith('/') ? root : '$root/';
  return path.startsWith(normalizedRoot) ? path.substring(normalizedRoot.length) : path;
}
