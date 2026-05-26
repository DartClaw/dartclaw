/// Identifier preservation mode for compacted prompt context.
enum IdentifierPreservationMode {
  /// Append the default identifier preservation instructions.
  strict,

  /// Do not append identifier preservation instructions.
  off,

  /// Append caller-provided identifier preservation instructions.
  custom;

  /// Parses [value] from its JSON wire string.
  static IdentifierPreservationMode fromJsonString(String value) => switch (value) {
    'strict' => strict,
    'off' => off,
    'custom' => custom,
    _ => throw FormatException(
      'Unknown IdentifierPreservationMode "$value"; valid values: ${values.map((mode) => mode.toJson()).join(', ')}',
    ),
  };

  /// Converts this value to its JSON wire string.
  String toJson() => name;
}
