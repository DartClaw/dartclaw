import 'package:dartclaw_workflow/src/workflow/review_finding_derivations.dart';
import 'package:test/test.dart';

void main() {
  group('output-capture residue trim', () {
    const verdict = {
      'findings': [
        {'severity': 'critical', 'location': 'a.dart:1', 'description': 'critical'},
        {'severity': 'high', 'location': 'a.dart:2', 'description': 'high'},
        {'severity': 'high', 'location': 'a.dart:3', 'description': 'high'},
        {'severity': 'medium', 'location': 'a.dart:4', 'description': 'medium'},
        {'severity': 'low', 'location': 'a.dart:5', 'description': 'low'},
        {'location': 'a.dart:6', 'description': 'missing'},
      ],
    };

    test('S01 derives total and gating counts independently from verdict findings', () {
      expect(deriveReviewFindingCount('review.findings_count', const {}, const {}, {'verdict': verdict}), 6);
      expect(deriveReviewFindingCount('review.gating_findings_count', const {}, const {}, {'verdict': verdict}), 4);
    });

    test('S02 resolves bare-suffix aliases independently for prefixed keys', () {
      const payload = {'findings_count': 3, 'gating_findings_count': 1};

      expect(deriveReviewFindingCount('architecture-review.findings_count', payload, const {}, const {}), 3);
      expect(deriveReviewFindingCount('architecture-review.gating_findings_count', payload, const {}, const {}), 1);
    });

    test('S03 gating count does not substitute the total count', () {
      expect(
        deriveReviewFindingCount('gating_findings_count', const {'findings_count': 6}, const {}, const {}),
        isNull,
      );
    });

    test('S04 top-level count lookup ignores unrelated nested integer values', () {
      expect(
        deriveReviewFindingCount(
          'findings_count',
          const {
            'unrelated': {'findings_count': 9},
          },
          const {},
          const {},
        ),
        isNull,
      );
    });
  });

  group('review finding severity-threshold gating', () {
    const verdict = {
      'findings_count': 6,
      'findings': [
        {'severity': 'critical', 'location': 'a.dart:1', 'description': 'critical'},
        {'severity': 'high', 'location': 'a.dart:2', 'description': 'high'},
        {'severity': 'medium', 'location': 'a.dart:3', 'description': 'medium'},
        {'severity': 'low', 'location': 'a.dart:4', 'description': 'low'},
        {'severity': 'unknown', 'location': 'a.dart:5', 'description': 'unknown'},
        {'location': 'a.dart:6', 'description': 'missing'},
      ],
    };

    test('default high counts critical, high, and malformed severities only', () {
      expect(isGatingFinding({'severity': 'critical'}), isTrue);
      expect(isGatingFinding({'severity': 'high'}), isTrue);
      expect(isGatingFinding({'severity': 'medium'}), isFalse);
      expect(isGatingFinding({'severity': 'low'}), isFalse);
      expect(isGatingFinding({'severity': 'unknown'}), isTrue);
      expect(isGatingFinding({'description': 'missing severity'}), isTrue);
      expect(deriveReviewFindingCountFromVerdict('review.gating_findings_count', verdict), 4);
    });

    test('critical threshold counts only critical and malformed severities', () {
      expect(isGatingFinding({'severity': 'high'}, gatingSeverity: 'critical'), isFalse);
      expect(isGatingFinding({'severity': 'critical'}, gatingSeverity: 'critical'), isTrue);
      expect(isGatingFinding({'severity': 'unknown'}, gatingSeverity: 'critical'), isTrue);
      expect(
        deriveReviewFindingCountFromVerdict('review.gating_findings_count', verdict, gatingSeverity: 'critical'),
        3,
      );
    });

    test('derives bare count keys from verdict findings', () {
      expect(deriveReviewFindingCountFromVerdict('findings_count', verdict), 6);
      expect(deriveReviewFindingCountFromVerdict('gating_findings_count', verdict), 4);
      expect(
        deriveReviewFindingCount('gating_findings_count', const {}, const {}, {
          'verdict': verdict,
        }, gatingSeverity: 'critical'),
        3,
      );
    });

    test('structured findings list overrides contradictory verdict count', () {
      const contradictoryVerdict = {
        'findings_count': 0,
        'findings': [
          {'severity': 'critical', 'location': 'a.dart:1', 'description': 'critical'},
          {'severity': 'low', 'location': 'a.dart:2', 'description': 'low'},
        ],
      };

      expect(deriveReviewFindingCountFromVerdict('findings_count', contradictoryVerdict), 2);
      expect(deriveReviewFindingCountFromVerdict('gating_findings_count', contradictoryVerdict), 1);
    });
  });
}
