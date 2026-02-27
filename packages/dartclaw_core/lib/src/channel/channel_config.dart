/// Retry policy for channel message delivery.
class RetryPolicy {
  final int maxAttempts;
  final Duration baseDelay;
  final double jitterFactor;

  const RetryPolicy({this.maxAttempts = 3, this.baseDelay = const Duration(seconds: 1), this.jitterFactor = 0.2});

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
  final Duration debounceWindow;
  final int maxQueueDepth;
  final RetryPolicy defaultRetryPolicy;
  final Map<String, Map<String, dynamic>> channelConfigs;

  const ChannelConfig({
    this.debounceWindow = const Duration(milliseconds: 1000),
    this.maxQueueDepth = 100,
    this.defaultRetryPolicy = const RetryPolicy(),
    this.channelConfigs = const {},
  });

  const ChannelConfig.defaults() : this();

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

    final channelConfigs = <String, Map<String, dynamic>>{};
    final ccRaw = yaml['channels'];
    if (ccRaw is Map) {
      for (final entry in ccRaw.entries) {
        final key = entry.key.toString();
        if (entry.value is Map) {
          channelConfigs[key] = Map<String, dynamic>.from(entry.value as Map);
        } else {
          warns.add('Invalid channel config for "$key": "${entry.value.runtimeType}" — skipping');
        }
      }
    } else if (ccRaw != null) {
      warns.add('Invalid type for channels.channels: "${ccRaw.runtimeType}" — ignoring');
    }

    return ChannelConfig(
      debounceWindow: Duration(milliseconds: debounceMs),
      maxQueueDepth: maxQueueDepth,
      defaultRetryPolicy: retryPolicy,
      channelConfigs: channelConfigs,
    );
  }
}
