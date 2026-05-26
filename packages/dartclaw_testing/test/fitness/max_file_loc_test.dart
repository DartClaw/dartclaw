// Fitness function: no production file under lib/src/ may exceed 1,500 LOC.
//
// What this enforces:
//   Every `.dart` file under `packages/<X>/lib/src/**` must have ≤ 1,500 lines.
//   Known intentional violators are listed in `allowlist/max_file_loc.txt` with
//   a shrink-target rationale — they are tracked for remediation, not forgotten.
//
// Why:
//   Files exceeding 1,500 LOC are a reliable signal of insufficient
//   decomposition. The ceiling prevents gradual drift toward monolithic files
//   that are expensive to review, test, and understand.
//
// How to resolve a failure:
//   Option A (preferred): Decompose the file into smaller focused modules so
//   that each stays under 1,500 lines.
//   Option B (intentional exception with shrink target): Add an entry to
//   `packages/dartclaw_testing/test/fitness/allowlist/max_file_loc.txt` with
//   the format `<relative-path-from-repo-root>  # <LOC>; <shrink-target>`.
//   The rationale is mandatory, must name the current LOC and a target story
//   or deadline, and will be reviewed at code-review time.

import 'dart:io';

import 'package:test/test.dart';

const _locLimit = 1500;

void main() {
  late Set<String> allowlist;
  late String repoRoot;

  setUpAll(() {
    repoRoot = _findRepoRoot();
    allowlist = _readAllowlist(repoRoot, 'max_file_loc.txt');
  });

  test('allowlist entries have required rationale format', () {
    final allowlistFile = File('$repoRoot/packages/dartclaw_testing/test/fitness/allowlist/max_file_loc.txt');
    _assertAllowlistFormat(allowlistFile);
  });

  test('no lib/src/**/*.dart file exceeds $_locLimit lines', () {
    final violations = <String>[];

    final packagesDir = Directory('$repoRoot/packages');
    for (final pkg in packagesDir.listSync().whereType<Directory>()) {
      final srcDir = Directory('${pkg.path}/lib/src');
      if (!srcDir.existsSync()) continue;
      for (final entity in srcDir.listSync(recursive: true).whereType<File>()) {
        if (!entity.path.endsWith('.dart')) continue;
        final relativePath = _relativeTo(entity.path, repoRoot);
        if (allowlist.contains(relativePath)) continue;
        final loc = entity.readAsLinesSync().length;
        if (loc > _locLimit) {
          violations.add(
            '$relativePath: $loc lines (limit $_locLimit) — '
            'decompose or add to allowlist/max_file_loc.txt with rationale',
          );
        }
      }
    }

    if (violations.isNotEmpty) {
      fail(
        'File LOC violations (see packages/dartclaw_testing/test/fitness/README.md):\n'
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
