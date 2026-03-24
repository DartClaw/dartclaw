import 'package:dartclaw_models/dartclaw_models.dart';
import 'package:test/test.dart';

void main() {
  group('ToolCallRecord', () {
    test('constructs with all fields', () {
      const record = ToolCallRecord(
        name: 'Bash',
        success: true,
        durationMs: 150,
        errorType: null,
        context: 'dart test',
      );
      expect(record.name, 'Bash');
      expect(record.success, isTrue);
      expect(record.durationMs, 150);
      expect(record.errorType, isNull);
      expect(record.context, 'dart test');
    });

    test('constructs with error fields', () {
      const record = ToolCallRecord(
        name: 'Write',
        success: false,
        durationMs: 42,
        errorType: 'tool_error',
        context: 'lib/main.dart',
      );
      expect(record.name, 'Write');
      expect(record.success, isFalse);
      expect(record.durationMs, 42);
      expect(record.errorType, 'tool_error');
      expect(record.context, 'lib/main.dart');
    });

    test('toJson output shape — success, no errorType', () {
      const record = ToolCallRecord(name: 'Read', success: true, durationMs: 10);
      final json = record.toJson();
      expect(json['name'], 'Read');
      expect(json['success'], isTrue);
      expect(json['durationMs'], 10);
      expect(json.containsKey('errorType'), isFalse);
    });

    test('toJson includes errorType when present', () {
      const record = ToolCallRecord(
        name: 'Bash',
        success: false,
        durationMs: 5,
        errorType: 'incomplete',
        context: 'dart format .',
      );
      final json = record.toJson();
      expect(json['errorType'], 'incomplete');
      expect(json['context'], 'dart format .');
    });

    test('fromJson round-trips correctly', () {
      const original = ToolCallRecord(name: 'Edit', success: true, durationMs: 77, context: 'lib/auth.dart');
      final decoded = ToolCallRecord.fromJson(original.toJson());
      expect(decoded, equals(original));
    });

    test('fromJson round-trips with errorType', () {
      const original = ToolCallRecord(
        name: 'Bash',
        success: false,
        durationMs: 123,
        errorType: 'tool_error',
        context: 'dart test',
      );
      final decoded = ToolCallRecord.fromJson(original.toJson());
      expect(decoded, equals(original));
      expect(decoded.errorType, 'tool_error');
      expect(decoded.context, 'dart test');
    });

    test('errorType omitted from JSON when null', () {
      const record = ToolCallRecord(name: 'Read', success: true, durationMs: 1);
      final json = record.toJson();
      expect(json.containsKey('errorType'), isFalse);
      expect(json.containsKey('context'), isFalse);
    });

    test('equality and hashCode', () {
      const a = ToolCallRecord(name: 'Bash', success: true, durationMs: 50, context: 'dart test');
      const b = ToolCallRecord(name: 'Bash', success: true, durationMs: 50, context: 'dart test');
      const c = ToolCallRecord(name: 'Bash', success: false, durationMs: 50, context: 'dart test');
      const d = ToolCallRecord(name: 'Bash', success: true, durationMs: 50, context: 'dart analyze');
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a, isNot(equals(c)));
      expect(a, isNot(equals(d)));
    });
  });
}
