import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_security/dartclaw_security.dart' show truncateUtf8Bytes;
import 'package:path/path.dart' as p;

import '../concurrency/repo_lock.dart';
import '../storage/atomic_write.dart';
import '../storage/write_op.dart';
import 'memory_entry_parser.dart';

/// Manages the MEMORY.md file with category-based sections and atomic writes.
class MemoryFileService {
  /// Maximum UTF-8 size of one daily-log record before a visible truncation marker is added.
  static const maxDailyLogEntryBytes = 512 * 1024;

  /// Maximum UTF-8 size retained in one date-partitioned daily-log file.
  static const maxDailyLogFileBytes = 8 * 1024 * 1024;

  /// Maximum size read from one canonical workspace text file.
  static const maxReadableFileBytes = 64 * 1024 * 1024;
  static const _dailyLogEntryTruncated = '\n\n[Daily log record truncated at 512 KiB]\n';
  static const _dailyLogHistoryTrimmed = '<!-- Older daily-log records removed at the 8 MiB file limit. -->\n';
  static final _dailyLogBoundary = RegExp(r'^## \d{2}:\d{2} — ', multiLine: true);
  static final _workspaceMemoryLock = RepoLock();
  final String baseDir;
  String? _resolvedBaseDir;
  int _lastMemorySize = 0;
  final _queue = BoundedWriteQueue();
  MemoryFileService({required this.baseDir});

  /// Byte size from last [readMemory] or [appendMemory] call.
  int get lastMemorySize => _lastMemorySize;

  /// Appends under [category]; unclosed fences throw [FormatException]; [afterWrite] runs locked after persistence.
  Future<void> appendMemory({
    required String text,
    String? category,
    DateTime? timestamp,
    FutureOr<void> Function(DateTime timestamp)? afterWrite,
  }) {
    final op = WriteOp(() {
      final root = _workspaceRoot(create: true)!;
      final file = File(p.join(root, 'MEMORY.md'));
      return _workspaceMemoryLock.acquire(file.path, () async {
        final cat = category ?? 'general';
        final writtenAt = _toMinutePrecision(timestamp ?? DateTime.now());
        final timestampText = writtenAt.toIso8601String().substring(0, 16).replaceFirst('T', ' ');
        final textLines = text.trim().replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n');
        final entryText = '- [$timestampText] ${textLines.join('\n  ')}';
        final content = readRegularFile(file);
        if (content == null) {
          _storeMemory(file, '## $cat\n$entryText\n');
        } else {
          final lines = content.split('\n');
          final location = findMemoryCategoryInsertion(lines, cat);
          if (location.headerIndex case final headerIndex?) {
            var insertIdx = location.insertIndex;
            while (insertIdx > headerIndex + 1 && lines[insertIdx - 1].trim().isEmpty) {
              insertIdx--;
            }
            _requireMemorySize(file, file.lengthSync() + utf8.encode(entryText).length + 1);
            lines.insert(insertIdx, entryText);
            _storeMemory(file, lines.join('\n'));
          } else {
            if (location.hasUnclosedFence) {
              throw const FormatException('Cannot add a category after an unclosed fence');
            }
            final suffix = '${content.endsWith('\n') ? '' : '\n'}\n## $cat\n$entryText\n';
            _requireMemorySize(file, file.lengthSync() + utf8.encode(suffix).length);
            _storeMemory(file, '$content$suffix');
          }
        }
        if (afterWrite != null) await afterWrite(writtenAt);
      });
    });
    _queue.add(op);
    return op.completer.future;
  }

  /// Reads MEMORY.md contents, or empty string if missing.
  Future<String> readMemory() async {
    final root = _workspaceRoot(create: false);
    final content = root == null ? null : readRegularFile(File(p.join(root, 'MEMORY.md')));
    if (content == null) {
      _lastMemorySize = 0;
      return '';
    }
    _lastMemorySize = utf8.encode(content).length;
    return content;
  }

