import 'canonical_memory.dart';

/// Fixed, non-configurable memory safety ceilings.
abstract final class MemoryResourceLimits {
  /// Maximum UTF-8 bytes admitted from one canonical or wiki source.
  static const sourceBytes = 64 * 1024 * 1024;

  /// Maximum UTF-8 bytes in one dated observation document.
  static const observationPartitionBytes = 8 * 1024 * 1024;

  /// Maximum regular files inspected by one recursive request.
  static const recursiveFiles = 1000;

  /// Maximum aggregate body bytes read by one recursive request.
  static const recursiveBodyBytes = 64 * 1024 * 1024;

  /// Maximum ranked results returned by one memory search response.
  static const searchResults = 50;

  /// Aggregate observation bytes at which status emits a usage warning.
  static const observationUsageWarningBytes = 64 * 1024 * 1024;
}

/// Reports a rejected memory operation with exact resource context.
final class MemoryResourceLimitException implements Exception {
  /// Creates a limit rejection for a direct source or prospective mutation.
  const new({
    required this.role,
    required this.locator,
    required this.observedBytes,
    required this.limitBytes,
    this.currentBytes,
  });

  /// Canonical role whose resource was rejected.
  final MemoryRole role;

  /// Stable source path or locator.
  final String locator;

  /// Actual or prospective UTF-8 byte count that exceeded the limit.
  final int observedBytes;

  /// Inclusive byte ceiling.
  final int limitBytes;

  /// Byte count before the rejected mutation, when applicable.
  final int? currentBytes;

  @override
  String toString() => currentBytes == null
      ? '${role.wireName} source $locator is $observedBytes bytes; limit is $limitBytes bytes'
      : '${role.wireName} source $locator is $currentBytes bytes and would become $observedBytes bytes; '
            'limit is $limitBytes bytes';
}
