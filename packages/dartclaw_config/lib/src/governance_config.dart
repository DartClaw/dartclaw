part 'budget_config.dart';
part 'crowd_coding_config.dart';
part 'loop_detection_config.dart';
part 'rate_limits_config.dart';
part 'turn_progress_config.dart';

/// Top-level governance configuration.
///
/// Controls rate limiting, budget enforcement, loop detection, queue strategy,
/// crowd coding defaults, and turn progress monitoring.
class GovernanceConfig {
  /// Sender IDs that are exempt from all per-sender rate limits.
  ///
  /// An empty list means ALL senders are treated as admins (no per-sender
  /// restrictions). This is the default, suitable for single-user deployments.
  final List<String> adminSenders;

  /// Rate limit configuration (per-sender and global).
  final RateLimitsConfig rateLimits;

  /// Token budget configuration. Enforced in S09.
  final BudgetConfig budget;

  /// Loop detection configuration. Enforced in S10.
  final LoopDetectionConfig loopDetection;

  /// Queue drain strategy for per-session message queues.
  final QueueStrategy queueStrategy;

  /// Crowd coding model/effort defaults for channel-routed group sessions.
  final CrowdCodingConfig crowdCoding;

  /// Progress-aware turn stall detection config.
  final TurnProgressConfig turnProgress;

  const GovernanceConfig({
    this.adminSenders = const [],
    this.rateLimits = const RateLimitsConfig.defaults(),
    this.budget = const BudgetConfig.defaults(),
    this.loopDetection = const LoopDetectionConfig.defaults(),
    this.queueStrategy = QueueStrategy.fifo,
    this.crowdCoding = const CrowdCodingConfig.defaults(),
    this.turnProgress = const TurnProgressConfig.defaults(),
  });

  /// Default governance config — all features disabled, all senders are admins.
  const GovernanceConfig.defaults() : this();

  /// Returns `true` if [senderId] is an admin.
  ///
  /// When [adminSenders] is empty, all senders are considered admins (suitable
  /// for single-user deployments). When non-empty, only listed IDs are admins.
  bool isAdmin(String senderId) {
    if (adminSenders.isEmpty) return true;
    return adminSenders.contains(senderId);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GovernanceConfig &&
          _listEquals(adminSenders, other.adminSenders) &&
          rateLimits == other.rateLimits &&
          budget == other.budget &&
          loopDetection == other.loopDetection &&
          queueStrategy == other.queueStrategy &&
          crowdCoding == other.crowdCoding &&
          turnProgress == other.turnProgress;

  @override
  int get hashCode => Object.hash(
    Object.hashAll(adminSenders),
    rateLimits,
    budget,
    loopDetection,
    queueStrategy,
    crowdCoding,
    turnProgress,
  );

  @override
  String toString() =>
      'GovernanceConfig(adminSenders: $adminSenders, rateLimits: $rateLimits, '
      'budget: $budget, loopDetection: $loopDetection, queueStrategy: $queueStrategy, '
      'crowdCoding: $crowdCoding, turnProgress: $turnProgress)';

  static bool _listEquals(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