  /// Appends an entry to the daily log file (`memory/YYYY-MM-DD.md`).
  Future<void> appendDailyLog(String entry) {
    final op = WriteOp(() async {
      final now = DateTime.now();
      final dateStr = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
      final logDir = p.join(_workspaceRoot(create: true)!, 'memory');
      final logDirType = FileSystemEntity.typeSync(logDir, followLinks: false);
      if (logDirType == FileSystemEntityType.notFound) {
        Directory(logDir).createSync();
      } else if (logDirType != FileSystemEntityType.directory) {
        throw FileSystemException('Unexpected filesystem entity', logDir);
      }
      final logFile = File(p.join(logDir, '$dateStr.md'));
      final existing = _readDailyLog(logFile);
      final boundedEntry = _truncateUtf8(entry, maxDailyLogEntryBytes, _dailyLogEntryTruncated);
      final content = _appendBoundedDailyLog(existing, '$boundedEntry\n');
      secureWriteFileSync(logFile, content, restrictPermissions: false);
    });
    _queue.add(op);
    return op.completer.future;
  }

  /// Disposes write queue. Drains in-flight writes before completing.
  Future<void> dispose() => _queue.close();

  /// Strips markdown formatting for cleaner FTS5 indexing.
  static String stripMarkdown(String text) => text
      .replaceAll(RegExp(r'#{1,6}\s*'), '')
      .replaceAll(RegExp(r'\*{1,2}|_{1,2}'), '')
      .replaceAll(RegExp(r'`{1,3}'), '')
      .replaceAllMapped(RegExp(r'\[([^\]]+)\]\([^)]+\)'), (m) => m.group(1)!)
      .replaceAll(RegExp(r'^>\s*', multiLine: true), '')
      .trim();

  /// Splits text >maxChars at paragraph boundaries.
  static List<String> splitParagraphs(String text, {int maxChars = 500}) {
    if (text.length <= maxChars) return [text];
    final chunks = <String>[];
    for (final para in text.split('\n\n')) {
      if (para.length <= maxChars) {
        chunks.add(para);
        continue;
      }
      var remaining = '';
      for (final line in para.split('\n')) {
        if (remaining.isNotEmpty && remaining.length + line.length + 1 > maxChars) {
          chunks.add(remaining.trim());
          remaining = '';
        }
        remaining = remaining.isEmpty ? line : '$remaining\n$line';
      }
      remaining = remaining.trim();
      while (remaining.length > maxChars) {
        var end = remaining.lastIndexOf(' ', maxChars);
        if (end <= 0) end = maxChars;
        chunks.add(remaining.substring(0, end).trim());
        remaining = remaining.substring(end).trim();
      }
      if (remaining.isNotEmpty) chunks.add(remaining);
    }
    return chunks.where((c) => c.isNotEmpty).toList();
  }

  static DateTime _toMinutePrecision(DateTime v) => DateTime(v.year, v.month, v.day, v.hour, v.minute);

  /// Parses a MEMORY.md file into text/category records.
  static List<({String text, String category})> parseMemoryFile(String path) {
    final content = readRegularFile(File(path));
    if (content == null) return [];
    return parseMemoryEntries(content).map((entry) => (text: entry.rawText, category: entry.category)).toList();
  }

  /// Whether appending a new top-level section would enter an unclosed fence.
  static bool hasUnclosedFence(String text) => findMemoryCategoryInsertion(text.split('\n'), '\u0000').hasUnclosedFence;
  String? _workspaceRoot({required bool create}) {
    if (_resolvedBaseDir case final resolved?) {
      _requireDirectory(resolved);
      return resolved;
    }
    final directory = Directory(p.absolute(baseDir));
    final type = FileSystemEntity.typeSync(directory.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      if (!create) return null;
      directory.createSync(recursive: true);
    } else if (type != FileSystemEntityType.directory && type != FileSystemEntityType.link) {
      throw FileSystemException('Workspace root is not a directory', directory.path);
    }
    final resolved = directory.resolveSymbolicLinksSync();
    if (FileSystemEntity.typeSync(resolved, followLinks: false) != FileSystemEntityType.directory) {
      throw FileSystemException('Workspace root does not resolve to a directory', directory.path);
    }
    return _resolvedBaseDir = p.normalize(resolved);
  }

