import 'dart:async';
import 'dart:io';

import 'package:logging/logging.dart';

import 'log_formatter.dart';
import 'log_redactor.dart';

/// Configures Dart's `logging` package with structured formatters and outputs.
///
/// Call [install] to set up root logger listener. Call [dispose] to flush
/// and close file sink on shutdown.
class LogService {
  final LogFormatter _formatter;
  final IOSink? _fileSink;
  final Level _level;
  StreamSubscription<LogRecord>? _subscription;

  LogService({
    required LogFormatter formatter,
    IOSink? fileSink,
    Level level = Level.INFO,
  }) : _formatter = formatter,
       _fileSink = fileSink,
       _level = level;

  /// Convenience factory from string config values.
  factory LogService.fromConfig({
    String format = 'human',
    String? logFile,
    String level = 'INFO',
    List<String> redactPatterns = const [],
  }) {
    final redactor = LogRedactor(patterns: redactPatterns);
    final formatter = switch (format) {
      'json' => JsonFormatter(redactor: redactor),
      _ => HumanFormatter(redactor: redactor),
    };

    IOSink? fileSink;
    if (logFile != null) {
      fileSink = File(logFile).openWrite(mode: FileMode.append);
    }

    final lvl = Level.LEVELS.firstWhere(
      (l) => l.name == level.toUpperCase(),
      orElse: () => Level.INFO,
    );

    return LogService(formatter: formatter, fileSink: fileSink, level: lvl);
  }

  /// Installs the root logger listener. Replaces any previous listener
  /// installed by this service.
  void install() {
    Logger.root.level = _level;
    _subscription?.cancel();
    _subscription = Logger.root.onRecord.listen(_handleRecord);
  }

  void _handleRecord(LogRecord record) {
    final line = _formatter.format(record);
    stderr.writeln(line);
    _fileSink?.writeln(line);
  }

  /// Flush and close file sink. Safe to call multiple times.
  Future<void> dispose() async {
    await _subscription?.cancel();
    _subscription = null;
    await _fileSink?.flush();
    await _fileSink?.close();
  }
}
