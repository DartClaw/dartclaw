import 'dart:math';

import 'package:logging/logging.dart';

/// Regex-based redaction for outbound text across all output paths.
///
/// Built-in patterns cover common secret types (API keys, AWS credentials,
/// Bearer tokens, PEM blocks, generic secrets). Custom patterns can be added
/// via [extraPatterns].
///
/// Secret assignments preserve their label and replace the value with `***`.
/// A secret-shaped key redacts its value unconditionally — prose that follows
/// such a key on the same line is over-redacted by design, because deciding
/// where the secret ends and the prose begins cannot be done safely.
/// Other matches use proportional reveal: `min(matchLength / 2, 8)` characters
/// preserved + `***`. PEM blocks are fully replaced with `[REDACTED]`.
///
/// The [redact] method never throws — errors are caught internally and the
/// original text is returned unchanged.
class MessageRedactor {
  static final _log = Logger('MessageRedactor');
  static final _authorizationHeader = RegExp(
    r'(^[ \t]*(?:Authorization|Proxy-Authorization)\s*:\s*)'
    r'(?:Basic\s+[A-Za-z0-9+/]+=*|Bearer\s+[A-Za-z0-9\-._~+/]+=*|'
    r'Negotiate\s+[A-Za-z0-9+/]+=*|Digest\s+[^\r\n]+|AWS4-HMAC-SHA256\s+[^\r\n]+)[ \t]*$',
    caseSensitive: false,
    multiLine: true,
  );
  static final _equalsAssignment = RegExp(
    r'(^|[^A-Za-z0-9_-])([A-Za-z][A-Za-z0-9_-]*)(\s*=\s*)([^\r\n]*?)'
    r'(?=(?:(?:[ \t]+|[,;]\s*)[A-Za-z][A-Za-z0-9_-]*\s*[:=])|$)',
    multiLine: true,
  );
  static final _colonAssignment = RegExp(
    r'(?:(^[ \t]*(?:(?:[-*+]|\d+[.)])[ \t]+)?)|([^A-Za-z0-9_\r\n-]))'
    r'([A-Za-z][A-Za-z0-9_-]*)(\s*:\s*)([^\r\n]*?)'
    r'(?=(?:(?:[ \t]+|[,;]\s*|(?:[\[{]\s*)+)[A-Za-z][A-Za-z0-9_-]*\s*[:=])|$)',
    multiLine: true,
  );
  static final _quotedColonAssignment = RegExp(
    r'(^|[,{]\s*)"([A-Za-z][A-Za-z0-9_-]*)"(\s*:\s*)',
    multiLine: true,
    caseSensitive: false,
  );
  static const _metadataPrefixes = {'has', 'is', 'requires', 'supports'};
  static final _closingDelimiters = RegExp(r'(\s*[}\]]+\s*)$');
  static final _terminalPunctuation = RegExp(r'([.!?]\s*)$');
  static final _jsonScalar = RegExp(r'(?:true|false|null|-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?)');
  static const _tokenMeasurementPrefixes = {
    'cached',
    'completion',
    'input',
    'max',
    'min',
    'output',
    'remaining',
    'total',
    'used',
  };
  static const _secretNouns = {
    'authorization',
    'authorizations',
    'cookie',
    'cookies',
    'credential',
    'credentials',
    'password',
    'passwords',
    'secret',
    'secrets',
    'token',
    'tokens',
  };

  List<({RegExp pattern, bool isPem})> _compiled;

  /// Creates a redactor with built-in patterns plus optional [extraPatterns].
  ///
  /// Invalid regexes in [extraPatterns] are logged as warnings and skipped.
  new({List<String> extraPatterns = const []}) : _compiled = _compilePatterns(extraPatterns);

