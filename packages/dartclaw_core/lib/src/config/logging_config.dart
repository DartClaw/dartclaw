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
}
