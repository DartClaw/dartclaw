// Fitness function: enforces that dartclaw_testing production lib has no
// dartclaw_server dependency.
//
// Why: after S11, TurnManager/HarnessPool/GoogleJwtVerifier abstract interfaces
// live in dartclaw_core. dartclaw_testing fakes implement the core interfaces
// directly, so dartclaw_server is no longer a production dependency of this
// package. This test catches any accidental re-introduction.

import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('dartclaw_testing lib/ must not import from dartclaw_server', () {
    final libDir = _findTestingLib();
    final dartFiles = libDir.listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart')).toList()
      ..sort((a, b) => a.path.compareTo(b.path));

    final violations = <String>[];
    final importLine = RegExp(r'''^\s*import\s+['"]([^'"]+)['"]''');

    for (final file in dartFiles) {
      final relative = _relativeTo(file.path, libDir.path);
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final match = importLine.firstMatch(lines[i]);
        if (match == null) continue;
        final uri = match.group(1)!;
        if (uri.startsWith('package:dartclaw_server/')) {
          violations.add('$relative:${i + 1}: forbidden import $uri');
        }
      }
    }

    if (violations.isNotEmpty) {
      fail(
        'dartclaw_testing lib/ must not import dartclaw_server '
        '(move dartclaw_server to dev_dependencies):\n  ${violations.join('\n  ')}',
      );
    }
  });
}

Directory _findTestingLib() {
  for (var dir = Directory.current; dir.parent.path != dir.path; dir = dir.parent) {
    final candidate = Directory('${dir.path}/packages/dartclaw_testing/lib');
    if (candidate.existsSync()) return candidate;
    final sibling = Directory('${dir.path}/../dartclaw_testing/lib');
    if (sibling.existsSync()) return sibling;
  }
  throw StateError('Could not locate packages/dartclaw_testing/lib from ${Directory.current.path}');
}

String _relativeTo(String path, String root) {
  final normalizedRoot = root.endsWith('/') ? root : '$root/';
  return path.startsWith(normalizedRoot) ? path.substring(normalizedRoot.length) : path;
}
