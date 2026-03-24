import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

import 'google_chat_config.dart';

/// A message pulled from a Cloud Pub/Sub subscription.
class ReceivedMessage {
  /// Opaque acknowledgement ID (used for ack/nack).
  final String ackId;

  /// Base64-encoded message data (CloudEvent JSON — not decoded here).
  final String data;

  /// Unique message identifier assigned by Pub/Sub.
  final String messageId;

  /// Time the message was published.
  final String publishTime;

  /// CloudEvent and other attributes from the Pub/Sub message.
  final Map<String, String> attributes;

  const ReceivedMessage({
    required this.ackId,
    required this.data,
    required this.messageId,
    required this.publishTime,
    required this.attributes,
  });

  /// Parses a [ReceivedMessage] from the Pub/Sub pull response JSON.
  factory ReceivedMessage.fromJson(Map<String, dynamic> json) {
    final message = json['message'] as Map<String, dynamic>;
    return ReceivedMessage(
      ackId: json['ackId'] as String,
      data: message['data'] as String? ?? '',
      messageId: message['messageId'] as String? ?? '',
      publishTime: message['publishTime'] as String? ?? '',
      attributes:
          (message['attributes'] as Map<String, dynamic>?)?.map((k, v) => MapEntry(k, v.toString())) ?? const {},
    );
  }
}

/// Health status snapshot for the Pub/Sub pull client.
class PubSubHealthStatus {
  /// Overall status: 'healthy', 'degraded', or 'unavailable'.
  final String status;

  /// Timestamp of the last successful pull (even if empty).
  final DateTime? lastSuccessfulPull;

  /// Number of consecutive pull failures.
  final int consecutiveErrors;

  const PubSubHealthStatus({required this.status, this.lastSuccessfulPull, this.consecutiveErrors = 0});

  Map<String, dynamic> toJson() => {
    'status': status,
    if (lastSuccessfulPull != null) 'last_successful_pull': lastSuccessfulPull!.toUtc().toIso8601String(),
    'consecutive_errors': consecutiveErrors,
  };
}

/// Lightweight Cloud Pub/Sub pull client using REST API v1.
///
/// Periodically polls a Pub/Sub subscription for messages, delivers them to a
/// callback, and acks or nacks based on the callback result. Uses exponential
/// backoff on transient API errors (429, 5xx). Supports graceful shutdown.
class PubSubClient {
  static const _pubsubApiBase = 'https://pubsub.googleapis.com/v1';
  static const _maxBackoffSeconds = 32;
  static const _degradedThreshold = 5;
  static const _permanentErrorBackoffThreshold = 10;
  static const _shutdownTimeout = Duration(seconds: 5);

  final http.Client _httpClient;

  /// Full resource path: 'projects/{project}/subscriptions/{sub}'.
  final String _subscriptionPath;
  final int _pollIntervalSeconds;
  final int _maxMessages;
  final Future<bool> Function(ReceivedMessage) _onMessage;
  final Future<void> Function(Duration)? _delayOverride;
  final Logger _log = Logger('PubSubClient');

  bool _running = false;
  // Completed by stop() to interrupt in-flight delays immediately.
  Completer<void>? _stopSignal;
  // Completed by _pullLoop() when it exits, so stop() can await loop teardown.
  Completer<void>? _loopDone;
  DateTime? _lastSuccessfulPull;
  int _consecutiveErrors = 0;
  bool _disposed = false;
  bool _httpClientClosed = false;

  /// Creates a Pub/Sub pull client.
  ///
  /// [authClient] — authenticated HTTP client from [GcpAuthService].
  /// [projectId] — GCP project ID.
  /// [subscription] — Pub/Sub subscription name.
  /// [pollIntervalSeconds] — seconds between pulls (default 2).
  /// [maxMessages] — max messages per pull (default 100).
  /// [onMessage] — callback for each received message. Return `true` to ack,
  ///   `false` to nack (message will be redelivered).
  /// [delay] — optional delay override for testing.
  PubSubClient({
    required http.Client authClient,
    required String projectId,
    required String subscription,
    int pollIntervalSeconds = 2,
    int maxMessages = 100,
    required Future<bool> Function(ReceivedMessage) onMessage,
    Future<void> Function(Duration)? delay,
  }) : _httpClient = authClient,
       _subscriptionPath = 'projects/$projectId/subscriptions/$subscription',
       _pollIntervalSeconds = pollIntervalSeconds,
       _maxMessages = maxMessages,
       _onMessage = onMessage,
       _delayOverride = delay;

