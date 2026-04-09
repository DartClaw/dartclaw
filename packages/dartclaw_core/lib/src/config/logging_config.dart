/// Configuration for the logging subsystem.
class LoggingConfig {
  final String format;
  final String? file;
  final String level;
  final List<String> redactPatterns;

  const LoggingConfig({
    this.format = 'human',
    this.file,
    this.level = 'INFO',
    this.redactPatterns = const [],
  });

  /// Default configuration.
  const LoggingConfig.defaults() : this();

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LoggingConfig &&
          format == other.format &&
          file == other.file &&
          level == other.level &&
          _listEquals(redactPatterns, other.redactPatterns);

  @override
  int get hashCode => Object.hash(format, file, level, Object.hashAll(redactPatterns));

  static bool _listEquals(List<String> a, List<String> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
