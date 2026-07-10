import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:dartclaw_workflow/src/generated/embedded_assets.g.dart';
import 'package:test/test.dart';

void main() {
  test('S01 embedded workflow assets match every source byte', () async {
    final packageRoot = await _packageRoot();
    final expected = <String, List<int>>{};

    _collectAssets(Directory('$packageRoot/skills'), 'skills', expected);
    _collectAssets(Directory('$packageRoot/lib/src/workflow/definitions'), 'workflows', expected);

    expect(embeddedWorkflowAssets.keys.toSet(), expected.keys.toSet());
    for (final entry in expected.entries) {
      expect(utf8.encode(embeddedWorkflowAssets[entry.key]!), entry.value, reason: entry.key);
    }
    expect(() => embeddedWorkflowAssets['unexpected'] = 'value', throwsUnsupportedError);
  });
}

void _collectAssets(Directory root, String prefix, Map<String, List<int>> result) {
  for (final file in root.listSync(recursive: true).whereType<File>()) {
    final relative = file.path.substring(root.path.length + 1).replaceAll('\\', '/');
    if (relative.split('/').any((part) => part.startsWith('.'))) {
      continue;
    }
    result['$prefix/$relative'] = file.readAsBytesSync();
  }
}

Future<String> _packageRoot() async {
  final library = await Isolate.resolvePackageUri(Uri.parse('package:dartclaw_workflow/dartclaw_workflow.dart'));
  if (library == null) {
    throw StateError('Could not resolve dartclaw_workflow package root');
  }
  return File.fromUri(library).parent.parent.path;
}
