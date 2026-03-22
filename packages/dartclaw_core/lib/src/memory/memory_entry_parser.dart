import 'package:logging/logging.dart';

import 'memory_entry.dart';

final _log = Logger('MemoryEntryParser');

/// Regex matching timestamped memory entries: `- [YYYY-MM-DD HH:MM] ...`
final memoryTimestampRe = RegExp(r'^\- \[(\d{4}-\d{2}-\d{2})\s+(\d{2}:\d{2})\]');

/// Parses MEMORY.md content into structured [MemoryEntry] instances.
///
/// Recognizes `## category` headers and `- [timestamp] text` entries.
/// Continuation lines (non-blank, non-header, non-entry) are appended to
/// the current entry. Undated entries (no recognized timestamp) get a null
/// [MemoryEntry.timestamp].
List<MemoryEntry> parseMemoryEntries(String content) {
  final lines = content.split('\n');
  final entries = <MemoryEntry>[];
  var currentCategory = 'general';
  final blockLines = <String>[];
  DateTime? currentTimestamp;
  StringBuffer? currentText;

  void flushEntry() {
    if (currentText != null && blockLines.isNotEmpty) {
      final rawBlock = blockLines.join('\n');
      final rawText = currentText.toString().trim();
      if (rawText.isNotEmpty) {
        entries.add(
          MemoryEntry(timestamp: currentTimestamp, category: currentCategory, rawText: rawText, rawBlock: rawBlock),
        );
      }
    }
    blockLines.clear();
    currentText = null;
    currentTimestamp = null;
  }

  for (final line in lines) {
    if (line.startsWith('## ')) {
      flushEntry();
      currentCategory = line.substring(3).trim();
      continue;
    }

    if (line.startsWith('- [')) {
      flushEntry();
      final match = memoryTimestampRe.firstMatch(line);
      if (match != null) {
        final datePart = match.group(1)!;
        final timePart = match.group(2)!;
        try {
          currentTimestamp = DateTime.parse('${datePart}T$timePart:00');
        } catch (e) {
          currentTimestamp = null;
          _log.warning('Failed to parse timestamp from line: $line ($e)');
        }
        // Extract text after "] "
        final closeBracket = line.indexOf('] ', 2);
        if (closeBracket != -1) {
          currentText = StringBuffer(line.substring(closeBracket + 2).trim());
        } else {
          currentText = StringBuffer();
        }
      } else {
        // Entry starts with "- [" but doesn't match timestamp pattern
        currentTimestamp = null;
        currentText = StringBuffer(line.substring(2).trim());
      }
      blockLines.add(line);
      continue;
    }

    // Continuation line
    if (currentText != null && line.trim().isNotEmpty) {
      currentText!.write('\n');
      currentText!.write(line.trim());
      blockLines.add(line);
    }
  }
  flushEntry();

  return entries;
}
