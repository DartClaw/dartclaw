import 'dart:io';

import 'package:dartclaw_workflow/dartclaw_workflow.dart';
import 'package:dartclaw_workflow/src/workflow/follow_up_draft.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '_support/workflow_test_paths.dart';

WorkflowDefinition _builtIn(String fileName) =>
    WorkflowDefinitionParser().parse(File(p.join(workflowDefinitionsDir(), fileName)).readAsStringSync());

Map<String, Object?> _finding(String severity, String where) => {
  'severity': severity,
  'location': where,
  'description': 'problem at $where',
};

Map<String, Object?> _verdict(List<Map<String, Object?>> findings) => {
  'pass': true,
  'findings_count': findings.length,
  'findings': findings,
  'summary': 's',
};

WorkflowContext _context(Map<String, Object?> data) => WorkflowContext(data: data);

List<String> _locations(List<FollowUpFinding> findings) => [for (final finding in findings) finding.location];

void main() {
  group('collectFollowUpFindings', () {
    final codeReview = _builtIn('code-review.yaml');

    test('S01: a clean review lists its medium and low findings with severity, location and description', () {
      final findings = collectFollowUpFindings(
        codeReview,
        _context({
          'review-code.verdict': _verdict([_finding('medium', 'a.dart:1'), _finding('low', 'b.dart:2')]),
          'review-code.gating_findings_count': 0,
        }),
      );

      expect(findings, [
        (severity: 'medium', location: 'a.dart:1', description: 'problem at a.dart:1'),
        (severity: 'low', location: 'b.dart:2', description: 'problem at b.dart:2'),
      ]);
    });

    test('S02: a remediated review contributes only its final verdict', () {
      final findings = collectFollowUpFindings(
        codeReview,
        _context({
          'review-code.verdict': _verdict([_finding('high', 'old.dart:1'), _finding('low', 'old.dart:2')]),
          'review-code.gating_findings_count': 1,
          're-review.verdict': _verdict([_finding('medium', 'new.dart:3')]),
          're-review.gating_findings_count': 0,
        }),
      );

      expect(_locations(findings), ['new.dart:3']);
    });

    test('S03: story reviews and the plan review merge; a story that needed remediation contributes nothing', () {
      final findings = collectFollowUpFindings(
        _builtIn('plan-and-implement.yaml'),
        _context({
          'story_results': [
            {
              'review-story': {
                'verdict': _verdict([_finding('low', 'story1.dart:1')]),
                'gating_findings_count': 0,
              },
            },
            {
              'review-story': {
                'verdict': _verdict([_finding('high', 'story2.dart:1'), _finding('low', 'story2.dart:2')]),
                'gating_findings_count': 1,
              },
            },
            {'error': true, 'kind': 'iteration_failure', 'message': 'boom'},
          ],
          'plan-review.verdict': _verdict([_finding('medium', 'plan.dart:9')]),
          'plan-review.gating_findings_count': 0,
        }),
      );

      expect(_locations(findings), ['story1.dart:1', 'plan.dart:9']);
    });

    test('plan-and-implement: a remediated plan review is superseded by the bare re-review verdict', () {
      final findings = collectFollowUpFindings(
        _builtIn('plan-and-implement.yaml'),
        _context({
          'story_results': <Object?>[],
          'plan-review.verdict': _verdict([_finding('high', 'plan.dart:1')]),
          'plan-review.gating_findings_count': 1,
          'verdict': _verdict([_finding('low', 'plan.dart:2')]),
          'gating_findings_count': 0,
        }),
      );

      expect(_locations(findings), ['plan.dart:2']);
    });

    test('story-and-implement: an integrated-review verdict with a zero gating count lists its low finding', () {
      final findings = collectFollowUpFindings(
        _builtIn('story-and-implement.yaml'),
        _context({
          'integrated-review.verdict': _verdict([_finding('low', 'x.dart:1')]),
          'integrated-review.gating_findings_count': 0,
        }),
      );

      expect(_locations(findings), ['x.dart:1']);
    });

    test('S04: nothing to follow up yields an empty list', () {
      final cases = <String, Map<String, Object?>>{
        'no verdict emitted': {},
        'empty findings': {'review-code.verdict': _verdict([]), 'review-code.gating_findings_count': 0},
        'gating severities are the loop\'s business, even in a zero-count verdict': {
          'review-code.verdict': _verdict([_finding('critical', 'a.dart:1'), _finding('high', 'a.dart:2')]),
          'review-code.gating_findings_count': 0,
        },
        'missing or unrecognized severity gates': {
          'review-code.verdict': _verdict([
            {'location': 'a.dart:1', 'description': 'd'},
            _finding('blocker', 'a.dart:2'),
          ]),
          'review-code.gating_findings_count': 0,
        },
        'the model-written count is not derived from the findings': {
          'review-code.verdict': {..._verdict([]), 'findings_count': 4},
          'review-code.gating_findings_count': 0,
        },
      };
      for (final entry in cases.entries) {
        expect(collectFollowUpFindings(codeReview, _context(entry.value)), isEmpty, reason: entry.key);
      }
    });

    test('a verdict whose step declares no gating count is kept', () {
      final definition = WorkflowDefinitionParser().parse('''
name: lone-review
description: A review without a remediation loop.
steps:
  - id: review
    name: Review
    skill: andthen:review
    prompt: review it
    outputs:
      verdict: verdict
''');

      final findings = collectFollowUpFindings(
        definition,
        _context({
          'verdict': _verdict([_finding('low', 'a:1')]),
        }),
      );

      expect(_locations(findings), ['a:1']);
    });
  });
}
