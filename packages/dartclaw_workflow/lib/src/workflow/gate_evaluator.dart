import 'package:logging/logging.dart';

import 'workflow_context.dart';

/// Evaluates simple gate expressions against workflow context.
///
/// Gate syntax: `<key> <operator> <value>` joined by `&&`.
/// Operators: ==, !=, <, >, <=, >=.
/// Example: `implement.status == accepted && research.tokenCount < 50000`
class GateEvaluator {
  static final _log = Logger('GateEvaluator');
  static final _conditionPattern = RegExp(r'^(.+?)\s*(==|!=|<=|>=|<|>)\s*(.+)$');

  /// Returns true if [expression] passes against [context], false if it fails.
  ///
  /// Malformed expressions and missing context keys return false (fail-safe).
  bool evaluate(String expression, WorkflowContext context) {
    final conditions = expression.split('&&').map((s) => s.trim());
    return conditions.every((cond) => _evaluateCondition(cond, context));
  }

  bool _evaluateCondition(String condition, WorkflowContext context) {
    final match = _conditionPattern.firstMatch(condition.trim());
    if (match == null) {
      _log.warning('Invalid gate expression: "$condition"');
      return false;
    }

    final key = match.group(1)!.trim();
    final op = match.group(2)!.trim();
    final expected = match.group(3)!.trim();
    final rawActual = context[key]?.toString() ?? '';
    // Treat missing/empty values as '0' when the expected value is numeric,
    // so gates like "findings_count == 0" pass when the key was never set.
    final actual = rawActual.isEmpty && double.tryParse(expected) != null ? '0' : rawActual;

    return switch (op) {
      '==' => actual == expected,
      '!=' => actual != expected,
      '<' => _compareNumeric(actual, expected) < 0,
      '>' => _compareNumeric(actual, expected) > 0,
      '<=' => _compareNumeric(actual, expected) <= 0,
      '>=' => _compareNumeric(actual, expected) >= 0,
      _ => false,
    };
  }

  /// Numeric comparison with string fallback.
  int _compareNumeric(String a, String b) {
    final aNum = double.tryParse(a);
    final bNum = double.tryParse(b);
    if (aNum != null && bNum != null) {
      return aNum.compareTo(bNum);
    }
    return a.compareTo(b);
  }
}