  /// Creates a [PubSubClient] from a [PubSubConfig].
  ///
  /// Throws [ArgumentError] if [config] is not fully configured
  /// (i.e., [PubSubConfig.isConfigured] is false).
  factory PubSubClient.fromConfig({
    required http.Client authClient,
    required PubSubConfig config,
    required Future<bool> Function(ReceivedMessage) onMessage,
    Future<void> Function(Duration)? delay,
  }) {
    if (!config.isConfigured) {
      throw ArgumentError('PubSubConfig.isConfigured must be true');
    }
    return PubSubClient(
      authClient: authClient,
      projectId: config.projectId!,
      subscription: config.subscription!,
      pollIntervalSeconds: config.pollIntervalSeconds,
      maxMessages: config.maxMessagesPerPull,
      onMessage: onMessage,
      delay: delay,
    );
  }

  /// Whether the client is currently running.
  bool get isRunning => _running;

  /// Current health status snapshot.
  PubSubHealthStatus get healthStatus {
    if (_lastSuccessfulPull == null && _consecutiveErrors > 0) {
      return PubSubHealthStatus(status: 'unavailable', consecutiveErrors: _consecutiveErrors);
    }
    return PubSubHealthStatus(
      status: _consecutiveErrors >= _degradedThreshold ? 'degraded' : 'healthy',
      lastSuccessfulPull: _lastSuccessfulPull,
      consecutiveErrors: _consecutiveErrors,
    );
  }

  /// Starts the pull loop. Returns immediately; loop runs asynchronously.
  ///
  /// Does nothing if already running.
  void start() {
    if (_disposed) {
      throw StateError('Cannot start a disposed PubSubClient');
    }
    if (_running) return;
    _running = true;
    _consecutiveErrors = 0;
    _lastSuccessfulPull = null;
    _stopSignal = Completer<void>();
    _loopDone = Completer<void>();
    _log.info('Starting Pub/Sub pull client for $_subscriptionPath');
    unawaited(_pullLoop());
  }

  /// Stops the pull loop gracefully.
  ///
  /// Signals the loop to exit, then waits up to 5 seconds for it to finish.
  /// Does nothing if not running.
  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    _log.info('Stopping Pub/Sub pull client for $_subscriptionPath');

    // Complete the stop signal to interrupt any in-flight delay immediately.
    final signal = _stopSignal;
    if (signal != null && !signal.isCompleted) {
      signal.complete();
    }

