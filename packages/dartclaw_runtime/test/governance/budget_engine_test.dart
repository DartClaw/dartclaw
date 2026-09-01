import 'package:dartclaw_runtime/src/governance/budget_engine.dart';
import 'package:test/test.dart';

void main() {
  // ---------------------------------------------------------------------------
  // Threshold comparison and percentage — proved once, for every scope
  // ---------------------------------------------------------------------------

  group('BudgetEngine.evaluate — thresholds', () {
    test('below the threshold → under, with no warn-once write', () async {
      final scope = _StubBudgetScope(limit: 1000, tokensUsed: 799);

      final result = await const BudgetEngine().evaluate(scope);

      expect(result.outcome, BudgetOutcome.under);
      expect(result.tokensUsed, 799);
      expect(result.limit, 1000);
      expect(result.percentage, 80); // 79.9% rounds up but stays under the threshold
      expect(result.warningIsNew, isFalse);
      expect(scope.marks, 0);
    });

    test('exactly at the threshold → warning, and the first one is new', () async {
      final scope = _StubBudgetScope(limit: 1000, tokensUsed: 800);

      final result = await const BudgetEngine().evaluate(scope);

      expect(result.outcome, BudgetOutcome.warning);
      expect(result.warningIsNew, isTrue);
      expect(result.percentage, 80);
      expect(scope.marks, 1);
      expect(scope.reads, 1);
    });

    test('a non-default threshold is honoured (60% of a 50%-threshold scope warns)', () async {
      final scope = _StubBudgetScope(limit: 100, tokensUsed: 60, warningThreshold: 0.5);

      final result = await const BudgetEngine().evaluate(scope);

      expect(result.outcome, BudgetOutcome.warning);
      expect(result.percentage, 60);
      expect(result.ratio, closeTo(0.6, 1e-9));
    });

    test('a warning already posted for the window is not new and writes no second marker', () async {
      final scope = _StubBudgetScope(limit: 1000, tokensUsed: 900, warningPosted: true);

      final result = await const BudgetEngine().evaluate(scope);

      expect(result.outcome, BudgetOutcome.warning);
      expect(result.warningIsNew, isFalse);
      expect(scope.marks, 0);
    });

    test('at the limit → exceeded', () async {
      final scope = _StubBudgetScope(limit: 1000, tokensUsed: 1000);

      final result = await const BudgetEngine().evaluate(scope);

      expect(result.outcome, BudgetOutcome.exceeded);
      expect(result.percentage, 100);
      // An exceeded outcome is always reached through a consumption reading —
      // TaskBudgetPolicy takes the artifact's turn count off that read.
      expect(scope.reads, 1);
    });

    test('over the limit → exceeded', () async {
      final scope = _StubBudgetScope(limit: 100, tokensUsed: 120);

      final result = await const BudgetEngine().evaluate(scope);

      expect(result.outcome, BudgetOutcome.exceeded);
      expect(result.percentage, 120);
    });
  });

  // ---------------------------------------------------------------------------
  // Warn-once gating at the limit — the one axis the two scopes diverge on
  // ---------------------------------------------------------------------------

  group('BudgetEngine.evaluate — warn-once at the limit', () {
    test('a scope whose limit consumes the warning burns it on a straight-to-100% breach', () async {
      final scope = _StubBudgetScope(limit: 1000, tokensUsed: 1000, limitConsumesWarning: true);

      final result = await const BudgetEngine().evaluate(scope);

      expect(result.outcome, BudgetOutcome.exceeded);
      expect(result.warningIsNew, isTrue);
      expect(scope.marks, 1);
      expect(scope.reads, 1);
    });

    test('a scope whose limit does not consume the warning leaves the marker unwritten', () async {
      final scope = _StubBudgetScope(limit: 1000, tokensUsed: 1000, limitConsumesWarning: false);

      final result = await const BudgetEngine().evaluate(scope);

      expect(result.outcome, BudgetOutcome.exceeded);
      expect(result.warningIsNew, isFalse);
      expect(scope.marks, 0);
    });
  });

  // ---------------------------------------------------------------------------
  // Short circuits and error posture
  // ---------------------------------------------------------------------------

  group('BudgetEngine.evaluate — short circuits', () {
    test('a null limit returns under without reading consumption', () async {
      final scope = _StubBudgetScope(limit: null, tokensUsed: 5000);

      final result = await const BudgetEngine().evaluate(scope);

      expect(result.outcome, BudgetOutcome.under);
      expect(result.limit, 0);
      expect(result.tokensUsed, 0);
      expect(scope.reads, 0);
    });

    test('a zero limit returns under without reading consumption', () async {
      final scope = _StubBudgetScope(limit: 0, tokensUsed: 5000);

      final result = await const BudgetEngine().evaluate(scope);

      expect(result.outcome, BudgetOutcome.under);
      expect(scope.reads, 0);
    });

    test('a scope with no consumption reading returns under but keeps its limit', () async {
      final scope = _StubBudgetScope(limit: 100, tokensUsed: null);

      final result = await const BudgetEngine().evaluate(scope);

      expect(result.outcome, BudgetOutcome.under);
      expect(result.limit, 100);
      expect(result.tokensUsed, 0);
      expect(scope.reads, 1);
    });

    test('a failing read propagates — the engine owns no error posture', () async {
      final scope = _StubBudgetScope(limit: 100, tokensUsed: 50, readThrows: true);

      await expectLater(const BudgetEngine().evaluate(scope), throwsA(isA<StateError>()));
    });
  });
}

/// A [BudgetScope] whose numbers are supplied directly, recording how often the
/// engine reads consumption and writes the warn-once marker.
final class _StubBudgetScope implements BudgetScope {
  new({
    required this.limit,
    required this.tokensUsed,
    this.warningThreshold = 0.8,
    this.limitConsumesWarning = true,
    this.warningPosted = false,
    this.readThrows = false,
  });

  @override
  final int? limit;

  final int? tokensUsed;
  final bool warningPosted;
  final bool readThrows;

  @override
  final double warningThreshold;

  @override
  final bool limitConsumesWarning;

  int reads = 0;
  int marks = 0;

  @override
  Future<BudgetConsumption?> readConsumption() async {
    reads++;
    if (readThrows) throw StateError('consumption store unavailable');
    final used = tokensUsed;
    if (used == null) return null;
    return BudgetConsumption(tokensUsed: used, warningPosted: warningPosted);
  }

  @override
  Future<void> markWarningPosted() async => marks++;
}
