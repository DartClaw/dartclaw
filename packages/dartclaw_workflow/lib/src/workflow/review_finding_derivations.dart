import 'dart:convert';

/// Derives a review finding count from a structured output payload.
///
/// Handles both `.findings_count` and `.gating_findings_count` output keys,
/// searching across multiple source maps in priority order.
int? deriveReviewFindingCount(
  String outputKey,
  Map<String, dynamic> outputs,
  Map<String, dynamic>? workflowContextPayload,
  Map<String, dynamic> structuredOutputPayload,
) {
  if (!outputKey.endsWith('.findings_count') && !outputKey.endsWith('.gating_findings_count')) {
    return null;
  }
  for (final source in [outputs, workflowContextPayload, structuredOutputPayload]) {
    final count = deriveReviewFindingCountFromMap(outputKey, source);
    if (count != null) return count;
  }
  if (outputKey.endsWith('.findings_count')) {
    for (final source in [outputs, workflowContextPayload, structuredOutputPayload]) {
      final totalCount = findIntegerValue(source, 'findings_count');
      if (totalCount != null) return totalCount;
    }
  }
  if (outputKey.endsWith('.gating_findings_count')) {
    final totalKey = outputKey.replaceFirst('.gating_findings_count', '.findings_count');
    for (final source in [workflowContextPayload, structuredOutputPayload]) {
      final totalCount = findIntegerValue(source, totalKey);
      if (totalCount != null) return totalCount;
    }
    for (final source in [outputs, workflowContextPayload, structuredOutputPayload]) {
      final gatingCount = findIntegerValue(source, 'gating_findings_count');
      if (gatingCount != null) return gatingCount;
    }
    for (final source in [outputs, workflowContextPayload, structuredOutputPayload]) {
      final totalCount = findIntegerValue(source, 'findings_count');
      if (totalCount != null) return totalCount;
    }
  }
  return null;
}

/// Returns the first integer found in [values] for any of [keys].
int? firstIntegerForKeys(Map<String, dynamic> values, Iterable<String> keys) {
  for (final key in keys) {
    final count = asInteger(values[key]);
    if (count != null) return count;
  }
  return null;
}

/// Looks up an integer value from [source] by [key], including one level of nesting.
int? findIntegerValue(Map<String, dynamic>? source, String key) {
  if (source == null) return null;
  final directValue = asInteger(source[key]);
  if (directValue != null) return directValue;
  for (final value in source.values) {
    final map = asStringKeyedMap(value);
    final nestedValue = asInteger(map?[key]);
    if (nestedValue != null) return nestedValue;
  }
  return null;
}

/// Coerces [value] to an integer when safe to do so.
int? asInteger(Object? value) {
  if (value is int) return value;
  if (value is num && value.isFinite && value.roundToDouble() == value) return value.toInt();
  if (value is String) return int.tryParse(value.trim());
  return null;
}

/// Searches [source] for a review verdict map and extracts the finding count.
int? deriveReviewFindingCountFromMap(String outputKey, Map<String, dynamic>? source) {
  if (source == null) return null;
  final directCount = deriveReviewFindingCountFromVerdict(outputKey, source);
  if (directCount != null) return directCount;

  for (final value in source.values) {
    final verdict = asVerdictMap(value);
    if (verdict == null) continue;
    final count = deriveReviewFindingCountFromVerdict(outputKey, verdict);
    if (count != null) return count;
  }
  return null;
}

/// Extracts a finding count from a verdict map that contains a `findings` key.
int? deriveReviewFindingCountFromVerdict(String outputKey, Map<String, dynamic> verdict) {
  if (!verdict.containsKey('findings')) return null;
  if (outputKey.endsWith('.findings_count')) {
    final findingsCount = verdict['findings_count'];
    if (findingsCount is int) return findingsCount;
    if (findingsCount is num) return findingsCount.toInt();
  }
  if (outputKey.endsWith('.gating_findings_count')) {
    final findings = verdict['findings'];
    if (findings is! Iterable) return null;
    return findings.where(isGatingFinding).length;
  }
  return null;
}

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

/// Returns true when [finding] is not a low-severity finding.
bool isGatingFinding(Object? finding) {
  final findingMap = asStringKeyedMap(finding);
  final severity = findingMap?['severity']?.toString().trim().toLowerCase();
  return severity == null || severity != 'low';
}

/// Normalizes [value] to a string-keyed `Map<String, dynamic>` or returns null.
Map<String, dynamic>? asStringKeyedMap(Object? value) {
  return switch (value) {
    final Map<String, dynamic> typed => Map<String, dynamic>.from(typed),
    final Map<dynamic, dynamic> dynamicMap => dynamicMap.map((key, value) => MapEntry('$key', value)),
    _ => null,
  };
}
