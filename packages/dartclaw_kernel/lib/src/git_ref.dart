final _gitRefAllowedChars = RegExp(r'^[A-Za-z0-9_./-]+$');

/// Returns [ref] trimmed after validating it as a safe git ref operand.
///
/// This guard is for operator-supplied refs passed to `git` argv operands. It
/// is intentionally stricter than git's full ref grammar because these values
/// cross a command boundary.
String normalizeGitRefOperand(String ref, {String label = 'git ref'}) {
  final normalized = ref.trim();
  validateGitRefOperand(normalized, label: label);
  return normalized;
}

/// Throws [FormatException] when [ref] is unsafe for use as a git ref operand.
void validateGitRefOperand(String ref, {String label = 'git ref'}) {
  if (ref.isEmpty) {
    throw FormatException('$label must not be empty');
  }
  if (!_gitRefAllowedChars.hasMatch(ref)) {
    throw FormatException('$label contains unsupported characters: $ref');
  }
  if (ref.startsWith('-')) {
    throw FormatException('$label must not start with "-": $ref');
  }
  if (ref == '@' || ref.contains('@{') || ref.contains('..')) {
    throw FormatException('$label is not a valid ref name: $ref');
  }
  if (ref.endsWith('/') || ref.endsWith('.')) {
    throw FormatException('$label must not end with "/" or ".": $ref');
  }

  for (final segment in ref.split('/')) {
    if (segment.isEmpty) {
      throw FormatException('$label must not contain empty path segments: $ref');
    }
    if (segment.startsWith('.') || segment.startsWith('-')) {
      throw FormatException('$label contains an unsafe path segment: $ref');
    }
    if (segment.endsWith('.lock')) {
      throw FormatException('$label segment must not end with ".lock": $ref');
    }
  }
}
