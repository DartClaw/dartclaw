import 'package:collection/collection.dart';

/// Configuration for the logging subsystem.
class LoggingConfig {
  /// format.
  final String format;

  /// file.
  final String? file;

  /// level.
  final String level;

  /// redactPatterns.
  final List<String> redactPatterns;

  /// const LoggingConfig({this.format = 'human', this.file, this..
  const LoggingConfig({this.format = 'human', this.file, this.level = 'INFO', this.redactPatterns = const []});

  /// Default configuration.
  const LoggingConfig.defaults() : this();

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LoggingConfig &&
          format == other.format &&
          file == other.file &&
          level == other.level &&
          const ListEquality<String>().equals(redactPatterns, other.redactPatterns);

  @override
  int get hashCode => Object.hash(format, file, level, Object.hashAll(redactPatterns));
}