  void _storeMemory(File file, String content) {
    final sizeBytes = utf8.encode(content).length;
    _requireMemorySize(file, sizeBytes);
    secureWriteFileSync(file, content, restrictPermissions: false);
    _lastMemorySize = sizeBytes;
  }

  static void _requireMemorySize(File file, int sizeBytes) {
    if (sizeBytes <= maxReadableFileBytes) return;
    throw FileSystemException('MEMORY.md would exceed the $maxReadableFileBytes-byte limit', file.path);
  }

  static void _requireDirectory(String path) {
    if (FileSystemEntity.typeSync(path, followLinks: false) == FileSystemEntityType.directory) return;
    throw FileSystemException('Workspace root is not a directory', path);
  }

  static String _appendBoundedDailyLog(String existing, String entry) {
    final combined = '$existing$entry';
    if (utf8.encode(combined).length <= maxDailyLogFileBytes) return combined;

    final available = maxDailyLogFileBytes - utf8.encode(_dailyLogHistoryTrimmed).length;
    final boundaries = _dailyLogBoundary.allMatches(combined).where((match) => match.start > 0).toList();
    var low = 0;
    var high = boundaries.length;
    while (low < high) {
      final middle = (low + high) ~/ 2;
      if (utf8.encode(combined.substring(boundaries[middle].start)).length <= available) {
        high = middle;
      } else {
        low = middle + 1;
      }
    }
    if (low < boundaries.length) return '$_dailyLogHistoryTrimmed${combined.substring(boundaries[low].start)}';
    return '$_dailyLogHistoryTrimmed${_truncateUtf8(entry, available, _dailyLogEntryTruncated)}';
  }

  static String _readDailyLog(File file) {
    final type = FileSystemEntity.typeSync(file.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return '';
    if (type != FileSystemEntityType.file) throw FileSystemException('Unexpected filesystem entity', file.path);
    final handle = file.openSync();
    try {
      final length = handle.lengthSync();
      final oversized = length > maxDailyLogFileBytes;
      final readBytes = oversized ? maxDailyLogFileBytes : length;
      if (oversized) handle.setPositionSync(length - readBytes);
      final content = utf8.decode(handle.readSync(readBytes), allowMalformed: oversized);
      if (!oversized) return content;
      final boundary = _dailyLogBoundary.firstMatch(content);
      return '$_dailyLogHistoryTrimmed${boundary == null ? '' : content.substring(boundary.start)}';
    } finally {
      handle.closeSync();
    }
  }

  static String _truncateUtf8(String value, int maxBytes, String marker) {
    if (utf8.encode(value).length <= maxBytes) return value;
    return '${truncateUtf8Bytes(value, maxBytes - utf8.encode(marker).length)}$marker';
  }

  /// Reads [file] when its stable leaf is regular; returns `null` if missing and rejects symlinks and non-files.
  static String? readRegularFile(File file, {int maxBytes = maxReadableFileBytes}) {
    final type = FileSystemEntity.typeSync(file.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return null;
    if (type != FileSystemEntityType.file) throw FileSystemException('Unexpected filesystem entity', file.path);
    final handle = file.openSync();
    try {
      final sizeBytes = handle.lengthSync();
      if (sizeBytes > maxBytes) throw FileSystemException('File exceeds $maxBytes-byte read limit', file.path);
      final bytes = handle.readSync(sizeBytes);
      return utf8.decode(bytes);
    } finally {
      handle.closeSync();
    }
  }
}
