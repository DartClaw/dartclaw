import 'package:logging/logging.dart';

import 'workflow_context.dart';
import 'workflow_context_resolver.dart';

/// Evaluates simple gate expressions against workflow context.
///
/// Gate syntax: `<key> <operator> <value>` or `<key> isEmpty` leaves joined
/// as `<a> [&& <b>]* [|| <c> [&& <d>]*]*`; `&&` binds tighter than `||`.
/// Parentheses, NOT, and deeper nesting are not supported.
class GateEvaluator {
  static final _log = Logger('GateEvaluator');

  /// The binary condition production: `<key> <operator> <value>`.
  ///
  /// Group 1 is the context key (bare or dotted), group 2 the operator, group 3
  /// the expected value. Declared once here and read by the validator, so a
  /// condition the validator accepts is always one this evaluator can evaluate.
  static final binaryConditionPattern = RegExp(r'^([\w-]+(?:\.[\w-]+)*)\s*(==|!=|<=|>=|<|>)\s*([^<>=!]+)$');

  /// The unary condition production: `<key> isEmpty` / `<key> isNotEmpty`.
  ///
  /// Group 1 is the context key, group 2 the operator. Companion to
  /// [binaryConditionPattern]; the two together are the whole gate grammar.
  static final unaryConditionPattern = RegExp(r'^([\w-]+(?:\.[\w-]+)*)\s+(isEmpty|isNotEmpty)$');

  /// Splits [expression] into `||`-joined groups of `&&`-joined leaf conditions.
  ///
  /// `&&` binds tighter than `||`. Leaves are trimmed but not validated – an
  /// empty or malformed leaf survives the split so callers can report it.
  static List<List<String>> conditionGroups(String expression) => expression
      .split('||')
      .map((group) => group.split('&&').map((condition) => condition.trim()).toList(growable: false))
      .toList(growable: false);

  /// Every leaf condition in [expression], flattened across `||` and `&&`.
  static Iterable<String> leafConditions(String expression) => conditionGroups(expression).expand((group) => group);

  /// Whether [condition] is a well-formed leaf of the gate grammar.
  static bool isConditionValid(String condition) =>
      binaryConditionPattern.hasMatch(condition) || unaryConditionPattern.hasMatch(condition);

  /// The context key [condition] reads, or null when [condition] is malformed.
  static String? referencedKey(String condition) =>
      (binaryConditionPattern.firstMatch(condition) ?? unaryConditionPattern.firstMatch(condition))?.group(1);

  /// Tracks keys that have already produced a "context." prefix warning,
  /// so gates evaluated on every loop iteration don't spam the log.
  final Set<String> _warnedPrefixKeys = {};

  /// Returns true if [expression] passes against [context], false if it fails.
  ///
  /// Malformed expressions and missing context keys return false (fail-safe).
  ///
  /// Throws [GateUnproducedOutputFailure] when a condition reads a key that a
  /// terminally failed step declared and never produced. That case is not
  /// fail-safe on purpose: neither answer is safe, because the gate has no
  /// value to decide on and the run must stop rather than guess.
  bool evaluate(String expression, WorkflowContext context) {
    final groups = conditionGroups(expression);
    for (final group in groups) {
      if (group.any((condition) => condition.isEmpty || !isConditionValid(condition))) {
        _log.warning('Invalid gate expression: "$expression"');
        return false;
      }
    }
    return groups.any((group) => group.every((condition) => _evaluateCondition(condition, context)));
  }

  /// The step that terminally failed leaving [key] unproduced, or null.
  ///
  /// Absence alone says nothing — a skipped step is absent too. Only the
  /// executor's record of a *failed* step's unproduced declared outputs
  /// distinguishes the two.
  static String? _stepThatFailedToProduce(WorkflowContext context, String key) {
    for (final entry in context.systemVariables.entries) {
      if (!entry.key.startsWith(unproducedKeysSystemPrefix)) continue;
      if (!entry.value.split(',').contains(key)) continue;
      return entry.key.substring(unproducedKeysSystemPrefix.length);
    }
    return null;
  }

