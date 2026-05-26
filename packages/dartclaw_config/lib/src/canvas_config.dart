/// Canvas configuration for the shareable workshop canvas feature.
class CanvasShareConfig {
  /// defaultPermission.
  final String defaultPermission;

  /// defaultTtlMinutes.
  final int defaultTtlMinutes;

  /// maxConnections.
  final int maxConnections;

  /// Reserved for future use: when true, agent auto-posts share link to channel
  /// on first canvas creation. Currently parsed but has no runtime effect.
  final bool autoShare;

  /// showQr.
  final bool showQr;

  /// Creates a [CanvasShareConfig] value.
  const CanvasShareConfig({
    this.defaultPermission = 'interact',
    this.defaultTtlMinutes = 480,
    this.maxConnections = 50,
    this.autoShare = true,
    this.showQr = true,
  });

  /// Creates a [CanvasShareConfig.defaults] value.
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

/// class CanvasWorkshopConfig {.
class CanvasWorkshopConfig {
  /// taskBoard.
  final bool taskBoard;

  /// showContributorStats.
  final bool showContributorStats;

  /// showBudgetBar.
  final bool showBudgetBar;

  /// const CanvasWorkshopConfig({this.taskBoard = true, this.show.
  const CanvasWorkshopConfig({this.taskBoard = true, this.showContributorStats = true, this.showBudgetBar = true});

  /// Creates a [CanvasWorkshopConfig.defaults] value.
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

/// class CanvasConfig {.
class CanvasConfig {
  /// enabled.
  final bool enabled;

  /// share.
  final CanvasShareConfig share;

  /// workshopMode.
  final CanvasWorkshopConfig workshopMode;

  /// Creates a [CanvasConfig] value.
  const CanvasConfig({
    this.enabled = true,
    this.share = const CanvasShareConfig.defaults(),
    this.workshopMode = const CanvasWorkshopConfig.defaults(),
  });

  /// Creates a [CanvasConfig.defaults] value.
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
