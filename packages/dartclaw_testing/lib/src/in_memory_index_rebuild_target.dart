import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'in_memory_full_text_index.dart';

/// In-memory rebuild target for tests that exercise reconciliation without SQL.
final class InMemoryIndexRebuildTarget implements IndexRebuildTarget {
  new({InMemoryFullTextIndex? index}) : index = index ?? InMemoryFullTextIndex();

  final InMemoryFullTextIndex index;

  @override
  Future<bool> isPresent() async => true;

  @override
  Future<T> validateLive<T>(Future<T> Function(FullTextIndex index) body) => body(index);

  @override
  Future<T> rebuild<T>({
    required Future<T> Function(FullTextIndex index, Future<void> Function() populated) populateAndValidate,
    required Future<void> Function(IndexReconcileTransition transition) transition,
  }) async {
    await transition(IndexReconcileTransition.siblingCreated);
    final result = await populateAndValidate(index, () => transition(IndexReconcileTransition.populated));
    await transition(IndexReconcileTransition.validated);
    await transition(IndexReconcileTransition.beforeClose);
    await transition(IndexReconcileTransition.closed);
    await transition(IndexReconcileTransition.beforeSwap);
    await transition(IndexReconcileTransition.swapped);
    return result;
  }
}
