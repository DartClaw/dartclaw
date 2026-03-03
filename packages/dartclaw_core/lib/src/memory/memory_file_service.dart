import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

class _WriteOp {
  final Future<void> Function() fn;
  final Completer<void> completer;
  _WriteOp(this.fn) : completer = Completer<void>();
}

/// Manages the MEMORY.md file with category-based sections and atomic writes.
class MemoryFileService {
  final String baseDir;
  int _lastMemorySize = 0;
  final _queue = StreamController<_WriteOp>();
  late final StreamSubscription<void> _queueSub;

  MemoryFileService({required this.baseDir}) {
    _queueSub = _queue.stream
        .asyncMap((op) async {
          try {
            await op.fn();
            op.completer.complete();
          } catch (e, st) {
            op.completer.completeError(e, st);
          }
        })
        .listen((_) {});
  }

  /// Byte size from last [readMemory] or [appendMemory] call.
  int get lastMemorySize => _lastMemorySize;

  /// Appends a timestamped entry to MEMORY.md, grouped under [category].
  Future<void> appendMemory({required String text, String? category}) {
    final op = _WriteOp(() async {
      final file = File(_memoryPath);
      final dir = file.parent;
      if (!dir.existsSync()) dir.createSync(recursive: true);

      final cat = category ?? 'general';
      final timestamp = DateTime.now().toIso8601String().substring(0, 16).replaceFirst('T', ' ');
      final entry = '- [$timestamp] $text';

      if (!file.existsSync()) {
        file.writeAsStringSync('## $cat\n$entry\n');
        _lastMemorySize = utf8.encode('## $cat\n$entry\n').length;
        return;
      }

      final content = file.readAsStringSync();
      final header = '## $cat';

      if (content.contains('$header\n')) {
        // Insert entry after the matching category header section
        final lines = content.split('\n');
        final headerIdx = lines.indexOf(header);
        // Find insertion point: after header and existing entries in this section
        var insertIdx = headerIdx + 1;
        while (insertIdx < lines.length && lines[insertIdx].startsWith('- [')) {
          insertIdx++;
        }
        lines.insert(insertIdx, entry);
        final updated = lines.join('\n');
        // Atomic write: temp file + rename
        _atomicWriteSync(file, updated);
        _lastMemorySize = utf8.encode(updated).length;
      } else {
        // Append new category section
        final suffix = '${content.endsWith('\n') ? '' : '\n'}\n$header\n$entry\n';
        file.writeAsStringSync(suffix, mode: FileMode.append);
        _lastMemorySize = utf8.encode(content).length + utf8.encode(suffix).length;
      }
    });
    _queue.add(op);
    return op.completer.future;
  }

  /// Reads MEMORY.md contents, or empty string if missing.
  Future<String> readMemory() async {
    final file = File(_memoryPath);
    if (!file.existsSync()) {
      _lastMemorySize = 0;
      return '';
    }
    final content = file.readAsStringSync();
    _lastMemorySize = utf8.encode(content).length;
    return content;
  }

  /// Appends an entry to the daily log file (`memory/YYYY-MM-DD.md`).
  Future<void> appendDailyLog(String entry) {
    final op = _WriteOp(() async {
      final now = DateTime.now();
      final dateStr = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
      final logDir = p.join(baseDir, 'memory');
      Directory(logDir).createSync(recursive: true);
      final logFile = File(p.join(logDir, '$dateStr.md'));
      logFile.writeAsStringSync('$entry\n', mode: FileMode.append);
    });
    _queue.add(op);
    return op.completer.future;
  }

  /// Disposes write queue. Drains in-flight writes before completing.
  Future<void> dispose() async {
    await _queue.close();
    await _queueSub.cancel();
  }

