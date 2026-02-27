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
class HumanFormatter implements LogFormatter {
  final LogRedactor _redactor;

  HumanFormatter({LogRedactor? redactor}) : _redactor = redactor ?? LogRedactor();

  @override
  String format(LogRecord record) {
    final buf = StringBuffer()
      ..write(record.level.name)
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
      ..write(record.loggerName)
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
