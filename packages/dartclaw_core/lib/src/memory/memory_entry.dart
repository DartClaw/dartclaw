/// A parsed entry from MEMORY.md with timestamp, category, and text.
class MemoryEntry {
  /// Timestamp from `[YYYY-MM-DD HH:MM]`, or null when unrecognized.
  final DateTime? timestamp;

  /// Category from the preceding `## category-name` header.
  final String category;

  /// Whether [category] came from the parser default rather than a heading.
  final bool categoryWasDefaulted;

  /// Entry text without the timestamp prefix.
  final String rawText;

  /// Full raw block including `- [timestamp] ` prefix and continuation lines.
  final String rawBlock;

  /// Inclusive source offset in the parsed file, when available.
  final int? sourceStart;

  /// Exclusive source offset in the parsed file, when available.
  final int? sourceEnd;
  new({
    required this.timestamp,
    required this.category,
    this.categoryWasDefaulted = false,
    required this.rawText,
    required this.rawBlock,
    this.sourceStart,
    this.sourceEnd,
  });

  /// Creates an entry without a recognized timestamp.
  factory undated({required String category, required String rawText, required String rawBlock}) =>
      MemoryEntry(timestamp: null, category: category, rawText: rawText, rawBlock: rawBlock);

  /// Normalized text for deduplication: trimmed and whitespace-collapsed.
  String get normalizedText => rawText.trim().replaceAll(RegExp(r'\s+'), ' ');
}
