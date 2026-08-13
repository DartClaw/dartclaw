import 'memory_entry.dart';

/// Regex matching timestamped memory entries: `- [YYYY-MM-DD HH:MM] ...`
final memoryTimestampRe = RegExp(r'^\- \[(\d{4}-\d{2}-\d{2})\s+(\d{2}:\d{2})\] ');
final _memoryFenceRe = RegExp(r'^ {0,3}(`{3,}|~{3,})');
bool _isIndented(String line) => line.startsWith(' ') || line.startsWith('\t');

class _MemoryFenceTracker {
  String? _token;
  bool get isOpen => _token != null;
  ({bool consumed, bool opened}) consume(String line, {required bool canOpen}) {
    final match = _memoryFenceRe.firstMatch(line);
    final token = match?.group(1);
    final open = _token;
    if (open != null) {
      if (token != null &&
          token[0] == open[0] &&
          token.length >= open.length &&
          line.substring(match!.end).trim().isEmpty) {
        _token = null;
      }
      return (consumed: true, opened: false);
    }
    if (token == null || !canOpen) return (consumed: false, opened: false);
    _token = token;
    return (consumed: true, opened: true);
  }
}

/// Parses category headers, timestamped entries, and indented continuations.
///
/// Unrecognized timestamps produce undated entries. When [onBatch] is supplied,
/// entries are visited without being retained and the returned list is empty.
List<MemoryEntry> parseMemoryEntries(
  String content, {
  int batchSize = 256,
  void Function(List<MemoryEntry> entries)? onBatch,
}) {
  final entries = <MemoryEntry>[];
  _parseMemoryEntryBatches(content, batchSize: batchSize, onBatch: onBatch ?? entries.addAll);
  return entries;
}

void _parseMemoryEntryBatches(
  String content, {
  required int batchSize,
  required void Function(List<MemoryEntry> entries) onBatch,
}) {
  if (batchSize < 1) throw ArgumentError.value(batchSize, 'batchSize', 'must be positive');
  final lines = content.split('\n');
  final batch = <MemoryEntry>[];
  var currentCategory = 'general';
  var currentCategoryWasDefaulted = true;
  final blockLines = <String>[];
  DateTime? currentTimestamp;
  StringBuffer? currentText;
  int? currentSourceStart;
  final pendingBlankLines = <String>[];
  final fences = _MemoryFenceTracker();
  void flushBatch() {
    if (batch.isEmpty) return;
    onBatch(List.unmodifiable(batch));
    batch.clear();
  }

  void flushEntry() {
    if (currentText != null && blockLines.isNotEmpty) {
      final rawBlock = blockLines.join('\n');
      final rawText = currentText.toString().trim();
      if (rawText.isNotEmpty) {
        batch.add(
          MemoryEntry(
            timestamp: currentTimestamp,
            category: currentCategory,
            categoryWasDefaulted: currentCategoryWasDefaulted,
            rawText: rawText,
            rawBlock: rawBlock,
            sourceStart: currentSourceStart,
            sourceEnd: currentSourceStart == null ? null : currentSourceStart! + rawBlock.length,
          ),
        );
        if (batch.length == batchSize) flushBatch();
      }
    }
    blockLines.clear();
    pendingBlankLines.clear();
    currentText = null;
    currentTimestamp = null;
    currentSourceStart = null;
  }

  var lineOffset = 0;
  for (final line in lines) {
    final currentLineOffset = lineOffset;
    lineOffset += line.length + 1;
    final fence = fences.consume(line, canOpen: currentText == null || !_isIndented(line));
    if (fence.consumed) {
      if (fence.opened) flushEntry();
      continue;
    }
    if (line.startsWith('## ')) {
      flushEntry();
      currentCategory = line.substring(3).trim();
      currentCategoryWasDefaulted = false;
      continue;
    }
    if (line.startsWith('- [')) {
      flushEntry();
      currentSourceStart = currentLineOffset;
      final match = memoryTimestampRe.firstMatch(line);
      if (match != null) {
        final datePart = match.group(1)!;
        final timePart = match.group(2)!;
        final parsed = DateTime.tryParse('${datePart}T$timePart:00');
        if (parsed != null && parsed.toIso8601String().startsWith('${datePart}T$timePart:')) {
          currentTimestamp = parsed;
        }
        currentText = StringBuffer(line.substring(match.end).trim());
      } else {
        currentText = StringBuffer(line.substring(2).trim());
      }
      blockLines.add(line);
      continue;
    }
    if (currentText == null) continue;
    if (line.trim().isEmpty) {
      pendingBlankLines.add(line);
      continue;
    }
    if (_isIndented(line)) {
      currentText!.write('\n' * pendingBlankLines.length);
      blockLines.addAll(pendingBlankLines);
      pendingBlankLines.clear();
      currentText!.write('\n');
      currentText!.write(line.startsWith('  ') ? line.substring(2) : line.substring(1));
      blockLines.add(line);
      continue;
    }
    flushEntry();
  }
  flushEntry();
  flushBatch();
}

/// Finds a safe insertion point for [category], ignoring fenced headings.
({int? headerIndex, int insertIndex, bool hasUnclosedFence}) findMemoryCategoryInsertion(
  List<String> lines,
  String category,
) {
  final fences = _MemoryFenceTracker();
  int? headerIndex;
  int? openFenceIndex;
  var hasCurrentEntry = false;
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    final fence = fences.consume(line, canOpen: !hasCurrentEntry || !_isIndented(line));
    if (fence.opened) openFenceIndex = i;
    if (fence.consumed) {
      if (fence.opened) hasCurrentEntry = false;
      if (!fences.isOpen) openFenceIndex = null;
      continue;
    }
    if (line.startsWith('## ')) {
      hasCurrentEntry = false;
      if (headerIndex != null) return (headerIndex: headerIndex, insertIndex: i, hasUnclosedFence: false);
      if (line.substring(3).trim() == category) headerIndex = i;
      continue;
    }
    if (line.trim().isNotEmpty && !_isIndented(line)) hasCurrentEntry = line.startsWith('- [');
  }
  return (
    headerIndex: headerIndex,
    insertIndex: openFenceIndex ?? lines.length,
    hasUnclosedFence: openFenceIndex != null,
  );
}