  /// Whether [key] names a credential value rather than related metadata.
  static bool isSecretKey(Object key) {
    final words = _keyWords(key);
    if (words.isEmpty || _metadataPrefixes.contains(words.first)) return false;

    final last = words.last;
    if (last == 'token' || last == 'tokens') {
      return words.length == 1 || !_tokenMeasurementPrefixes.contains(words[words.length - 2]);
    }
    if (_secretNouns.contains(last)) return true;
    return (last == 'key' || last == 'keys') &&
        words.length > 1 &&
        (words.contains('api') ||
            words.contains('private') ||
            words.contains('secret') ||
            words[words.length - 2] == 'encryption' ||
            words[words.length - 2] == 'signing');
  }

  /// Recompiles redaction patterns with [extraPatterns] replacing any prior extras.
  void recompilePatterns(List<String> extraPatterns) {
    _compiled = _compilePatterns(extraPatterns);
    _log.info('MessageRedactor patterns recompiled (${extraPatterns.length} extra patterns)');
  }

  static List<({RegExp pattern, bool isPem})> _compilePatterns(List<String> extra) {
    final result = <({RegExp pattern, bool isPem})>[];

    // Built-in patterns (order: PEM first for multi-line, then specific, then generic).
    const builtins = <({String pattern, bool isPem, bool caseSensitive, bool dotAll})>[
      // PEM blocks (multi-line)
      (pattern: r'-----BEGIN [^-]+-----.*?-----END [^-]+-----', isPem: true, caseSensitive: true, dotAll: true),
      // Truncated or malformed PEM blocks remain sensitive without a closing delimiter.
      (pattern: r'-----BEGIN [^-]+-----.*$', isPem: true, caseSensitive: true, dotAll: true),
      // Stripe-style API keys
      (pattern: r'(?:sk|pk)_(?:live|test)_\w+', isPem: false, caseSensitive: true, dotAll: false),
      // Anthropic API keys
      (pattern: r'sk-ant-[a-zA-Z0-9_-]+', isPem: false, caseSensitive: true, dotAll: false),
      // JWT-shaped tokens, matched whole so no payload segment survives
      (
        pattern: r'eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]{4,}',
        isPem: false,
        caseSensitive: true,
        dotAll: false,
      ),
      // AWS access key ID
      (pattern: r'AKIA[0-9A-Z]{16}', isPem: false, caseSensitive: true, dotAll: false),
      // Bearer tokens
      (pattern: r'Bearer\s+[A-Za-z0-9\-._~+/]+=*', isPem: false, caseSensitive: true, dotAll: false),
    ];

    for (final b in builtins) {
      result.add((pattern: RegExp(b.pattern, caseSensitive: b.caseSensitive, dotAll: b.dotAll), isPem: b.isPem));
    }

    // Extra patterns from config.
    for (final raw in extra) {
      try {
        result.add((pattern: RegExp(raw), isPem: false));
      } on FormatException catch (e) {
        _log.warning('Invalid extra redact pattern "$raw": $e');
      }
    }

    return result;
  }

  /// Redacts sensitive content from [input].
  ///
  /// Never throws. On internal error, returns [input] unchanged.
  String redact(String input) {
    if (input.isEmpty) return input;
    try {
      var result = input.replaceAllMapped(_authorizationHeader, (match) => '${match.group(1)}***');
      result = result.replaceAllMapped(
        _equalsAssignment,
        (match) => isSecretKey(match.group(2)!)
            ? _redactAssignmentValue(
                '${match.group(1)}${match.group(2)}${match.group(3)}',
                match.group(4)!,
                preserveClosingDelimiter: _isStructuralPrefix(result, match.start, null, match.group(1)),
              )
            : match.group(0)!,
      );
      result = _redactQuotedAssignments(result);
      result = result.replaceAllMapped(
        _colonAssignment,
        (match) => isSecretKey(match.group(3)!)
            ? _redactAssignmentValue(
                '${match.group(1) ?? match.group(2)}${match.group(3)}${match.group(4)}',
                match.group(5)!,
                preserveClosingDelimiter: _isStructuralPrefix(result, match.start, match.group(1), match.group(2)),
              )
            : match.group(0)!,
      );
      for (final entry in _compiled) {
        if (entry.isPem) {
          result = result.replaceAll(entry.pattern, '[REDACTED]');
        } else {
          result = result.replaceAllMapped(entry.pattern, _proportionalReveal);
        }
      }
      return result;
    } catch (e) {
      _log.warning('Redaction failed, returning original text', e);
      return input;
    }
  }

