/// Configuration for the memory subsystem.
class MemoryConfig {
  final int maxBytes;
  final bool pruningEnabled;
  final int archiveAfterDays;
  final String pruningSchedule;

  const MemoryConfig({
    this.maxBytes = 32 * 1024,
    this.pruningEnabled = true,
    this.archiveAfterDays = 90,
    this.pruningSchedule = '0 3 * * *',
  });

  /// Default configuration.
  const MemoryConfig.defaults() : this();
}
