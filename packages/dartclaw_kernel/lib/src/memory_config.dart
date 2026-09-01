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

  /// Whether the built-in scheduled memory curation job is enabled.
  final bool curationEnabled;

  /// Cron schedule for the built-in memory curation job.
  final String curationSchedule;

  /// Creates a [MemoryConfig] value.
  factory({
    int maxBytes = 32 * 1024,
    bool pruningEnabled = true,
    int archiveAfterDays = 90,
    String pruningSchedule = '0 3 * * *',
    bool journalEnabled = false,
    String journalSchedule = '0 22 * * *',
    bool curationEnabled = false,
    String curationSchedule = '0 3 * * *',
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
      curationEnabled: curationEnabled,
      curationSchedule: curationSchedule,
    );
  }

  /// Default configuration.
  const new defaults()
    : maxBytes = 32 * 1024,
      pruningEnabled = true,
      archiveAfterDays = 90,
      pruningSchedule = '0 3 * * *',
      journalEnabled = false,
      journalSchedule = '0 22 * * *',
      curationEnabled = false,
      curationSchedule = '0 3 * * *';

  const new _({
    required this.maxBytes,
    required this.pruningEnabled,
    required this.archiveAfterDays,
    required this.pruningSchedule,
    required this.journalEnabled,
    required this.journalSchedule,
    required this.curationEnabled,
    required this.curationSchedule,
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
          journalSchedule == other.journalSchedule &&
          curationEnabled == other.curationEnabled &&
          curationSchedule == other.curationSchedule;

  @override
  int get hashCode => Object.hash(
    maxBytes,
    pruningEnabled,
    archiveAfterDays,
    pruningSchedule,
    journalEnabled,
    journalSchedule,
    curationEnabled,
    curationSchedule,
  );
}

void _requirePositive(int value, String field) {
  if (value <= 0) throw ArgumentError.value(value, field, 'must be a positive integer');
}