  static String _proportionalReveal(Match match) {
    final value = match.group(0)!;
    final keep = min(value.length ~/ 2, 8);
    if (keep <= 0) return '***';
    return '${value.substring(0, keep)}***';
  }

  static bool _isStructuralPrefix(String input, int matchStart, String? linePrefix, String? separator) {
    if ((linePrefix?.trim().isNotEmpty ?? false) || const {'{', '[', ','}.contains(separator)) return true;
    var index = matchStart - 1;
    while (index >= 0 && (input.codeUnitAt(index) == 0x20 || input.codeUnitAt(index) == 0x09)) {
      index--;
    }
    return index >= 0 && const {0x7b, 0x5b, 0x2c}.contains(input.codeUnitAt(index));
  }

  static String _redactAssignmentValue(String prefix, String value, {bool preserveClosingDelimiter = false}) {
    final closing = preserveClosingDelimiter ? _closingDelimiters.firstMatch(value) : null;
    final body = closing == null ? value : value.substring(0, closing.start);
    final punctuation = _terminalPunctuation.firstMatch(body);
    return '$prefix***${punctuation?.group(0) ?? ''}${closing?.group(0) ?? ''}';
  }

  static String _redactQuotedAssignments(String input) {
    final output = StringBuffer();
    var cursor = 0;
    for (final match in _quotedColonAssignment.allMatches(input)) {
      if (match.start < cursor || !isSecretKey(match.group(2)!)) continue;
      final valueEnd = _jsonValueEnd(input, match.end);
      if (valueEnd == null) continue;
      output
        ..write(input.substring(cursor, match.end))
        ..write('"***"');
      cursor = valueEnd;
    }
    if (cursor == 0) return input;
    output.write(input.substring(cursor));
    return output.toString();
  }

  static int? _jsonValueEnd(String input, int start) {
    if (start >= input.length) return null;
    final first = input.codeUnitAt(start);
    if (first == 0x22) {
      var escaped = false;
      for (var i = start + 1; i < input.length; i++) {
        final code = input.codeUnitAt(i);
        if (escaped) {
          escaped = false;
        } else if (code == 0x5c) {
          escaped = true;
        } else if (code == 0x22) {
          return i + 1;
        }
      }
      return input.length;
    }
    if (first == 0x7b || first == 0x5b) {
      final stack = <int>[first];
      var quoted = false;
      var escaped = false;
      for (var i = start + 1; i < input.length; i++) {
        final code = input.codeUnitAt(i);
        if (quoted) {
          if (escaped) {
            escaped = false;
          } else if (code == 0x5c) {
            escaped = true;
          } else if (code == 0x22) {
            quoted = false;
          }
          continue;
        }
        if (code == 0x22) {
          quoted = true;
        } else if (code == 0x7b || code == 0x5b) {
          stack.add(code);
        } else if (code == 0x7d || code == 0x5d) {
          final expected = code == 0x7d ? 0x7b : 0x5b;
          if (stack.last != expected) return input.length;
          stack.removeLast();
          if (stack.isEmpty) return i + 1;
        }
      }
      return input.length;
    }
    return _jsonScalar.matchAsPrefix(input, start)?.end;
  }

  static List<String> _keyWords(Object key) {
    final separated = key
        .toString()
        .trim()
        .replaceAllMapped(RegExp(r'([A-Z]+)([A-Z][a-z])'), (match) => '${match.group(1)}_${match.group(2)}')
        .replaceAllMapped(RegExp(r'([a-z0-9])([A-Z])'), (match) => '${match.group(1)}_${match.group(2)}');
    return separated.toLowerCase().split(RegExp('[^a-z0-9]+')).where((word) => word.isNotEmpty).toList(growable: false);
  }
}
