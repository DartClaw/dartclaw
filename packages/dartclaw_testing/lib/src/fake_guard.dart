import 'dart:async';

import 'package:dartclaw_security/dartclaw_security.dart';

/// Configurable [Guard] fake with evaluation tracking.
class FakeGuard extends Guard {
  final FutureOr<GuardVerdict> Function(GuardContext)? _evaluator;
  final GuardVerdict? _fixedVerdict;

  /// Creates a fake guard with either a fixed [verdict] or dynamic [evaluator].
  FakeGuard({
    this.name = 'fake',
    this.category = 'test',
    GuardVerdict? verdict,
    FutureOr<GuardVerdict> Function(GuardContext)? evaluator,
  }) : _fixedVerdict = verdict,
       _evaluator = evaluator;

  /// Creates a fake guard that always passes.
  FakeGuard.pass({this.name = 'fake', this.category = 'test'}) : _fixedVerdict = GuardVerdict.pass(), _evaluator = null;

  /// Creates a fake guard that always warns with [message].
  FakeGuard.warn(String message, {this.name = 'fake', this.category = 'test'})
    : _fixedVerdict = GuardVerdict.warn(message),
      _evaluator = null;

  /// Creates a fake guard that always blocks with [message].
  FakeGuard.block(String message, {this.name = 'fake', this.category = 'test'})
    : _fixedVerdict = GuardVerdict.block(message),
      _evaluator = null;

  @override
  final String name;

  @override
  final String category;

  /// Number of evaluations performed.
  int evaluationCount = 0;

  /// Captured guard contexts in evaluation order.
  final List<GuardContext> evaluatedContexts = [];

  /// The most recent guard context, or null when never evaluated.
  GuardContext? get lastContext => evaluatedContexts.isEmpty ? null : evaluatedContexts.last;

  @override
  Future<GuardVerdict> evaluate(GuardContext context) async {
    evaluationCount += 1;
    evaluatedContexts.add(context);
    final evaluator = _evaluator;
    if (evaluator != null) {
      return await evaluator(context);
    }
    return _fixedVerdict ?? GuardVerdict.pass();
  }
}
