/// Abstract interface for content classification at agent boundaries.
///
/// Implementations classify text content into safety categories:
/// `safe`, `prompt_injection`, `harmful_content`, `exfiltration_attempt`.
abstract interface class ContentClassifier {
  /// Classify [content] into a safety category.
  ///
  /// Returns one of: `safe`, `prompt_injection`, `harmful_content`,
  /// `exfiltration_attempt`.
  ///
  /// Throws on error or timeout — the caller decides fail-open vs fail-closed.
  Future<String> classify(String content, {Duration timeout});
}
