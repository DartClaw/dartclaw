import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_storage/dartclaw_storage.dart';
import 'package:path/path.dart' as p;

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
  String get description => 'Rebuild FTS5 memory search index from MEMORY.md';

  @override
  Future<void> run() async {
    final config = _config ?? DartclawConfig.load(configPath: globalResults?['config'] as String?);
    final write = _writeLine ?? stdout.writeln;

    for (final w in config.warnings) {
      write('WARNING: $w');
    }

    final memoryPath = p.join(config.workspaceDir, 'MEMORY.md');
    final file = File(memoryPath);
    if (!file.existsSync()) {
      write('No MEMORY.md found at $memoryPath');
      return;
    }

    final entries = MemoryFileService.parseMemoryFile(memoryPath);
    if (entries.isEmpty) {
      write('MEMORY.md is empty — nothing to index');
      return;
    }

    final db = _searchDbFactory(config.searchDbPath);
    try {
      final memory = MemoryService(db);
      memory.rebuildIndex(entries.map((e) => (text: e.text, source: 'memory_save', category: e.category)).toList());
      write('Rebuilt index: ${entries.length} entries from $memoryPath');
    } finally {
      db.close();
    }
  }
}
