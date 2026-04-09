import 'dart:math';

import 'package:logging/logging.dart';

/// Regex-based redaction for outbound text across all output paths.
///
/// Built-in patterns cover common secret types (API keys, AWS credentials,
/// Bearer tokens, PEM blocks, generic secrets). Custom patterns can be added
/// via [extraPatterns].
///
/// Redaction uses proportional reveal: `min(matchLength / 2, 8)` characters
/// preserved + `***`. PEM blocks are fully replaced with `[REDACTED]`.
///
/// The [redact] method never throws — errors are caught internally and the
/// original text is returned unchanged.
class MessageRedactor {
  static final _log = Logger('MessageRedactor');

  List<({RegExp pattern, bool isPem})> _compiled;

  /// Creates a redactor with built-in patterns plus optional [extraPatterns].
  ///
  /// Invalid regexes in [extraPatterns] are logged as warnings and skipped.
  MessageRedactor({List<String> extraPatterns = const []}) : _compiled = _compilePatterns(extraPatterns);

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
      // Stripe-style API keys
      (pattern: r'(?:sk|pk)_(?:live|test)_\w+', isPem: false, caseSensitive: true, dotAll: false),
      // Anthropic API keys
      (pattern: r'sk-ant-[a-zA-Z0-9_-]+', isPem: false, caseSensitive: true, dotAll: false),
      // AWS access key ID
      (pattern: r'AKIA[0-9A-Z]{16}', isPem: false, caseSensitive: true, dotAll: false),
      // AWS secret access key
      (pattern: r'aws_secret_access_key\s*=\s*\S+', isPem: false, caseSensitive: false, dotAll: false),
      // Bearer tokens
      (pattern: r'Bearer\s+[A-Za-z0-9\-._~+/]+=*', isPem: false, caseSensitive: true, dotAll: false),
      // Generic secrets (api_key, secret, token, password = value)
      (
        pattern: r'(?:api[_-]?key|secret|token|password)\s*[:=]\s*\S+',
        isPem: false,
        caseSensitive: false,
        dotAll: false,
      ),
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
      var result = input;
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
}
