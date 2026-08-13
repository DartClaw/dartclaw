/// Host-owned operation exposed through scheduling's read and run-now boundary.
final class SystemAction {
  const SystemAction({required this.id, required this.description, required this.run, this.isBlocked});

  final String id;
  final String description;
  final Future<void> Function() run;

  /// Returns whether durable action state currently forbids admission.
  final bool Function()? isBlocked;
}

/// Read-only scheduling entry shared by configured jobs and system actions.
final class SchedulingEntry {
  const SchedulingEntry({required this.id, required this.kind, required this.runnable, required this.mutable});

  final String id;
  final SchedulingEntryKind kind;
  final bool runnable;
  final bool mutable;
}

enum SchedulingEntryKind { job, systemAction }

/// A configured job attempted to claim an immutable system-action ID.
final class ReservedSystemActionIdException implements Exception {
  const ReservedSystemActionIdException(this.ids);

  final Set<String> ids;

  @override
  String toString() => 'Configured job IDs collide with reserved system actions: ${ids.join(', ')}';
}

/// Rejects a complete configured-job set that intersects [reservedIds].
void validateReservedSystemActionIds(Iterable<Object?> configuredIds, Iterable<String> reservedIds) {
  final reserved = reservedIds.toSet();
  final collisions = configuredIds.whereType<String>().where(reserved.contains).toSet();
  if (collisions.isNotEmpty) throw ReservedSystemActionIdException(collisions);
}
