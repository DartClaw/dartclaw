import 'dart:io';

import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

/// Dispatches a cleanup turn when MEMORY.md grows beyond a size threshold.
class MemoryConsolidator {
  static final _log = Logger('MemoryConsolidator');

  static const consolidationPrompt =
      'Review MEMORY.md for duplicates, outdated entries, and reorganization '
      'opportunities. Deduplicate and reorganize while preserving all important '
      'information. Save the cleaned version using memory_save.';

  final String workspaceDir;
  final Future<void> Function(String sessionKey, String message) _dispatch;
  final int threshold;

  MemoryConsolidator({
    required this.workspaceDir,
    required Future<void> Function(String sessionKey, String message) dispatch,
    this.threshold = 32 * 1024,
  }) : _dispatch = dispatch;

  Future<void> runIfNeeded() async {
    final memoryPath = p.join(workspaceDir, 'MEMORY.md');
    try {
      final file = File(memoryPath);
      if (!file.existsSync()) return;

      final size = file.lengthSync();
      if (size < threshold) return;

      _log.info('MEMORY.md is ${size}B (>${threshold}B) — running consolidation');
      final sessionKey = 'agent:main:consolidation:${DateTime.now().toUtc().toIso8601String()}';
      await _dispatch(sessionKey, consolidationPrompt);
    } catch (e) {
      _log.warning('Memory consolidation failed: $e');
    }
  }
}
