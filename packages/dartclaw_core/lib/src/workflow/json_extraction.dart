import 'dart:convert';

/// Extracts a JSON value from raw text using a 4-strategy fallback chain.
///
/// Strategies (tried in order):
/// 1. Raw parse — attempt `jsonDecode` on the full text
/// 2. ```json fenced — extract content from ```json ... ``` blocks
/// 3. Bare fenced — extract content from ``` ... ``` blocks
/// 4. Pattern scan — find longest `{...}` or `[...]` balanced substring
///
/// Returns the parsed JSON value (Map or List).
/// Throws [FormatException] with descriptive message on failure.
Object extractJson(String raw) {
  // Strategy 1: Raw parse.
  try {
    final result = jsonDecode(raw.trim());
    if (result is Map || result is List) return result as Object;
  } on FormatException {
    // Fall through to next strategy.
  }

  // Strategy 2: ```json fenced blocks.
  final jsonFenced = _extractFencedBlock(raw, requireJson: true);
  if (jsonFenced != null) {
    try {
      final result = jsonDecode(jsonFenced);
      if (result is Map || result is List) return result as Object;
    } on FormatException {
      // Fall through.
    }
  }

  // Strategy 3: Bare ``` fenced blocks.
  final bareFenced = _extractFencedBlock(raw, requireJson: false);
  if (bareFenced != null) {
    try {
      final result = jsonDecode(bareFenced);
      if (result is Map || result is List) return result as Object;
    } on FormatException {
      // Fall through.
    }
  }

  // Strategy 4: Longest balanced brace/bracket pattern.
  final pattern = _extractLongestBalanced(raw);
  if (pattern != null) {
    try {
      final result = jsonDecode(pattern);
      if (result is Map || result is List) return result as Object;
    } on FormatException {
      // Fall through.
    }
  }

  // All strategies failed.
  final preview = raw.length > 500 ? '${raw.substring(0, 500)}...' : raw;
  throw FormatException(
    'JSON extraction failed after all strategies '
    '(raw parse, json-fenced, bare-fenced, pattern scan). '
    'Raw output (first 500 chars):\n$preview',
  );
}

/// Extracts content from the first markdown fenced code block.
///
/// When [requireJson] is true, only matches ```json blocks.
/// When false, matches any ``` block (but NOT ```json blocks — those are
/// handled by the requireJson=true path first).
String? _extractFencedBlock(String text, {required bool requireJson}) {
  final pattern = requireJson
      ? RegExp(r'```json\s*\n([\s\S]*?)\n\s*```')
      : RegExp(r'```(?!json)\w*\s*\n([\s\S]*?)\n\s*```');
  final match = pattern.firstMatch(text);
  return match?.group(1)?.trim();
}

/// Finds the longest balanced `{...}` or `[...]` substring.
///
/// Scans for opening braces/brackets and tracks nesting depth.
/// Handles JSON string literals (ignores braces inside quoted strings).
/// Truncates input to 100K chars to prevent excessive CPU usage.
/// Returns the longest balanced substring found, or null.
String? _extractLongestBalanced(String text) {
  // Truncate to prevent CPU-bound scanning on very large inputs.
  final input = text.length > 100000 ? text.substring(0, 100000) : text;

  String? longest;

  for (final open in ['{', '[']) {
    final close = open == '{' ? '}' : ']';
    var i = 0;
    while (i < input.length) {
      if (input[i] == open) {
        var depth = 1;
        var inString = false;
        var escape = false;
        var j = i + 1;
        while (j < input.length && depth > 0) {
          final c = input[j];
          if (escape) {
            escape = false;
          } else if (c == r'\') {
            escape = true;
          } else if (c == '"') {
            inString = !inString;
          } else if (!inString) {
            if (c == open) depth++;
            if (c == close) depth--;
          }
          j++;
        }
        if (depth == 0) {
          final candidate = input.substring(i, j);
          if (longest == null || candidate.length > longest.length) {
            longest = candidate;
          }
        }
      }
      i++;
    }
  }

  return longest;
}

/// Splits text into trimmed non-empty lines.
List<String> extractLines(String raw) {
  return raw
      .split('\n')
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .toList();
}
