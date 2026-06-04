/// Knowledge automation configuration.
class KnowledgeConfig {
  /// Inbox drop-folder processing configuration.
  final KnowledgeInboxConfig inbox;

  /// Wiki lint job configuration.
  final KnowledgeWikiLintConfig wikiLint;

  /// Creates a [KnowledgeConfig] value.
  const KnowledgeConfig({
    this.inbox = const KnowledgeInboxConfig.defaults(),
    this.wikiLint = const KnowledgeWikiLintConfig.defaults(),
  });

  /// Creates a [KnowledgeConfig.defaults] value.
  const KnowledgeConfig.defaults() : this();

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is KnowledgeConfig && inbox == other.inbox && wikiLint == other.wikiLint;

  @override
  int get hashCode => Object.hash(inbox, wikiLint);
}

/// Filesystem knowledge inbox scheduler settings.
class KnowledgeInboxConfig {
  /// Whether scheduled inbox processing is enabled.
  final bool enabled;

  /// Interval between inbox scans.
  final int intervalMinutes;

  /// Maximum accepted source file size.
  final int maxBytes;

  /// Processing retry attempts before quarantine.
  final int retryAttempts;

  /// Days to retain successfully processed source files.
  final int processedRetentionDays;

  /// Scheduled report delivery mode.
  final String deliveryMode;

  /// Creates a [KnowledgeInboxConfig] value.
  const KnowledgeInboxConfig({
    required this.enabled,
    required this.intervalMinutes,
    required this.maxBytes,
    required this.retryAttempts,
    required this.processedRetentionDays,
    required this.deliveryMode,
  });

  /// Creates a [KnowledgeInboxConfig.defaults] value.
  const KnowledgeInboxConfig.defaults()
    : enabled = false,
      intervalMinutes = 5,
      maxBytes = 1024 * 1024,
      retryAttempts = 2,
      processedRetentionDays = 30,
      deliveryMode = 'announce';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is KnowledgeInboxConfig &&
          enabled == other.enabled &&
          intervalMinutes == other.intervalMinutes &&
          maxBytes == other.maxBytes &&
          retryAttempts == other.retryAttempts &&
          processedRetentionDays == other.processedRetentionDays &&
          deliveryMode == other.deliveryMode;

  @override
  int get hashCode =>
      Object.hash(enabled, intervalMinutes, maxBytes, retryAttempts, processedRetentionDays, deliveryMode);
}

/// Wiki lint scheduler settings.
class KnowledgeWikiLintConfig {
  /// Whether scheduled wiki linting is enabled.
  final bool enabled;

  /// Interval between wiki lint runs.
  final int intervalMinutes;

  /// Scheduled report delivery mode.
  final String deliveryMode;

  /// Creates a [KnowledgeWikiLintConfig] value.
  const KnowledgeWikiLintConfig({required this.enabled, required this.intervalMinutes, required this.deliveryMode});

  /// Creates a [KnowledgeWikiLintConfig.defaults] value.
  const KnowledgeWikiLintConfig.defaults() : enabled = false, intervalMinutes = 60, deliveryMode = 'announce';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is KnowledgeWikiLintConfig &&
          enabled == other.enabled &&
          intervalMinutes == other.intervalMinutes &&
          deliveryMode == other.deliveryMode;

  @override
  int get hashCode => Object.hash(enabled, intervalMinutes, deliveryMode);
}
