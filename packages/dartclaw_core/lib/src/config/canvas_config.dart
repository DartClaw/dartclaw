/// Canvas configuration for the shareable workshop canvas feature.
class CanvasShareConfig {
  final String defaultPermission;
  final int defaultTtlMinutes;
  final int maxConnections;

  /// Reserved for future use: when true, agent auto-posts share link to channel
  /// on first canvas creation. Currently parsed but has no runtime effect.
  final bool autoShare;
  final bool showQr;

  const CanvasShareConfig({
    this.defaultPermission = 'interact',
    this.defaultTtlMinutes = 480,
    this.maxConnections = 50,
    this.autoShare = true,
    this.showQr = true,
  });

  const CanvasShareConfig.defaults() : this();

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CanvasShareConfig &&
          defaultPermission == other.defaultPermission &&
          defaultTtlMinutes == other.defaultTtlMinutes &&
          maxConnections == other.maxConnections &&
          autoShare == other.autoShare &&
          showQr == other.showQr;

  @override
  int get hashCode => Object.hash(defaultPermission, defaultTtlMinutes, maxConnections, autoShare, showQr);

  @override
  String toString() =>
      'CanvasShareConfig(defaultPermission: $defaultPermission, defaultTtlMinutes: $defaultTtlMinutes, '
      'maxConnections: $maxConnections, autoShare: $autoShare, showQr: $showQr)';
}

class CanvasWorkshopConfig {
  final bool taskBoard;
  final bool showContributorStats;
  final bool showBudgetBar;

  const CanvasWorkshopConfig({
    this.taskBoard = true,
    this.showContributorStats = true,
    this.showBudgetBar = true,
  });

  const CanvasWorkshopConfig.defaults() : this();

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CanvasWorkshopConfig &&
          taskBoard == other.taskBoard &&
          showContributorStats == other.showContributorStats &&
          showBudgetBar == other.showBudgetBar;

  @override
  int get hashCode => Object.hash(taskBoard, showContributorStats, showBudgetBar);

  @override
  String toString() =>
      'CanvasWorkshopConfig(taskBoard: $taskBoard, showContributorStats: $showContributorStats, '
      'showBudgetBar: $showBudgetBar)';
}

class CanvasConfig {
  final bool enabled;
  final CanvasShareConfig share;
  final CanvasWorkshopConfig workshopMode;

  const CanvasConfig({
    this.enabled = true,
    this.share = const CanvasShareConfig.defaults(),
    this.workshopMode = const CanvasWorkshopConfig.defaults(),
  });

  const CanvasConfig.defaults() : this();

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CanvasConfig && enabled == other.enabled && share == other.share && workshopMode == other.workshopMode;

  @override
  int get hashCode => Object.hash(enabled, share, workshopMode);

  @override
  String toString() => 'CanvasConfig(enabled: $enabled, share: $share, workshopMode: $workshopMode)';
}