  /// Strips markdown formatting for cleaner FTS5 indexing.
  static String stripMarkdown(String text) {
    return text
        .replaceAll(RegExp(r'#{1,6}\s*'), '') // headings
        .replaceAll(RegExp(r'\*{1,2}|_{1,2}'), '') // bold/italic
        .replaceAll(RegExp(r'`{1,3}'), '') // inline/block code
        .replaceAllMapped(RegExp(r'\[([^\]]+)\]\([^)]+\)'), (m) => m.group(1)!) // links
        .replaceAll(RegExp(r'^>\s*', multiLine: true), '') // blockquotes
        .trim();
  }

  /// Splits text >maxChars at paragraph boundaries.
  static List<String> splitParagraphs(String text, {int maxChars = 500}) {
    if (text.length <= maxChars) return [text];

    final chunks = <String>[];
    // Split on double-newline first
    final paragraphs = text.split('\n\n');

    for (final para in paragraphs) {
      if (para.length <= maxChars) {
        chunks.add(para);
        continue;
      }
      // Split on single newline
      final lines = para.split('\n');
      final buf = StringBuffer();
      for (final line in lines) {
        if (buf.length + line.length + 1 > maxChars && buf.isNotEmpty) {
          chunks.add(buf.toString().trim());
          buf.clear();
        }
        if (buf.isNotEmpty) buf.write('\n');
        buf.write(line);
      }
      if (buf.isNotEmpty) {
        final remaining = buf.toString().trim();
        // If still too long, split at word boundary
        if (remaining.length > maxChars) {
          _splitAtWordBoundary(remaining, maxChars, chunks);
        } else {
          chunks.add(remaining);
        }
      }
    }
    return chunks.where((c) => c.isNotEmpty).toList();
  }

  static void _splitAtWordBoundary(String text, int maxChars, List<String> out) {
    var remaining = text;
    while (remaining.length > maxChars) {
      var splitIdx = remaining.lastIndexOf(' ', maxChars);
      if (splitIdx <= 0) splitIdx = maxChars;
      out.add(remaining.substring(0, splitIdx).trim());
      remaining = remaining.substring(splitIdx).trim();
    }
    if (remaining.isNotEmpty) out.add(remaining);
  }

  /// Parses a MEMORY.md file into structured entries.
  ///
  /// Format:
  /// ```
  /// ## category-name
  /// - [2026-02-23 10:00] Some memory text
  /// ```
  ///
  /// Returns list of records with `text` and `category` fields.
  static List<({String text, String category})> parseMemoryFile(String path) {
    final file = File(path);
    if (!file.existsSync()) return [];

    final lines = file.readAsStringSync().split('\n');
    final entries = <({String text, String category})>[];
    var currentCategory = 'general';
    StringBuffer? currentText;
    String? currentCat;

    void flushEntry() {
      if (currentText != null && currentCat != null) {
        final text = currentText.toString().trim();
        if (text.isNotEmpty) {
          entries.add((text: text, category: currentCat!));
        }
      }
      currentText = null;
      currentCat = null;
    }

    for (final line in lines) {
      if (line.startsWith('## ')) {
        flushEntry();
        currentCategory = line.substring(3).trim();
        continue;
      }
      if (line.startsWith('- [')) {
        flushEntry();
        // Strip timestamp prefix: "- [YYYY-MM-DD HH:MM] "
        final closeBracket = line.indexOf('] ', 2);
        if (closeBracket == -1) continue;
        final text = line.substring(closeBracket + 2).trim();
        if (text.isEmpty) continue;
        currentText = StringBuffer(text);
        currentCat = currentCategory;
        continue;
      }
      // Continuation line — append to current entry
      if (currentText != null && line.trim().isNotEmpty) {
        currentText!.write('\n');
        currentText!.write(line.trim());
      }
    }
    flushEntry();

    return entries;
  }

  String get _memoryPath => p.join(baseDir, 'MEMORY.md');

  /// Atomic write: write to temp file then rename.
  static void _atomicWriteSync(File target, String content) {
    final tempFile = File('${target.path}.tmp');
    tempFile.writeAsStringSync(content);
    tempFile.renameSync(target.path);
  }
}
