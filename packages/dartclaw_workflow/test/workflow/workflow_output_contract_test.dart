import 'package:dartclaw_workflow/src/workflow/workflow_output_contract.dart';
import 'package:test/test.dart';

void main() {
  group('parseStepOutcomePayload (S36)', () {
    test('parses a well-formed succeeded payload', () {
      const message = 'some output\n<step-outcome>{"outcome":"succeeded","reason":"done"}</step-outcome>';
      final payload = parseStepOutcomePayload(message);
      expect(payload, isNotNull);
      expect(payload!.outcome, equals('succeeded'));
      expect(payload.reason, equals('done'));
    });

    test('parses failed payload', () {
      const message = '<step-outcome>{"outcome":"failed","reason":"3 critical findings"}</step-outcome>';
      final payload = parseStepOutcomePayload(message);
      expect(payload?.outcome, equals('failed'));
      expect(payload?.reason, equals('3 critical findings'));
    });

    test('parses needsInput payload', () {
      const message = '<step-outcome>{"outcome":"needsInput","reason":"ambiguous"}</step-outcome>';
      final payload = parseStepOutcomePayload(message);
      expect(payload?.outcome, equals('needsInput'));
    });

    test('returns null when tag is absent', () {
      const message = 'no marker here';
      expect(parseStepOutcomePayload(message), isNull);
    });

    test('returns null when payload is malformed JSON', () {
      const message = '<step-outcome>{not json}</step-outcome>';
      expect(parseStepOutcomePayload(message), isNull);
    });

    test('returns null when outcome value is not in the allowed set', () {
      const message = '<step-outcome>{"outcome":"maybe","reason":"bogus"}</step-outcome>';
      expect(parseStepOutcomePayload(message), isNull);
    });

    test('uses the last well-formed marker when multiple are present', () {
      const message =
          '<step-outcome>{"outcome":"failed","reason":"first"}</step-outcome>\n'
          '<step-outcome>{"outcome":"succeeded","reason":"final"}</step-outcome>';
      final payload = parseStepOutcomePayload(message);
      expect(payload?.outcome, equals('succeeded'));
      expect(payload?.reason, equals('final'));
    });

    test('reason defaults to empty string when missing', () {
      const message = '<step-outcome>{"outcome":"succeeded"}</step-outcome>';
      final payload = parseStepOutcomePayload(message);
      expect(payload?.outcome, equals('succeeded'));
      expect(payload?.reason, equals(''));
    });
  });
}
