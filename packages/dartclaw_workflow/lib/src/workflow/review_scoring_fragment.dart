/// Review severities, most severe first. The one definition of the severity
/// order: the `verdict` preset's enum, the scoring prompt and [isGatingSeverity]
/// all read it.
const reviewSeverityOrder = ['critical', 'high', 'medium', 'low'];

const defaultGatingSeverity = 'high';

const _severityMeaning = {
  'critical': 'execution-breaking, data-loss, security, or release-blocking defects.',
  'high': 'defects likely to break required behavior or block safe completion.',
  'medium': 'important issues that should be reported but do not block this loop.',
  'low': 'minor issues, polish, or optional improvements.',
};

/// Whether a finding of [severity] blocks remediation-loop convergence.
///
/// A missing or unrecognized severity gates, so a malformed finding is never
/// silently demoted to a follow-up.
bool isGatingSeverity(String? severity) {
  final rank = reviewSeverityOrder.indexOf(severity ?? '');
  return rank < 0 || rank <= reviewSeverityOrder.indexOf(defaultGatingSeverity);
}

String reviewScoringFragmentFor(String gatingSeverity) =>
    '''
## Review Finding Scoring

Classify each finding with exactly one severity:
${[for (final severity in reviewSeverityOrder) '- $severity: ${_severityMeaning[severity]}'].join('\n')}

Set `gating_findings_count` to the number of findings whose severity is at or above `$gatingSeverity`.
Findings with missing or unrecognized severity count as gating.
Findings below `$gatingSeverity` are reported but do not block remediation-loop convergence.
''';
