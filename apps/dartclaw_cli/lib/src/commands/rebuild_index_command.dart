import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_storage/dartclaw_storage.dart';
import 'package:path/path.dart' as p;

import 'config_loader.dart';

class RebuildIndexCommand extends Command<void> {
  final DartclawConfig? _config;
  final void Function(String)? _writeLine;
  final SearchDbFactory _searchDbFactory;

  RebuildIndexCommand({DartclawConfig? config, void Function(String)? writeLine, SearchDbFactory? searchDbFactory})
    : _config = config,
      _writeLine = writeLine,
      _searchDbFactory = searchDbFactory ?? openSearchDb;

  @override
  String get name => 'rebuild-index';

  @override
  String get description => 'Rebuild FTS5 memory search index offline (stop DartClaw first)';

  @override
  Future<void> run() async {
    final config = _config ?? loadCliConfig(configPath: globalResults?['config'] as String?);
    final write = _writeLine ?? stdout.writeln;

    for (final w in config.warnings) {
      write('WARNING: $w');
    }
    write('WARNING: DartClaw must remain stopped until rebuild-index completes.');

    final memoryPath = p.join(config.workspaceDir, 'MEMORY.md');
    final archivePath = p.join(config.workspaceDir, 'MEMORY.archive.md');
    final learningsPath = p.join(config.workspaceDir, 'learnings.md');
    final memoryEntries = _readEntries(memoryPath);
    final archiveEntries = _readEntries(archivePath);
    final learningEntries = _readEntries(learningsPath);
    if (![memoryPath, archivePath, learningsPath].any((path) => File(path).existsSync())) {
      write('No MEMORY.md, MEMORY.archive.md, or learnings.md found in ${config.workspaceDir}');
    }

    final db = _searchDbFactory(config.searchDbPath);
    try {
      final memory = MemoryService(db);
      final rows = [
        ..._indexRows(memoryEntries, source: 'memory_save'),
        ..._indexRows(archiveEntries, source: 'archive'),
        ..._indexRows(learningEntries, source: 'memory_save', category: 'learning'),
      ];
      memory.rebuildIndex(rows);
      final total = rows.length;
      write('Rebuilt index: $total entries from MEMORY.md, MEMORY.archive.md, and learnings.md');
    } finally {
      db.close();
    }
  }

  List<MemoryEntry> _readEntries(String path) {
    final content = MemoryFileService.readRegularFile(File(path));
    return content == null ? const [] : parseMemoryEntries(content);
  }

  Iterable<MemoryIndexRow> _indexRows(List<MemoryEntry> entries, {required String source, String? category}) sync* {
    for (final entry in entries) {
      yield* MemoryService.indexRows(
        text: entry.rawText,
        source: source,
        category: category ?? entry.category,
        createdAt: entry.timestamp,
      );
    }
  }
}
