import 'package:logging/logging.dart';

import 'workflow_context.dart';
import 'workflow_context_resolver.dart';

/// Evaluates simple gate expressions against workflow context.
///
/// Gate syntax: `<key> <operator> <value>` leaves joined as
/// `<a> [&& <b>]* [|| <c> [&& <d>]*]*`; `&&` binds tighter than `||`.
/// Parentheses, NOT, and deeper nesting are not supported.
class GateEvaluator {
  static final _log = Logger('GateEvaluator');
  static final _conditionPattern = RegExp(r'^([\w-]+(?:\.[\w-]+)*)\s*(==|!=|<=|>=|<|>)\s*([^<>=!]+)$');

  /// Tracks keys that have already produced a "context." prefix warning,
  /// so gates evaluated on every loop iteration don't spam the log.
  final Set<String> _warnedPrefixKeys = {};

  /// Returns true if [expression] passes against [context], false if it fails.
  ///
  /// Malformed expressions and missing context keys return false (fail-safe).
  bool evaluate(String expression, WorkflowContext context) {
    final orGroups = expression.split('||').map((s) => s.trim()).toList();
    if (orGroups.any((group) => group.isEmpty)) {
      _log.warning('Invalid gate expression: "$expression"');
      return false;
    }
    for (final group in orGroups) {
      final conditions = group.split('&&').map((s) => s.trim()).toList();
      if (conditions.any((condition) => condition.isEmpty || !_conditionPattern.hasMatch(condition))) {
        _log.warning('Invalid gate expression: "$expression"');
        return false;
      }
    }
    return orGroups.any((group) {
      final conditions = group.split('&&').map((s) => s.trim());
      return conditions.every((cond) => _evaluateCondition(cond, context));
    });
  }

  bool _evaluateCondition(String condition, WorkflowContext context) {
    final match = _conditionPattern.firstMatch(condition.trim());
    if (match == null) {
      _log.warning('Invalid gate expression: "$condition"');
      return false;
    }

    var key = match.group(1)!.trim();
    // Gate keys are unprefixed; forgive a stray "context." prefix (as used in
    // prompt templates) by stripping it, and nudge the author to drop it.
    if (key.startsWith('context.')) {
      final stripped = key.substring('context.'.length);
      if (_warnedPrefixKeys.add(stripped)) {
        _log.warning(
          'Gate expression used "context.$stripped"; gate keys are bare '
          '(unlike prompt templates). Treating as "$stripped" — please remove '
          'the "context." prefix.',
        );
      }
      key = stripped;
    }
    final op = match.group(2)!.trim();
    final expected = match.group(3)!.trim();
    final rawActual = resolveContextKey(context, key)?.toString() ?? '';

    // Null-literal handling for equality: missing keys and empty values are
    // considered null; the literal string "null" also matches null. Equality
    // semantics are evaluated before the numeric-empty-→-0 fallback so that
    // `x == null` and `x != null` behave consistently regardless of whether
    // the key was ever set.
    if ((op == '==' || op == '!=') && expected == 'null') {
      final isNull = rawActual.isEmpty || rawActual == 'null';
      final result = op == '==' ? isNull : !isNull;
      _log.fine('Gate condition: $key $op null → actual="$rawActual", result=$result');
      return result;
    }
    // When the *actual* value is the literal "null" but expected is a
    // non-"null" string, `!=` should be true and `==` false — matches user
    // intuition for gates like `source != synthesized` when `source` is null.
    // Nothing special to do: string comparison already handles this case.

    // Treat missing/empty values as '0' when the expected value is numeric,
    // so gates like "findings_count == 0" pass when the key was never set.
    final actual = rawActual.isEmpty && double.tryParse(expected) != null ? '0' : rawActual;

    final result = switch (op) {
      '==' => actual == expected,
      '!=' => actual != expected,
      '<' => _evaluateNumericComparison(actual, expected, (comparison) => comparison < 0),
      '>' => _evaluateNumericComparison(actual, expected, (comparison) => comparison > 0),
      '<=' => _evaluateNumericComparison(actual, expected, (comparison) => comparison <= 0),
      '>=' => _evaluateNumericComparison(actual, expected, (comparison) => comparison >= 0),
      _ => false,
    };
    _log.fine('Gate condition: $key $op $expected → actual="$actual", result=$result');
    return result;
  }

  bool _evaluateNumericComparison(String a, String b, bool Function(int comparison) predicate) {
    final aNum = double.tryParse(a);
    final bNum = double.tryParse(b);
    if (aNum == null || bNum == null) {
      _log.warning('Invalid numeric gate comparison: "$a" vs "$b"');
      return false;
    }
    return predicate(aNum.compareTo(bNum));
  }
}
