import 'dart:convert';

/// Tag name delimiting a JSON payload in a knowledge-turn assistant reply.
///
/// Re-homed here in 0.25 when the workflow engine stopped parsing it: the
/// knowledge inbox's extraction and merge prompts quote this spelling, so it is
/// their protocol now, not the workflow output contract's.
const String workflowContextTag = 'workflow-context';

const String workflowContextOpen = '<$workflowContextTag>';

const String workflowContextClose = '</$workflowContextTag>';

/// Matches a `<workflow-context>...</workflow-context>` block and captures its
/// inner JSON payload in group 1.
final RegExp workflowContextRegExp = RegExp('$workflowContextOpen\\s*([\\s\\S]*?)\\s*$workflowContextClose');

/// Parses the tagged JSON payload out of a knowledge-turn assistant reply.
///
/// Later blocks win over earlier ones. Returns an empty map when the reply
/// carries no parseable block, or when [requiredKeys] is non-empty and the
/// merged payload populates none of them — the caller then falls back to
/// reading the whole reply as JSON.
final class WorkflowTurnExtractor {
  const new();

  Map<String, Object?> parse(String text, {Iterable<String> requiredKeys = const <String>[]}) {
    final merged = <String, Object?>{};
    for (final payload in _payloads(text)) {
      merged.addAll(payload);
    }

    final required = requiredKeys.toList(growable: false);
    if (required.isNotEmpty && !required.any((key) => isNonEmptyPayloadValue(merged[key]))) {
      return const <String, Object?>{};
    }
    return merged;
  }

  static bool isNonEmptyPayloadValue(Object? value) {
    if (value == null) return false;
    if (value is String) return value.isNotEmpty;
    if (value is Iterable) return value.isNotEmpty;
    if (value is Map) return value.isNotEmpty;
    return true;
  }

  List<Map<String, Object?>> _payloads(String text) {
    return workflowContextRegExp
        .allMatches(text)
        .map((match) => match.group(1))
        .whereType<String>()
        .map(_decodePayload)
        .whereType<Map<String, Object?>>()
        .toList(growable: false);
  }

  Map<String, Object?>? _decodePayload(String rawJson) {
    try {
      final decoded = jsonDecode(rawJson);
      if (decoded is! Map) return null;
      if (decoded.isEmpty) return null;
      return decoded.map((key, value) => MapEntry(key.toString(), value));
    } on FormatException {
      return null;
    }
  }
}
