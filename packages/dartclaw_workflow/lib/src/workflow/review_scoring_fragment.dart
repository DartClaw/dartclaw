const defaultGatingSeverity = 'high';

const reviewFindingSeverityTiers = ['critical', 'high', 'medium', 'low'];

const reviewScoringFragmentThresholdToken = '{threshold}';

const reviewScoringFragment = '''
## Review Finding Scoring

Classify each finding with exactly one severity:
- critical: execution-breaking, data-loss, security, or release-blocking defects.
- high: defects likely to break required behavior or block safe completion.
- medium: important issues that should be reported but do not block this loop.
- low: minor issues, polish, or optional improvements.

Set `gating_findings_count` to the number of findings whose severity is at or above `{threshold}`.
Findings with missing or unrecognized severity count as gating.
Findings below `{threshold}` are reported but do not block remediation-loop convergence.
''';

String reviewScoringFragmentFor(String gatingSeverity) =>
    reviewScoringFragment.replaceAll(reviewScoringFragmentThresholdToken, gatingSeverity);

bool isValidReviewFindingSeverity(String? value) =>
    value != null && reviewFindingSeverityTiers.contains(value.trim().toLowerCase());
