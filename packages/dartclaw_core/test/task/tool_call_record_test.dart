import 'package:dartclaw_core/dartclaw_core.dart' show ToolCallRecord;
import 'package:test/test.dart';

void main() {
  group('ToolCallRecord', () {
    test('toJson output shape — success, no errorType', () {
      final record = ToolCallRecord(name: 'Read', success: true, durationMs: 10);
      final json = record.toJson();
      expect(json['name'], 'Read');
      expect(json['success'], isTrue);
      expect(json['durationMs'], 10);
      expect(json.containsKey('errorType'), isFalse);
    });

    test('toJson includes errorType when present', () {
      final record = ToolCallRecord(
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
      final original = ToolCallRecord(name: 'Edit', success: true, durationMs: 77, context: 'lib/auth.dart');
      final decoded = ToolCallRecord.fromJson(original.toJson());
      expect(decoded, equals(original));
    });

    test('fromJson round-trips with errorType', () {
      final original = ToolCallRecord(
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
      final record = ToolCallRecord(name: 'Read', success: true, durationMs: 1);
      final json = record.toJson();
      expect(json.containsKey('errorType'), isFalse);
      expect(json.containsKey('context'), isFalse);
    });

    test('equality and hashCode', () {
      final a = ToolCallRecord(name: 'Bash', success: true, durationMs: 50, context: 'dart test');
      final b = ToolCallRecord(name: 'Bash', success: true, durationMs: 50, context: 'dart test');
      final c = ToolCallRecord(name: 'Bash', success: false, durationMs: 50, context: 'dart test');
      final d = ToolCallRecord(name: 'Bash', success: true, durationMs: 50, context: 'dart analyze');
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a, isNot(equals(c)));
      expect(a, isNot(equals(d)));
    });
  });
}
