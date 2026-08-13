/// Configuration for the memory subsystem.
class MemoryConfig {
  /// maxBytes.
  final int maxBytes;

  /// pruningEnabled.
  final bool pruningEnabled;

  /// archiveAfterDays.
  final int archiveAfterDays;

  /// pruningSchedule.
  final String pruningSchedule;

  /// Whether the built-in daily memory journal is enabled.
  final bool journalEnabled;

  /// Cron schedule for the built-in daily memory journal.
  final String journalSchedule;

  /// Creates a [MemoryConfig] value.
  factory MemoryConfig({
    int maxBytes = 32 * 1024,
    bool pruningEnabled = true,
    int archiveAfterDays = 90,
    String pruningSchedule = '0 3 * * *',
    bool journalEnabled = false,
    String journalSchedule = '0 22 * * *',
  }) {
    _requirePositive(maxBytes, 'memory.max_bytes');
    _requirePositive(archiveAfterDays, 'memory.pruning.archive_after_days');
    return MemoryConfig._(
      maxBytes: maxBytes,
      pruningEnabled: pruningEnabled,
      archiveAfterDays: archiveAfterDays,
      pruningSchedule: pruningSchedule,
      journalEnabled: journalEnabled,
      journalSchedule: journalSchedule,
    );
  }

  /// Default configuration.
  const MemoryConfig.defaults()
    : maxBytes = 32 * 1024,
      pruningEnabled = true,
      archiveAfterDays = 90,
      pruningSchedule = '0 3 * * *',
      journalEnabled = false,
      journalSchedule = '0 22 * * *';

  const MemoryConfig._({
    required this.maxBytes,
    required this.pruningEnabled,
    required this.archiveAfterDays,
    required this.pruningSchedule,
    required this.journalEnabled,
    required this.journalSchedule,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MemoryConfig &&
          maxBytes == other.maxBytes &&
          pruningEnabled == other.pruningEnabled &&
          archiveAfterDays == other.archiveAfterDays &&
          pruningSchedule == other.pruningSchedule &&
          journalEnabled == other.journalEnabled &&
          journalSchedule == other.journalSchedule;

  @override
  int get hashCode =>
      Object.hash(maxBytes, pruningEnabled, archiveAfterDays, pruningSchedule, journalEnabled, journalSchedule);
}

void _requirePositive(int value, String field) {
  if (value <= 0) throw ArgumentError.value(value, field, 'must be a positive integer');
}
