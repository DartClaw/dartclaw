/// Multi-word system names that should stay atomic during entity normalization.
const knownSystems = <String>{
  'amazon web services',
  'android studio',
  'apple silicon',
  'claude code',
  'dart sdk',
  'docker desktop',
  'github actions',
  'google chat',
  'google cloud',
  'google drive',
  'google workspace',
  'homebrew',
  'jetbrains fleet',
  'microsoft teams',
  'openai api',
  'postgresql',
  'sqlite',
  'supabase',
  'visual studio code',
  'vs code',
  'xcode',
};

/// Normalizes a fact entity to a canonical lowercase form with whitespace
/// collapsed to single spaces.
///
/// The normalizer never splits on internal whitespace, so multi-word product
/// names already survive as a single atomic entity. [knownSystems] is the
/// reserved guard a future token-splitting normalizer must consult before it
/// fragments an entity; it has no runtime effect under the current
/// non-splitting normalization. Adding an entry is therefore a no-op today —
/// it only matters once a splitting normalizer exists.
String normalizeKnowledgeEntity(String input) {
  final trimmed = input.trim().replaceAll(RegExp(r'\s+'), ' ');
  if (trimmed.isEmpty) {
    throw ArgumentError('entity must not be empty');
  }
  return trimmed.toLowerCase();
}
