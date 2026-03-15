import 'dart:convert';

import 'package:dartclaw_server/src/logging/log_context.dart';
import 'package:dartclaw_server/src/logging/log_formatter.dart';
import 'package:dartclaw_server/src/logging/log_redactor.dart';
import 'package:logging/logging.dart';
import 'package:test/test.dart';

void main() {
  group('HumanFormatter', () {
    late HumanFormatter formatter;

    setUp(() {
      formatter = HumanFormatter(redactor: LogRedactor());
    });

    test('formats basic log record', () {
      final record = LogRecord(Level.INFO, 'Server started', 'DartclawServer');
      final output = formatter.format(record);
      expect(output, contains('INFO:'));
      expect(output, contains('DartclawServer: Server started'));
    });

    test('includes correlation IDs when in zone', () {
      LogContext.runWith(
        () {
          final record = LogRecord(Level.INFO, 'Turn started', 'TurnManager');
          final output = formatter.format(record);
          expect(output, contains('[session=sess-1 turn=turn-1]'));
          expect(output, contains('TurnManager: Turn started'));
        },
        sessionId: 'sess-1',
        turnId: 'turn-1',
      );
    });

    test('omits correlation IDs when not in zone', () {
      final record = LogRecord(Level.INFO, 'Startup', 'Main');
      final output = formatter.format(record);
      expect(output, isNot(contains('[session=')));
      expect(output, isNot(contains('[turn=')));
    });

    test('includes error and stackTrace when present', () {
      final record = LogRecord(Level.SEVERE, 'Crash', 'Worker', StateError('bad state'), StackTrace.current);
      final output = formatter.format(record);
      expect(output, contains('SEVERE:'));
      expect(output, contains('bad state'));
    });

    test('colorize wraps level and logger name in ANSI codes', () {
      final colored = HumanFormatter(redactor: LogRedactor(), colorize: true);
      final severe = colored.format(LogRecord(Level.SEVERE, 'crash', 'X'));
      expect(severe, contains('\x1B[31mSEVERE\x1B[0m'));

      // Logger name wrapped in stable color (same logger = same color across calls)
      final output = colored.format(LogRecord(Level.INFO, 'msg', 'GowaManager'));
      expect(output, matches(RegExp(r'\x1B\[\d+mGowaManager\x1B\[0m')));
      final output2 = colored.format(LogRecord(Level.WARNING, 'x', 'GowaManager'));
      final color1 = RegExp(r'(\x1B\[\d+m)GowaManager').firstMatch(output)!.group(1);
      final color2 = RegExp(r'(\x1B\[\d+m)GowaManager').firstMatch(output2)!.group(1);
      expect(color1, equals(color2));
    });

    test('colorize false emits plain level', () {
      final plain = HumanFormatter(redactor: LogRedactor(), colorize: false);
      final output = plain.format(LogRecord(Level.SEVERE, 'crash', 'X'));
      expect(output, contains('SEVERE:'));
      expect(output, isNot(contains('\x1B[')));
    });

    test('redacts sensitive data', () {
      final record = LogRecord(Level.INFO, 'Key: sk-ant-secret123_key', 'Config');
      final output = formatter.format(record);
      expect(output, contains('***'));
      expect(output, isNot(contains('secret123_key')));
    });
  });

  group('JsonFormatter', () {
    late JsonFormatter formatter;

    setUp(() {
      formatter = JsonFormatter(redactor: LogRedactor());
    });

    test('produces valid JSON', () {
      final record = LogRecord(Level.INFO, 'Hello', 'Test');
      final output = formatter.format(record);
      final json = jsonDecode(output) as Map<String, dynamic>;
      expect(json['level'], 'INFO');
      expect(json['logger'], 'Test');
      expect(json['message'], 'Hello');
      expect(json['time'], isNotEmpty);
    });

    test('includes correlation IDs from zone', () {
      LogContext.runWith(
        () {
          final record = LogRecord(Level.INFO, 'Turn started', 'TurnManager');
          final output = formatter.format(record);
          final json = jsonDecode(output) as Map<String, dynamic>;
          expect(json['sessionId'], 'sess-abc');
          expect(json['turnId'], 'turn-xyz');
        },
        sessionId: 'sess-abc',
        turnId: 'turn-xyz',
      );
    });

    test('omits null fields', () {
      final record = LogRecord(Level.INFO, 'No context', 'Test');
      final output = formatter.format(record);
      final json = jsonDecode(output) as Map<String, dynamic>;
      expect(json.containsKey('sessionId'), isFalse);
      expect(json.containsKey('turnId'), isFalse);
      expect(json.containsKey('error'), isFalse);
      expect(json.containsKey('stackTrace'), isFalse);
    });

    test('includes error when present', () {
      final record = LogRecord(Level.SEVERE, 'Fail', 'Worker', Exception('boom'));
      final output = formatter.format(record);
      final json = jsonDecode(output) as Map<String, dynamic>;
      expect(json['error'], contains('boom'));
    });

    test('redacts sensitive data in JSON', () {
      final record = LogRecord(Level.INFO, 'Token: Bearer eyJxyz.abc.def', 'Auth');
      final output = formatter.format(record);
      expect(output, contains('***'));
      expect(output, isNot(contains('abc.def')));
    });

    test('time is UTC ISO8601', () {
      final record = LogRecord(Level.INFO, 'Test', 'Test');
      final output = formatter.format(record);
      final json = jsonDecode(output) as Map<String, dynamic>;
      expect(json['time'] as String, endsWith('Z'));
    });
  });
}
