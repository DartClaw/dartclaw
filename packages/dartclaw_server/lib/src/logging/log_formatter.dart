import 'dart:convert';

import 'package:logging/logging.dart';

import 'log_context.dart';
import 'log_redactor.dart';

/// Formats a [LogRecord] into a single output string.
abstract class LogFormatter {
  String format(LogRecord record);
}

/// Human-readable log format for stderr.
///
/// Format: `LEVEL: 2026-02-25T10:30:00 [session=X turn=Y] LoggerName: message`
///
/// When [colorize] is true, the level prefix is wrapped in ANSI color codes:
/// SEVERE → red, WARNING → yellow, INFO → cyan, FINE/FINER/FINEST → dim.
class HumanFormatter implements LogFormatter {
  final LogRedactor _redactor;
  final bool colorize;

  HumanFormatter({LogRedactor? redactor, this.colorize = false}) : _redactor = redactor ?? LogRedactor();

  static const _reset = '\x1B[0m';
  static const _red = '\x1B[31m';
  static const _yellow = '\x1B[33m';
  static const _cyan = '\x1B[36m';
  static const _dim = '\x1B[2m';

  /// Palette for logger name coloring — avoids red (SEVERE), yellow (WARNING),
  /// cyan (INFO), and dim (FINE) to prevent confusion with level indicators.
  static const _loggerColors = [
    '\x1B[32m', // green
    '\x1B[34m', // blue
    '\x1B[35m', // magenta
    '\x1B[92m', // bright green
    '\x1B[94m', // bright blue
    '\x1B[95m', // bright magenta
    '\x1B[97m', // bright white
  ];

  String _coloredLevel(Level level) {
    final name = level.name;
    if (!colorize) return name;
    if (level >= Level.SEVERE) return '$_red$name$_reset';
    if (level >= Level.WARNING) return '$_yellow$name$_reset';
    if (level >= Level.INFO) return '$_cyan$name$_reset';
    return '$_dim$name$_reset';
  }

  /// Returns a stable color for a logger name based on its hash code.
  String _coloredLogger(String name) {
    if (!colorize) return name;
    final color = _loggerColors[name.hashCode.abs() % _loggerColors.length];
    return '$color$name$_reset';
  }

  @override
  String format(LogRecord record) {
    final buf = StringBuffer()
      ..write(_coloredLevel(record.level))
      ..write(': ')
      ..write(record.time.toIso8601String());

    final sessionId = LogContext.sessionId;
    final turnId = LogContext.turnId;
    if (sessionId != null || turnId != null) {
      buf.write(' [');
      if (sessionId != null) buf.write('session=$sessionId');
      if (sessionId != null && turnId != null) buf.write(' ');
      if (turnId != null) buf.write('turn=$turnId');
      buf.write(']');
    }

    buf
      ..write(' ')
      ..write(_coloredLogger(record.loggerName))
      ..write(': ')
      ..write(record.message);

    if (record.error != null) {
      buf
        ..write('\n')
        ..write(record.error);
    }
    if (record.stackTrace != null) {
      buf
        ..write('\n')
        ..write(record.stackTrace);
    }

    return _redactor.redact(buf.toString());
  }
}

/// JSON (NDJSON) log format — one JSON object per line.
class JsonFormatter implements LogFormatter {
  final LogRedactor _redactor;

  JsonFormatter({LogRedactor? redactor}) : _redactor = redactor ?? LogRedactor();

  @override
  String format(LogRecord record) {
    final map = <String, dynamic>{
      'level': record.level.name,
      'time': record.time.toUtc().toIso8601String(),
      'logger': record.loggerName,
      'message': record.message,
    };

    final sessionId = LogContext.sessionId;
    final turnId = LogContext.turnId;
    if (sessionId != null) map['sessionId'] = sessionId;
    if (turnId != null) map['turnId'] = turnId;
    if (record.error != null) map['error'] = record.error.toString();
    if (record.stackTrace != null) map['stackTrace'] = record.stackTrace.toString();

    return _redactor.redact(jsonEncode(map));
  }
}