  /// Refuses [condition] when [key] is absent because a step failed to produce
  /// it, rather than letting the absence decide the gate.
  ///
  /// Reading a stalled review's unproduced counter as a clean 0 is how a
  /// remediation gate passed on a review that never ran (live, 2026-08-28).
  static void _refuseUnproduced(WorkflowContext context, String key, String condition) {
    final failedStep = _stepThatFailedToProduce(context, key);
    if (failedStep == null) return;
    throw GateUnproducedOutputFailure(stepId: failedStep, key: key, condition: condition);
  }

  bool _evaluateCondition(String condition, WorkflowContext context) {
    final unaryMatch = unaryConditionPattern.firstMatch(condition.trim());
    if (unaryMatch != null) {
      final key = _normalizeKey(unaryMatch.group(1)!.trim());
      final op = unaryMatch.group(2)!.trim();
      final isEmpty = _isEmptyValue(resolveContextKey(context, key));
      if (isEmpty) _refuseUnproduced(context, key, condition);
      final result = op == 'isEmpty' ? isEmpty : !isEmpty;
      _log.fine('Gate condition: $key $op → result=$result');
      return result;
    }

    final match = binaryConditionPattern.firstMatch(condition.trim());
    if (match == null) {
      _log.warning('Invalid gate expression: "$condition"');
      return false;
    }

    final key = _normalizeKey(match.group(1)!.trim());
    final op = match.group(2)!.trim();
    final expected = match.group(3)!.trim();
    final rawActual = resolveContextKey(context, key)?.toString() ?? '';

    // Every branch below decides on the absence of a value, so the refusal has
    // to precede all of them — the null-literal branch returned `x == null` as
    // true for a key a failed step never produced.
    if (rawActual.isEmpty) _refuseUnproduced(context, key, condition);

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
    // non-"null" string, `!=` should be true and `==` false – matches user
    // intuition for gates like `source != synthesized` when `source` is null.
    // Nothing special to do: string comparison already handles this case.

    // Treat missing/empty values as '0' when the expected value is numeric, so
    // gates like "findings_count == 0" pass when the key was never set — which
    // is right for a step skipped by design, and wrong for one that ran and
    // failed. A step that failed without producing its declared output has that
    // fact recorded on the context's system side; reading its absence as a
    // clean 0 is how a stalled review let a remediation gate pass (live,
    // 2026-08-28), so that case refuses to coerce and fails loudly instead.
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

  String _normalizeKey(String key) {
    if (!key.startsWith('context.')) return key;
    final stripped = key.substring('context.'.length);
    if (_warnedPrefixKeys.add(stripped)) {
      _log.warning(
        'Gate expression used "context.$stripped"; gate keys are bare '
        '(unlike prompt templates). Treating as "$stripped" – please remove '
        'the "context." prefix.',
      );
    }
    return stripped;
  }

  bool _isEmptyValue(Object? value) {
    if (value == null) return true;
    if (value is String) {
      final trimmed = value.trim();
      return trimmed.isEmpty || trimmed == 'null';
    }
    if (value is Iterable) return value.isEmpty;
    if (value is Map) return value.isEmpty;
    return false;
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

/// Raised when a gate reads a declared output that a terminally failed step
/// never produced.
///
/// Distinct from a malformed or unsatisfied gate: those are answers, this is
/// the absence of one. Callers convert it into a controlled run failure —
/// catching it to return false would restore the silent pass it exists to stop.
final class GateUnproducedOutputFailure implements Exception {
  /// Step that failed leaving [key] unproduced.
  final String stepId;

  /// Declared output key the gate tried to read.
  final String key;

  /// Gate condition that read it.
  final String condition;

  const new({required this.stepId, required this.key, required this.condition});

  @override
  String toString() =>
      'Gate "$condition" reads "$key", which step "$stepId" failed to produce. '
      'Refusing to treat a failed step\'s missing output as a clean value.';
}
