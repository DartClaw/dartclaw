import 'package:dartclaw_workflow/src/workflow/review_finding_derivations.dart';
import 'package:test/test.dart';

void main() {
  group('schema-emitted count reading', () {
    test('asInteger accepts the integer shapes a schema-validated count arrives in', () {
      expect(asInteger(4), 4);
      expect(asInteger(4.0), 4);
      expect(asInteger('4'), 4);
      expect(asInteger('  4 '), 4);
      expect(asInteger(4.5), isNull);
      expect(asInteger(double.nan), isNull);
      expect(asInteger(null), isNull);
      expect(asInteger('four'), isNull);
      expect(asInteger([4]), isNull);
    });

    test('firstIntegerForKeys reads the first declared key that carries a count', () {
      const payload = {'review.findings_count': 4, 'findings_count': 9};

      expect(firstIntegerForKeys(payload, const ['review.findings_count', 'findings_count']), 4);
      expect(firstIntegerForKeys(payload, const ['findings_count', 'review.findings_count']), 9);
      expect(firstIntegerForKeys(payload, const ['gating_findings_count']), isNull);
      expect(firstIntegerForKeys(const {}, const ['findings_count']), isNull);
    });

    test('a count is never manufactured from a verdict object in the same payload', () {
      // The counts a review reports are the schema-enforced integers it emitted.
      // A verdict's `findings` list, a nested map, or any other lookalike is not
      // a count source — an omitted count stays absent and surfaces as a schema
      // validation failure upstream.
      const payload = {
        'verdict': {
          'findings_count': 6,
          'findings': [
            {'severity': 'critical', 'location': 'a.dart:1', 'description': 'critical'},
            {'severity': 'high', 'location': 'a.dart:2', 'description': 'high'},
          ],
        },
        'unrelated': {'findings_count': 9},
      };

      expect(firstIntegerForKeys(payload, const ['review.findings_count', 'findings_count']), isNull);
      expect(firstIntegerForKeys(payload, const ['review.gating_findings_count', 'gating_findings_count']), isNull);
    });

    test('a gating count is never substituted by the total count', () {
      const payload = {'findings_count': 6};

      expect(firstIntegerForKeys(payload, const ['review.gating_findings_count', 'gating_findings_count']), isNull);
    });
  });
}
