/// Access control mode for group messages across supported channels.
enum GroupAccessMode {
  /// Only explicitly listed groups may interact with the runtime.
  allowlist,

  /// Any group may interact with the runtime.
  open,

  /// Group messages are ignored entirely.
  disabled,
}

/// Retry policy for channel message delivery.
class RetryPolicy {
  /// Maximum number of delivery attempts before a message is dead-lettered.
  final int maxAttempts;

  /// Base delay before retry backoff and jitter are applied.
  final Duration baseDelay;

  /// Randomization factor applied to retry delays to reduce thundering herds.
  final double jitterFactor;

  /// Creates a retry policy for outbound channel delivery.
  const RetryPolicy({this.maxAttempts = 3, this.baseDelay = const Duration(seconds: 1), this.jitterFactor = 0.2});

  /// Parses a retry policy from YAML configuration, appending warnings to [warns].
  factory RetryPolicy.fromYaml(Map<String, dynamic> yaml, List<String> warns) {
    var maxAttempts = 3;
    final ma = yaml['max_attempts'];
    if (ma is int) {
      maxAttempts = ma;
    } else if (ma != null) {
      warns.add('Invalid type for retry_policy.max_attempts: "${ma.runtimeType}" — using default');
    }

    var baseDelayMs = 1000;
    final bd = yaml['base_delay_ms'];
    if (bd is int) {
      baseDelayMs = bd;
    } else if (bd != null) {
      warns.add('Invalid type for retry_policy.base_delay_ms: "${bd.runtimeType}" — using default');
    }

    var jitterFactor = 0.2;
    final jf = yaml['jitter_factor'];
    if (jf is num) {
      jitterFactor = jf.toDouble();
    } else if (jf != null) {
      warns.add('Invalid type for retry_policy.jitter_factor: "${jf.runtimeType}" — using default');
    }

    return RetryPolicy(
      maxAttempts: maxAttempts,
      baseDelay: Duration(milliseconds: baseDelayMs),
      jitterFactor: jitterFactor,
    );
  }
}

/// Configuration for the channel subsystem.
class ChannelConfig {
  /// Time window used to coalesce inbound messages from the same session.
  final Duration debounceWindow;

  /// Maximum queued messages allowed per session key.
  final int maxQueueDepth;

  /// Retry policy applied when a channel-specific override is absent.
  final RetryPolicy defaultRetryPolicy;

  /// Raw channel-specific config maps keyed by channel name.
  final Map<String, Map<String, dynamic>> channelConfigs;

  /// Creates channel subsystem configuration.
  const ChannelConfig({
    this.debounceWindow = const Duration(milliseconds: 1000),
    this.maxQueueDepth = 100,
    this.defaultRetryPolicy = const RetryPolicy(),
    this.channelConfigs = const {},
  });

  /// Creates the default channel configuration used when no YAML overrides exist.
  const ChannelConfig.defaults() : this();

  /// Parses channel configuration from YAML, appending warnings to [warns].
  factory ChannelConfig.fromYaml(Map<String, dynamic> yaml, List<String> warns) {
    var debounceMs = 1000;
    final dw = yaml['debounce_window_ms'];
    if (dw is int) {
      debounceMs = dw;
    } else if (dw != null) {
      warns.add('Invalid type for channels.debounce_window_ms: "${dw.runtimeType}" — using default');
    }

    var maxQueueDepth = 100;
    final mqd = yaml['max_queue_depth'];
    if (mqd is int) {
      maxQueueDepth = mqd;
    } else if (mqd != null) {
      warns.add('Invalid type for channels.max_queue_depth: "${mqd.runtimeType}" — using default');
    }

    var retryPolicy = const RetryPolicy();
    final rpRaw = yaml['retry_policy'];
    if (rpRaw is Map) {
      retryPolicy = RetryPolicy.fromYaml(Map<String, dynamic>.from(rpRaw), warns);
    } else if (rpRaw != null) {
      warns.add('Invalid type for channels.retry_policy: "${rpRaw.runtimeType}" — using default');
    }

    // Channel configs: any Map-valued key that isn't a known config key
    // is treated as a channel definition (e.g. whatsapp, signal).
    const knownKeys = {'debounce_window_ms', 'max_queue_depth', 'retry_policy'};
    final channelConfigs = <String, Map<String, dynamic>>{};
    for (final entry in yaml.entries) {
      final key = entry.key.toString();
      if (knownKeys.contains(key)) continue;
      if (entry.value is Map) {
        channelConfigs[key] = Map<String, dynamic>.from(entry.value as Map);
      } else {
        warns.add('Invalid channel config for "$key": "${entry.value.runtimeType}" — skipping');
      }
    }

    return ChannelConfig(
      debounceWindow: Duration(milliseconds: debounceMs),
      maxQueueDepth: maxQueueDepth,
      defaultRetryPolicy: retryPolicy,
      channelConfigs: channelConfigs,
    );
  }
}
