/// A parsed entry from MEMORY.md with timestamp, category, and text.
class MemoryEntry {
  /// Timestamp parsed from the entry prefix `[YYYY-MM-DD HH:MM]`.
  /// Null for entries without a recognized timestamp.
  final DateTime? timestamp;

  /// Category from the preceding `## category-name` header.
  final String category;

  /// Entry text without the timestamp prefix.
  final String rawText;

  /// Full raw block including `- [timestamp] ` prefix and continuation lines.
  final String rawBlock;

  MemoryEntry({
    required this.timestamp,
    required this.category,
    required this.rawText,
    required this.rawBlock,
  });

  /// Creates an entry without a recognized timestamp.
  factory MemoryEntry.undated({
    required String category,
    required String rawText,
    required String rawBlock,
  }) {
    return MemoryEntry(
      timestamp: null,
      category: category,
      rawText: rawText,
      rawBlock: rawBlock,
    );
  }

  /// Normalized text for deduplication: trimmed and whitespace-collapsed.
  String get normalizedText => rawText.trim().replaceAll(RegExp(r'\s+'), ' ');
}