    // Wait for the pull loop to finish cleanly.
    final done = _loopDone;
    if (done != null && !done.isCompleted) {
      try {
        await done.future.timeout(_shutdownTimeout);
      } on TimeoutException {
        _log.warning('Pub/Sub pull client shutdown timed out after ${_shutdownTimeout.inSeconds}s');
      }
    }
    _stopSignal = null;
    _loopDone = null;
  }

  /// Stops the client and closes the underlying HTTP client.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;

    if (_running) {
      _running = false;
      _log.info('Stopping Pub/Sub pull client for $_subscriptionPath');
    }

    final signal = _stopSignal;
    if (signal != null && !signal.isCompleted) {
      signal.complete();
    }

    if (!_httpClientClosed) {
      _httpClient.close();
      _httpClientClosed = true;
    }

    final done = _loopDone;
    if (done != null && !done.isCompleted) {
      try {
        await done.future.timeout(_shutdownTimeout);
      } on TimeoutException {
        _log.warning(
          'Pub/Sub pull client shutdown timed out after ${_shutdownTimeout.inSeconds}s '
          'while disposing',
        );
      }
    }

    _stopSignal = null;
    _loopDone = null;
  }

  Future<void> _pullLoop() async {
    while (_running) {
      // Yield to the timer queue to prevent microtask starvation. Without this,
      // a fast delay override (e.g. in tests) can monopolize the microtask queue
      // and prevent stop() or other scheduled work from executing.
      await Future<void>.delayed(Duration.zero);
      if (!_running) break;

      try {
        final messages = await _pull();
        // Successful pull (even if empty)
        _lastSuccessfulPull = DateTime.now();
        _consecutiveErrors = 0;
        if (!_running) break;

        if (messages.isNotEmpty) {
          await _processMessages(messages);
        }
      } on _TransientPubSubError catch (e) {
        _consecutiveErrors++;
        if (!_running) break;
        final backoff = _calculateBackoff();
        _log.warning(
          'Pub/Sub pull failed (${e.statusCode}): ${e.message}. '
          'Consecutive errors: $_consecutiveErrors. Backing off ${backoff}s',
        );
        await _interruptibleDelay(Duration(seconds: backoff));
        continue; // skip normal poll delay
      } on _PermanentPubSubError catch (e) {
        _consecutiveErrors++;
        if (!_running) break;
        _log.warning(
          'Pub/Sub pull failed (${e.statusCode}): ${e.message}. '
          'Consecutive errors: $_consecutiveErrors. Check configuration',
        );
        // After sustained permanent errors, slow down to avoid hammering the API.
        if (_consecutiveErrors >= _permanentErrorBackoffThreshold) {
          await _interruptibleDelay(Duration(seconds: _maxBackoffSeconds));
          continue;
        }
      } on Exception catch (e, st) {
        if (!_running) {
          _log.fine('Pub/Sub pull loop aborted during shutdown: $e');
          break;
        }
        _consecutiveErrors++;
        final backoff = _calculateBackoff();
        _log.warning(
          'Pub/Sub pull exception: $e. '
          'Consecutive errors: $_consecutiveErrors. Backing off ${backoff}s',
          e,
          st,
        );
        await _interruptibleDelay(Duration(seconds: backoff));
        continue;
      }

      if (_running) {
        await _interruptibleDelay(Duration(seconds: _pollIntervalSeconds));
      }
    }

    final done = _loopDone;
    if (done != null && !done.isCompleted) {
      done.complete();
    }
  }

  Future<List<ReceivedMessage>> _pull() async {
    final uri = Uri.parse('$_pubsubApiBase/$_subscriptionPath:pull');
    final response = await _httpClient.post(
      uri,
      headers: const {'content-type': 'application/json'},
      body: jsonEncode({'maxMessages': _maxMessages}),
    );

    final statusCode = response.statusCode;
    if (statusCode >= 200 && statusCode < 300) {
      if (response.body.isEmpty) {
        return const [];
      }
      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        return const [];
      }
      final rawMessages = decoded['receivedMessages'];
      if (rawMessages is! List || rawMessages.isEmpty) {
        return const [];
      }
      return rawMessages.whereType<Map<String, dynamic>>().map(ReceivedMessage.fromJson).toList();
    }

    if (statusCode == 429 || statusCode >= 500) {
      throw _TransientPubSubError(statusCode, response.body);
    }

    throw _PermanentPubSubError(statusCode, response.body);
  }

  Future<void> _processMessages(List<ReceivedMessage> messages) async {
    final ackIds = <String>[];
    final nackIds = <String>[];

    for (final msg in messages) {
      try {
        final accepted = await _onMessage(msg);
        if (accepted) {
          ackIds.add(msg.ackId);
        } else {
          nackIds.add(msg.ackId);
        }
      } on Exception catch (e, st) {
        _log.warning('Message callback failed for ${msg.messageId}', e, st);
        nackIds.add(msg.ackId);
      }
    }

    if (ackIds.isNotEmpty) {
      await _acknowledge(ackIds);
    }
    if (nackIds.isNotEmpty) {
      await _nack(nackIds);
    }
  }

  Future<void> _acknowledge(List<String> ackIds) async {
    final uri = Uri.parse('$_pubsubApiBase/$_subscriptionPath:acknowledge');
    try {
      final response = await _httpClient.post(
        uri,
        headers: const {'content-type': 'application/json'},
        body: jsonEncode({'ackIds': ackIds}),
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        _log.warning('Pub/Sub acknowledge failed with HTTP ${response.statusCode}');
      } else {
        _log.fine('Acknowledged ${ackIds.length} messages');
      }
    } on Exception catch (e, st) {
      _log.warning('Pub/Sub acknowledge request failed', e, st);
    }
  }

  Future<void> _nack(List<String> ackIds) async {
    final uri = Uri.parse('$_pubsubApiBase/$_subscriptionPath:modifyAckDeadline');
    try {
      final response = await _httpClient.post(
        uri,
        headers: const {'content-type': 'application/json'},
        body: jsonEncode({'ackIds': ackIds, 'ackDeadlineSeconds': 0}),
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        _log.warning('Pub/Sub nack (modifyAckDeadline) failed with HTTP ${response.statusCode}');
      } else {
        _log.fine('Nacked ${ackIds.length} messages');
      }
    } on Exception catch (e, st) {
      _log.warning('Pub/Sub nack request failed', e, st);
    }
  }

  int _calculateBackoff() {
    // 2^errors capped at _maxBackoffSeconds: 2, 4, 8, 16, 32
    final raw = 1 << _consecutiveErrors.clamp(1, 5);
    return raw.clamp(1, _maxBackoffSeconds);
  }

  /// Delays for [duration], but can be interrupted early by [stop()].
  Future<void> _interruptibleDelay(Duration duration) async {
    final delay = _delayOverride ?? Future.delayed;
    final stopFuture = _stopSignal?.future;
    if (stopFuture == null) {
      await delay(duration);
      return;
    }
    await Future.any([delay(duration), stopFuture]);
  }
}

class _TransientPubSubError implements Exception {
  final int statusCode;
  final String message;
  const _TransientPubSubError(this.statusCode, this.message);
}

class _PermanentPubSubError implements Exception {
  final int statusCode;
  final String message;
  const _PermanentPubSubError(this.statusCode, this.message);
}
