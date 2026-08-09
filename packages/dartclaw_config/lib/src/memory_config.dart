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
  const MemoryConfig({
    this.maxBytes = 32 * 1024,
    this.pruningEnabled = true,
    this.archiveAfterDays = 90,
    this.pruningSchedule = '0 3 * * *',
    this.journalEnabled = false,
    this.journalSchedule = '0 22 * * *',
  });

  /// Default configuration.
  const MemoryConfig.defaults() : this();

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
