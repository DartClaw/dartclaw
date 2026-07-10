import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:dartclaw_server/src/generated/embedded_assets.g.dart';
import 'package:test/test.dart';

void main() {
  test('S01 embedded server assets match every runtime-read source byte', () async {
    final packageRoot = await _packageRoot();
    final expected = <String, List<int>>{};

    _collectAssets(Directory('$packageRoot/lib/src/templates'), 'templates', expected, excludeDart: true);
    _collectAssets(Directory('$packageRoot/lib/src/static'), 'static', expected);

    expect(embeddedServerAssets.keys.toSet(), expected.keys.toSet());
    for (final entry in expected.entries) {
      expect(utf8.encode(embeddedServerAssets[entry.key]!), entry.value, reason: entry.key);
    }
    expect(() => embeddedServerAssets['unexpected'] = 'value', throwsUnsupportedError);
  });
}

void _collectAssets(Directory root, String prefix, Map<String, List<int>> result, {bool excludeDart = false}) {
  for (final file in root.listSync(recursive: true).whereType<File>()) {
    final relative = file.path.substring(root.path.length + 1).replaceAll('\\', '/');
    if (relative.split('/').any((part) => part.startsWith('.')) || (excludeDart && relative.endsWith('.dart'))) {
      continue;
    }
    result['$prefix/$relative'] = file.readAsBytesSync();
  }
}

Future<String> _packageRoot() async {
  final library = await Isolate.resolvePackageUri(Uri.parse('package:dartclaw_server/dartclaw_server.dart'));
  if (library == null) {
    throw StateError('Could not resolve dartclaw_server package root');
  }
  return File.fromUri(library).parent.parent.path;
}
