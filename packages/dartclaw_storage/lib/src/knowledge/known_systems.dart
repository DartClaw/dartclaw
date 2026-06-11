/// Normalizes a fact entity to a canonical lowercase form with whitespace
/// collapsed to single spaces.
///
/// The normalizer never splits on internal whitespace, so multi-word product
/// names already survive as a single atomic entity.
String normalizeKnowledgeEntity(String input) {
  final trimmed = input.trim().replaceAll(RegExp(r'\s+'), ' ');
  if (trimmed.isEmpty) {
    throw ArgumentError('entity must not be empty');
  }
  return trimmed.toLowerCase();
}
