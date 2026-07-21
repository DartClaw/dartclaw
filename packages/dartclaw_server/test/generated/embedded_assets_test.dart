import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:dartclaw_server/src/generated/embedded_assets.g.dart';
import 'package:test/test.dart';

void main() {
  test('S01 embedded server assets match every runtime-read source byte', () async {
    final packageRoot = await _packageRoot();
    final expectedText = <String, List<int>>{};
    final expectedBinary = <String, List<int>>{};

    _collectAssets(Directory('$packageRoot/lib/src/templates'), 'templates', expectedText, excludeDart: true);
    _collectAssets(Directory('$packageRoot/lib/src/static'), 'static', expectedText, binary: expectedBinary);

    expect(embeddedServerAssets.keys.toSet(), expectedText.keys.toSet());
    for (final entry in expectedText.entries) {
      expect(utf8.encode(embeddedServerAssets[entry.key]!), entry.value, reason: entry.key);
    }
    expect(embeddedServerBinaryAssets.keys.toSet(), expectedBinary.keys.toSet());
    for (final entry in expectedBinary.entries) {
      expect(embeddedServerBinaryAssets[entry.key], entry.value, reason: entry.key);
    }
    final firstBinary = embeddedServerBinaryAssets[expectedBinary.keys.first]!;
    expect(() => firstBinary[0] = 0, throwsUnsupportedError);
    expect(() => embeddedServerAssets['unexpected'] = 'value', throwsUnsupportedError);
    expect(() => embeddedServerBinaryAssets['unexpected'] = <int>[1], throwsUnsupportedError);
  });
}

void _collectAssets(
  Directory root,
  String prefix,
  Map<String, List<int>> text, {
  Map<String, List<int>>? binary,
  bool excludeDart = false,
}) {
  for (final file in root.listSync(recursive: true).whereType<File>()) {
    final relative = file.path.substring(root.path.length + 1).replaceAll('\\', '/');
    if (relative.split('/').any((part) => part.startsWith('.')) || (excludeDart && relative.endsWith('.dart'))) {
      continue;
    }
    final key = '$prefix/$relative';
    if (binary != null && relative.toLowerCase().endsWith('.png')) {
      binary[key] = file.readAsBytesSync();
    } else {
      text[key] = file.readAsBytesSync();
    }
  }
}

Future<String> _packageRoot() async {
  final library = await Isolate.resolvePackageUri(Uri.parse('package:dartclaw_server/dartclaw_server.dart'));
  if (library == null) {
    throw StateError('Could not resolve dartclaw_server package root');
  }
  return File.fromUri(library).parent.parent.path;
}
