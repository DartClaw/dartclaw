import 'dart:io';

import 'package:dartclaw_cli/src/commands/rebuild_index_command.dart';
import 'package:dartclaw_cli/src/runner.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_storage/dartclaw_storage.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late List<String> output;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_rebuild_idx_test_');
    output = [];
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Future<void> runCommand(DartclawConfig config) async {
    final runner = DartclawRunner()
      ..addCommand(
        RebuildIndexCommand(config: config, writeLine: output.add, searchDbFactory: (_) => openSearchDbInMemory()),
      );
    await runner.run(['rebuild-index']);
  }

  test('prints message when MEMORY.md is missing', () async {
    final config = DartclawConfig(dataDir: tempDir.path);
    await runCommand(config);
    expect(output, hasLength(1));
    expect(output[0], contains('No MEMORY.md found'));
  });

  test('prints message when MEMORY.md is empty', () async {
    final wsDir = Directory(p.join(tempDir.path, 'workspace'))..createSync();
    File(p.join(wsDir.path, 'MEMORY.md')).writeAsStringSync('');
    final config = DartclawConfig(dataDir: tempDir.path);
    await runCommand(config);
    expect(output, hasLength(1));
    expect(output[0], contains('empty'));
  });

  test('prints message when MEMORY.md has headers only (no entries)', () async {
    final wsDir = Directory(p.join(tempDir.path, 'workspace'))..createSync();
    File(p.join(wsDir.path, 'MEMORY.md')).writeAsStringSync('## general\n');
    final config = DartclawConfig(dataDir: tempDir.path);
    await runCommand(config);
    expect(output, hasLength(1));
    expect(output[0], contains('empty'));
  });

  test('rebuilds index from valid MEMORY.md', () async {
    final memoryContent = '''
## preferences
- [2026-02-23 10:00] User likes Dart
- [2026-02-23 10:05] User prefers dark mode

## project
- [2026-02-23 11:00] Working on DartClaw
''';
    final wsDir = Directory(p.join(tempDir.path, 'workspace'))..createSync();
    File(p.join(wsDir.path, 'MEMORY.md')).writeAsStringSync(memoryContent);
    final config = DartclawConfig(dataDir: tempDir.path);

    // Use file-based DB so we can reopen after command closes it
    final dbPath = p.join(tempDir.path, 'search.db');
    final runner = DartclawRunner()
      ..addCommand(
        RebuildIndexCommand(config: config, writeLine: output.add, searchDbFactory: (_) => openSearchDb(dbPath)),
      );
    await runner.run(['rebuild-index']);

    expect(output, hasLength(1));
    expect(output[0], contains('Rebuilt index: 3 entries'));

    // Verify entries were actually indexed by reopening the DB
    final db = openSearchDb(dbPath);
    final memory = MemoryService(db);
    final results = memory.search('Dart');
    expect(results, isNotEmpty);
    expect(results.first.text, contains('Dart'));
    db.close();
  });

  test('parses multiline entries correctly', () async {
    final memoryContent = '''
## preferences
- [2026-02-23 10:00] User prefers dark mode
  with high contrast settings
  and reduced motion
- [2026-02-23 10:05] Another preference
''';
    final wsDir = Directory(p.join(tempDir.path, 'workspace'))..createSync();
    File(p.join(wsDir.path, 'MEMORY.md')).writeAsStringSync(memoryContent);
    final config = DartclawConfig(dataDir: tempDir.path);

    final dbPath = p.join(tempDir.path, 'search.db');
    final runner = DartclawRunner()
      ..addCommand(
        RebuildIndexCommand(config: config, writeLine: output.add, searchDbFactory: (_) => openSearchDb(dbPath)),
      );
    await runner.run(['rebuild-index']);

    expect(output, hasLength(1));
    expect(output[0], contains('Rebuilt index: 2 entries'));

    // Verify multiline content is preserved in search index
    final db = openSearchDb(dbPath);
    final memory = MemoryService(db);
    final results = memory.search('high contrast');
    expect(results, isNotEmpty);
    expect(results.first.text, contains('high contrast'));
    db.close();
  });
}
