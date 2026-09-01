import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' show MemoryResourceLimits;
import 'package:dartclaw_runtime/src/memory/workspace_file_reader.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_workspace_reader_');
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  test('bounded directory selection is independent of creation order', () async {
    Future<List<String>> select(String directoryName, List<String> creationOrder) async {
      final workspace = Directory('${tempDir.path}/$directoryName')..createSync();
      final memory = Directory('${workspace.path}/memory')..createSync();
      for (final name in creationOrder) {
        File('${memory.path}/$name').writeAsStringSync(name);
      }
      final scan = await WorkspaceFileReader(workspace.path).readDirectoryBounded('memory', limit: 2);
      expect(scan.complete, isTrue);
      return scan.entries.map((entry) => entry.name).toList();
    }

    expect(await select('forward', ['a.md', 'm.md', 'z.md']), ['a.md', 'm.md']);
    expect(await select('reverse', ['z.md', 'm.md', 'a.md']), ['a.md', 'm.md']);
  });

  test('bounded directory selection reports indeterminate coverage without an arbitrary prefix', () async {
    final memory = Directory('${tempDir.path}/memory')..createSync();
    for (var index = 0; index < MemoryResourceLimits.recursiveFiles * 2 + 2; index++) {
      Directory('${memory.path}/d${index.toString().padLeft(4, '0')}').createSync();
    }

    final scan = await WorkspaceFileReader(tempDir.path).readDirectoryBounded(
      'memory',
      limit: MemoryResourceLimits.recursiveFiles,
      include: (name) => name.endsWith('.md'),
    );

    expect(scan.complete, isFalse);
    expect(scan.entries, isEmpty);
    expect(scan.firstOmitted, isNull);
    expect(scan.omittedCount, 0);
  });
}
