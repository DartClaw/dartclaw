/// A parsed entry from MEMORY.md with timestamp, category, and text.
class MemoryEntry {
  /// Timestamp from `[YYYY-MM-DD HH:MM]`, or null when unrecognized.
  final DateTime? timestamp;

  /// Category from the preceding `## category-name` header.
  final String category;

  /// Entry text without the timestamp prefix.
  final String rawText;

  /// Full raw block including `- [timestamp] ` prefix and continuation lines.
  final String rawBlock;

  /// Inclusive source offset in the parsed file, when available.
  final int? sourceStart;

  /// Exclusive source offset in the parsed file, when available.
  final int? sourceEnd;
  MemoryEntry({
    required this.timestamp,
    required this.category,
    required this.rawText,
    required this.rawBlock,
    this.sourceStart,
    this.sourceEnd,
  });

  /// Creates an entry without a recognized timestamp.
  factory MemoryEntry.undated({required String category, required String rawText, required String rawBlock}) =>
      MemoryEntry(timestamp: null, category: category, rawText: rawText, rawBlock: rawBlock);

  /// Normalized text for deduplication: trimmed and whitespace-collapsed.
  String get normalizedText => rawText.trim().replaceAll(RegExp(r'\s+'), ' ');
}
