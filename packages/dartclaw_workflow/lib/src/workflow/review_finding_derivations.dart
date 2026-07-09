import 'dart:convert';

import 'review_scoring_fragment.dart';
import 'step_output_validation_helpers.dart';

/// Derives a review finding count from a structured output payload.
///
/// Handles both `.findings_count` and `.gating_findings_count` output keys,
/// searching across multiple source maps in priority order.
int? deriveReviewFindingCount(
  String outputKey,
  Map<String, dynamic> outputs,
  Map<String, dynamic>? workflowContextPayload,
  Map<String, dynamic> structuredOutputPayload, {
  String? gatingSeverity,
}) {
  if (!_isFindingsCountKey(outputKey) && !_isGatingFindingsCountKey(outputKey)) {
    return null;
  }
  final sources = [outputs, workflowContextPayload, structuredOutputPayload];
  for (final source in sources) {
    final exactCount = findIntegerValue(source, outputKey);
    if (exactCount != null) return exactCount;
  }

  final bareKey = _bareFindingCountKey(outputKey);
  if (bareKey != outputKey) {
    for (final source in sources) {
      final bareCount = findIntegerValue(source, bareKey);
      if (bareCount != null) return bareCount;
    }
  }

  for (final source in sources) {
    final count = deriveReviewFindingCountFromMap(outputKey, source, gatingSeverity: gatingSeverity);
    if (count != null) return count;
  }
  return null;
}

/// Returns whether [outputKey] is one of the review finding count outputs.
bool isReviewFindingCountKey(String outputKey) =>
    _isFindingsCountKey(outputKey) || _isGatingFindingsCountKey(outputKey);

/// Returns the first integer found in [values] for any of [keys].
int? firstIntegerForKeys(Map<String, dynamic> values, Iterable<String> keys) {
  for (final key in keys) {
    final count = asInteger(values[key]);
    if (count != null) return count;
  }
  return null;
}

/// Looks up a top-level integer value from [source] by [key].
int? findIntegerValue(Map<String, dynamic>? source, String key) {
  if (source == null) return null;
  return asInteger(source[key]);
}

/// Coerces [value] to an integer when safe to do so.
int? asInteger(Object? value) {
  if (value is int) return value;
  if (value is num && value.isFinite && value.roundToDouble() == value) return value.toInt();
  if (value is String) return int.tryParse(value.trim());
  return null;
}

/// Searches [source] for a review verdict map and extracts the finding count.
int? deriveReviewFindingCountFromMap(String outputKey, Map<String, dynamic>? source, {String? gatingSeverity}) {
  if (source == null) return null;
  final directCount = deriveReviewFindingCountFromVerdict(outputKey, source, gatingSeverity: gatingSeverity);
  if (directCount != null) return directCount;

  for (final value in source.values) {
    final verdict = asVerdictMap(value);
    if (verdict == null) continue;
    final count = deriveReviewFindingCountFromVerdict(outputKey, verdict, gatingSeverity: gatingSeverity);
    if (count != null) return count;
  }
  return null;
}

/// Extracts a finding count from a verdict map that contains a `findings` key.
int? deriveReviewFindingCountFromVerdict(String outputKey, Map<String, dynamic> verdict, {String? gatingSeverity}) {
  if (!verdict.containsKey('findings')) return null;
  final findings = verdict['findings'];
  if (_isFindingsCountKey(outputKey)) {
    if (findings is Iterable) return findings.length;
    final findingsCount = verdict['findings_count'];
    if (findingsCount is int) return findingsCount;
    if (findingsCount is num) return findingsCount.toInt();
  }
  if (_isGatingFindingsCountKey(outputKey)) {
    if (findings is! Iterable) return null;
    return findings.where((finding) => isGatingFinding(finding, gatingSeverity: gatingSeverity)).length;
  }
  return null;
}

bool _isFindingsCountKey(String outputKey) => outputKey == 'findings_count' || outputKey.endsWith('.findings_count');

bool _isGatingFindingsCountKey(String outputKey) =>
    outputKey == 'gating_findings_count' || outputKey.endsWith('.gating_findings_count');

String _bareFindingCountKey(String outputKey) =>
    _isGatingFindingsCountKey(outputKey) ? 'gating_findings_count' : 'findings_count';

/// Coerces [value] to a string-keyed map when possible.
Map<String, dynamic>? asVerdictMap(Object? value) {
  final map = asStringKeyedMap(value);
  if (map != null) return map;
  if (value is String) {
    try {
      final decoded = jsonDecode(value);
      return asStringKeyedMap(decoded);
    } on FormatException {
      return null;
    }
  }
  return null;
}

/// Returns true when [finding] is at or above the resolved gating threshold.
bool isGatingFinding(Object? finding, {String? gatingSeverity}) {
  final findingMap = asStringKeyedMap(finding);
  final severity = findingMap?['severity']?.toString().trim().toLowerCase();
  final severityIndex = reviewFindingSeverityTiers.indexOf(severity ?? '');
  if (severityIndex < 0) return true;
  final threshold = gatingSeverity?.trim().toLowerCase();
  final thresholdIndex = reviewFindingSeverityTiers.indexOf(
    isValidReviewFindingSeverity(threshold) ? threshold! : defaultGatingSeverity,
  );
  return severityIndex <= thresholdIndex;
}
