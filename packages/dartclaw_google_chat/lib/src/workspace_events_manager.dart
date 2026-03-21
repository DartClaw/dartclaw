import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

import 'google_chat_config.dart';

/// Persisted metadata for a single Workspace Events subscription.
class SubscriptionRecord {
  /// The Google Chat space ID (bare ID without `spaces/` prefix, e.g. `AAAA`).
  final String spaceId;

  /// Full subscription resource name as returned by the API (e.g., `subscriptions/abc123`).
  final String subscriptionName;

  /// When the subscription expires (UTC).
  final DateTime expireTime;

  /// When the subscription was created (UTC).
  final DateTime createdAt;

  const SubscriptionRecord({
    required this.spaceId,
    required this.subscriptionName,
    required this.expireTime,
    required this.createdAt,
  });

  /// Whether this subscription has expired.
  bool get isExpired => DateTime.now().toUtc().isAfter(expireTime);

  /// Parses a record from persisted JSON.
  factory SubscriptionRecord.fromJson(Map<String, dynamic> json) {
    return SubscriptionRecord(
      spaceId: json['spaceId'] as String,
      subscriptionName: json['subscriptionName'] as String,
      expireTime: DateTime.parse(json['expireTime'] as String),
      createdAt: DateTime.parse(json['createdAt'] as String),
    );
  }

  /// Serializes to JSON for persistence.
  Map<String, dynamic> toJson() => {
    'spaceId': spaceId,
    'subscriptionName': subscriptionName,
    'expireTime': expireTime.toUtc().toIso8601String(),
    'createdAt': createdAt.toUtc().toIso8601String(),
  };

  /// Returns a copy with updated fields.
  SubscriptionRecord copyWith({
    String? subscriptionName,
    DateTime? expireTime,
  }) {
    return SubscriptionRecord(
      spaceId: spaceId,
      subscriptionName: subscriptionName ?? this.subscriptionName,
      expireTime: expireTime ?? this.expireTime,
      createdAt: createdAt,
    );
  }
}

/// Manages the lifecycle of Google Workspace Events API subscriptions.
///
/// Creates subscriptions when spaces are added, renews before expiry,
/// recreates expired subscriptions, and persists metadata for crash recovery.
class WorkspaceEventsManager {
  static const _apiBase = 'https://workspaceevents.googleapis.com/v1';
  static const _eventTypePrefix = 'google.workspace.chat.';

  /// Default TTL for full-data subscriptions (4 hours in seconds).
  static const _defaultTtlSeconds = 14400;

  /// Default TTL for name-only subscriptions (7 days in seconds).
  static const _nameOnlyTtlSeconds = 604800;

  /// Renewal fires at 75% of TTL.
  static const _renewalFraction = 0.75;

  /// Small delay between API calls during reconciliation to respect rate limits.
  static const _reconciliationDelay = Duration(milliseconds: 200);

  final http.Client _httpClient;
  final SpaceEventsConfig _config;
  final File _persistFile;
  final Future<void> Function(Duration)? _delayOverride;
  final DateTime Function()? _clockOverride;
  final Logger _log = Logger('WorkspaceEventsManager');

  /// In-memory subscription records, keyed by spaceId.
  final Map<String, SubscriptionRecord> _subscriptions = {};

  /// Active renewal cancellers, keyed by spaceId.
  final Map<String, Completer<void>> _renewalCancellers = {};

  bool _disposed = false;

  /// Creates a Workspace Events subscription manager.
  ///
  /// [authClient] — authenticated HTTP client from [GcpAuthService].
  /// [config] — Workspace Events configuration from [SpaceEventsConfig].
  /// [dataDir] — directory for persisting subscription metadata.
  /// [delay] — optional delay override for testing.
  /// [clock] — optional clock override for testing.
  WorkspaceEventsManager({
    required http.Client authClient,
    required SpaceEventsConfig config,
    required String dataDir,
    Future<void> Function(Duration)? delay,
    DateTime Function()? clock,
  }) : _httpClient = authClient,
       _config = config,
       _persistFile = File('$dataDir/google-chat-subscriptions.json'),
       _delayOverride = delay,
       _clockOverride = clock;

  /// Current time (overridable for testing).
  DateTime _now() => _clockOverride?.call() ?? DateTime.now().toUtc();

  /// TTL in seconds based on the configured includeResource setting.
  int get _ttlSeconds => _config.includeResource ? _defaultTtlSeconds : _nameOnlyTtlSeconds;

  /// Current subscription records (read-only snapshot).
  Map<String, SubscriptionRecord> get subscriptions => Map.unmodifiable(_subscriptions);

  /// Returns the number of currently tracked subscriptions.
  int get activeSubscriptionCount => _subscriptions.length;

  /// Whether the manager has been disposed.
  bool get isDisposed => _disposed;

  /// Expands event type shorthand to fully-qualified form.
  ///
  /// `message.created` -> `google.workspace.chat.message.v1.created`
  /// Already-qualified types (starting with `google.workspace.`) pass through.
  static List<String> expandEventTypes(List<String> shorthand) {
    return shorthand.map((type) {
      if (type.startsWith('google.workspace.')) {
        return type;
      }
      final dotIndex = type.indexOf('.');
      if (dotIndex == -1) {
        return type; // pass through malformed shorthand
      }
      final resource = type.substring(0, dotIndex);
      final action = type.substring(dotIndex + 1);
      return '$_eventTypePrefix$resource.v1.$action';
    }).toList();
  }

  // ---------------------------------------------------------------------------
  // Persistence
  // ---------------------------------------------------------------------------

  /// Loads persisted subscription records from disk.
  Future<void> _loadFromDisk() async {
    if (!_persistFile.existsSync()) {
      _log.fine('No persisted subscriptions file found');
      return;
    }

    try {
      final content = await _persistFile.readAsString();
      if (content.trim().isEmpty) {
        return;
      }
      final decoded = jsonDecode(content);
      if (decoded is! Map<String, dynamic>) {
        _log.warning('Invalid subscriptions file format — ignoring');
        return;
      }
      final rawList = decoded['subscriptions'];
      if (rawList is! List) {
        _log.warning('Invalid subscriptions list in file — ignoring');
        return;
      }
      for (final raw in rawList) {
        if (raw is Map<String, dynamic>) {
          try {
            final record = SubscriptionRecord.fromJson(raw);
            _subscriptions[record.spaceId] = record;
          } on Exception catch (e) {
            _log.warning('Skipping malformed subscription record: $e');
          }
        }
      }
      _log.fine('Loaded ${_subscriptions.length} persisted subscriptions');
    } on Exception catch (e, st) {
      _log.warning('Failed to load persisted subscriptions', e, st);
    }
  }

  /// Persists current subscription records to disk (atomic write).
  Future<void> _saveToDisk() async {
    final json = {
      'subscriptions': _subscriptions.values.map((r) => r.toJson()).toList(),
    };
    final tempFile = File('${_persistFile.path}.tmp');
    try {
      await _persistFile.parent.create(recursive: true);
      await tempFile.writeAsString(jsonEncode(json));
      await tempFile.rename(_persistFile.path);
    } on Exception catch (e, st) {
      _log.warning('Failed to persist subscriptions', e, st);
    }
  }

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  /// Normalizes a space identifier by stripping the `spaces/` prefix if present.
  ///
  /// Accepts both `spaces/AAAA` (full resource name from webhook payloads)
  /// and bare `AAAA`. Always returns the bare ID for internal use.
  static String normalizeSpaceId(String spaceId) {
    if (spaceId.startsWith('spaces/')) {
      return spaceId.substring('spaces/'.length);
    }
    return spaceId;
  }

  /// Creates a Workspace Events subscription for a Google Chat space.
  ///
  /// [spaceId] accepts either a full resource name (`spaces/AAAA`) or a
  /// bare ID (`AAAA`) — the prefix is stripped automatically.
  ///
  /// If a subscription already exists for this space, it is returned as-is.
  /// Returns the subscription record on success, null on failure.
  Future<SubscriptionRecord?> subscribe(String spaceId) async {
    if (_disposed) {
      _log.warning('Cannot subscribe — manager is disposed');
      return null;
    }

    final normalized = normalizeSpaceId(spaceId);
    final existing = _subscriptions[normalized];
    if (existing != null && !existing.isExpired) {
      _log.fine('Subscription already exists for space $normalized');
      return existing;
    }

    return _createSubscription(normalized);
  }

  /// Deletes the Workspace Events subscription for a Google Chat space.
  ///
  /// [spaceId] accepts either a full resource name or bare ID.
  /// Returns true if the subscription was deleted (or already absent), false on error.
  Future<bool> unsubscribe(String spaceId) async {
    final normalized = normalizeSpaceId(spaceId);
    final record = _subscriptions[normalized];
    if (record == null) {
      _log.fine('No subscription to remove for space $normalized');
      return true;
    }

    _cancelRenewal(normalized);

    final deleted = await _deleteSubscription(record.subscriptionName);

    // Remove from memory and persist regardless of API result
    _subscriptions.remove(normalized);
    await _saveToDisk();

    if (deleted) {
      _log.info('Unsubscribed from space $normalized');
    } else {
      _log.warning('API delete failed for space $normalized — removed from local tracking');
    }
    return deleted;
  }

  /// Reconciles persisted subscriptions with actual API state.
  ///
  /// Call on server startup. Loads from disk, verifies each subscription,
  /// renews active ones, recreates expired ones, prunes orphaned entries.
  Future<void> reconcile() async {
    if (_disposed) {
      _log.warning('Cannot reconcile — manager is disposed');
      return;
    }

    await _loadFromDisk();
    if (_subscriptions.isEmpty) {
      _log.fine('No persisted subscriptions to reconcile');
      return;
    }

    _log.info('Reconciling ${_subscriptions.length} persisted subscriptions');
    final spaceIds = _subscriptions.keys.toList();
    var updated = false;

    for (final spaceId in spaceIds) {
      if (_disposed) break;

      final record = _subscriptions[spaceId];
      if (record == null) continue;

      if (record.isExpired) {
        _log.info('Subscription for space $spaceId expired — recreating');
        await _deleteSubscription(record.subscriptionName);
        final newRecord = await _createSubscription(spaceId);
        if (newRecord == null) {
          _subscriptions.remove(spaceId);
          _log.warning('Failed to recreate subscription for space $spaceId — removing');
        }
        updated = true;
      } else {
        final verified = await _verifySubscription(record);
        if (verified) {
          _scheduleRenewal(_subscriptions[spaceId]!);
        } else {
          _log.info('Subscription for space $spaceId not verifiable — recreating');
          final newRecord = await _createSubscription(spaceId);
          if (newRecord == null) {
            _subscriptions.remove(spaceId);
            _log.warning('Failed to recreate subscription for space $spaceId — removing');
          }
          updated = true;
        }
      }

      if (!_disposed) {
        final delay = _delayOverride ?? Future.delayed;
        await delay(_reconciliationDelay);
      }
    }

    if (updated) {
      await _saveToDisk();
    }
    _log.info('Reconciliation complete: ${_subscriptions.length} active subscriptions');
  }

  /// Disposes the manager — cancels all renewal timers.
  ///
  /// Does NOT delete subscriptions — they expire naturally.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _log.info('Disposing WorkspaceEventsManager');

    for (final canceller in _renewalCancellers.values) {
      if (!canceller.isCompleted) {
        canceller.complete();
      }
    }
    _renewalCancellers.clear();
  }

  // ---------------------------------------------------------------------------
  // Internal API operations
  // ---------------------------------------------------------------------------

  Future<SubscriptionRecord?> _createSubscription(String spaceId) async {
    final uri = Uri.parse('$_apiBase/subscriptions');
    final expandedEventTypes = expandEventTypes(_config.eventTypes);

    final body = {
      'targetResource': '//chat.googleapis.com/spaces/$spaceId',
      'eventTypes': expandedEventTypes,
      'notificationEndpoint': {
        'pubsubTopic': _config.pubsubTopic,
      },
      'payloadOptions': {
        'includeResource': _config.includeResource,
      },
    };

    try {
      final response = await _httpClient.post(
        uri,
        headers: const {'content-type': 'application/json'},
        body: jsonEncode(body),
      );

      if (response.statusCode < 200 || response.statusCode >= 300) {
        _log.warning(
          'Failed to create subscription for space $spaceId: '
          'HTTP ${response.statusCode} — ${response.body}',
        );
        return null;
      }

      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        _log.warning('Invalid response from create subscription for space $spaceId');
        return null;
      }

      final subscriptionName = decoded['name'] as String?;
      final expireTimeStr = decoded['expireTime'] as String?;
      if (subscriptionName == null || expireTimeStr == null) {
        _log.warning('Missing name or expireTime in create response for space $spaceId');
        return null;
      }

      final record = SubscriptionRecord(
        spaceId: spaceId,
        subscriptionName: subscriptionName,
        expireTime: DateTime.parse(expireTimeStr),
        createdAt: _now(),
      );

      _subscriptions[spaceId] = record;
      await _saveToDisk();
      _scheduleRenewal(record);
      _log.info('Created subscription for space $spaceId: $subscriptionName (expires $expireTimeStr)');
      return record;
    } on Exception catch (e, st) {
      _log.warning('Exception creating subscription for space $spaceId', e, st);
      return null;
    }
  }

  /// Deletes a subscription via the Workspace Events API.
  /// Returns true on success or 404 (already deleted).
  Future<bool> _deleteSubscription(String subscriptionName) async {
    final uri = Uri.parse('$_apiBase/$subscriptionName');
    try {
      final response = await _httpClient.delete(uri);
      if (response.statusCode >= 200 && response.statusCode < 300) {
        return true;
      }
      if (response.statusCode == 404) {
        _log.fine('Subscription $subscriptionName already deleted (404)');
        return true;
      }
      _log.warning('Delete subscription $subscriptionName failed: HTTP ${response.statusCode}');
      return false;
    } on Exception catch (e, st) {
      _log.warning('Exception deleting subscription $subscriptionName', e, st);
      return false;
    }
  }

  /// Verifies a subscription exists and is active via GET.
  /// Returns true if active, false if not found or in bad state.
  Future<bool> _verifySubscription(SubscriptionRecord record) async {
    final uri = Uri.parse('$_apiBase/${record.subscriptionName}');
    try {
      final response = await _httpClient.get(uri);
      if (response.statusCode >= 200 && response.statusCode < 300) {
        final decoded = jsonDecode(response.body);
        if (decoded is Map<String, dynamic>) {
          final state = decoded['state'] as String?;
          if (state == 'ACTIVE') {
            // Update expireTime from API (may differ from persisted)
            final expireTimeStr = decoded['expireTime'] as String?;
            if (expireTimeStr != null) {
              _subscriptions[record.spaceId] = record.copyWith(
                expireTime: DateTime.parse(expireTimeStr),
              );
            }
            return true;
          }
          _log.warning(
            'Subscription ${record.subscriptionName} for space ${record.spaceId} '
            'is in state $state — will recreate',
          );
          return false;
        }
      }
      if (response.statusCode == 404) {
        _log.fine('Subscription ${record.subscriptionName} not found (404)');
        return false;
      }
      _log.warning('Verify subscription ${record.subscriptionName} failed: HTTP ${response.statusCode}');
      return false;
    } on Exception catch (e, st) {
      _log.warning('Exception verifying subscription ${record.subscriptionName}', e, st);
      return false;
    }
  }

  // ---------------------------------------------------------------------------
  // Renewal scheduling
  // ---------------------------------------------------------------------------

  void _scheduleRenewal(SubscriptionRecord record) {
    _cancelRenewal(record.spaceId);

    // Compute renewal delay from remaining time to expiry, not from createdAt.
    // This is correct after reconciliation where createdAt may be stale but
    // expireTime is fresh from the API.
    final remaining = record.expireTime.difference(_now());
    final delayFromNow = Duration(
      microseconds: (remaining.inMicroseconds * _renewalFraction).round(),
    );

    if (delayFromNow.isNegative || delayFromNow == Duration.zero) {
      _log.fine('Renewal overdue for space ${record.spaceId} — renewing immediately');
      unawaited(_executeRenewal(record.spaceId));
      return;
    }

    final canceller = Completer<void>();
    _renewalCancellers[record.spaceId] = canceller;

    _log.fine('Scheduled renewal for space ${record.spaceId} in ${delayFromNow.inMinutes}m');

    unawaited(() async {
      await _interruptibleDelay(delayFromNow, canceller);
      if (canceller.isCompleted || _disposed) return;
      await _executeRenewal(record.spaceId);
    }());
  }

  Future<void> _executeRenewal(String spaceId) async {
    if (_disposed) return;

    final record = _subscriptions[spaceId];
    if (record == null) {
      _log.fine('Renewal skipped — no subscription for space $spaceId');
      return;
    }

    if (record.isExpired) {
      _log.info('Subscription for space $spaceId has expired — recreating');
      await _deleteSubscription(record.subscriptionName);
      _subscriptions.remove(spaceId);
      await _createSubscription(spaceId);
      return;
    }

    final uri = Uri.parse('$_apiBase/${record.subscriptionName}');
    try {
      final response = await _httpClient.patch(
        uri,
        headers: const {'content-type': 'application/json'},
        body: jsonEncode({'ttl': '${_ttlSeconds}s'}),
      );

      if (response.statusCode >= 200 && response.statusCode < 300) {
        final decoded = jsonDecode(response.body);
        if (decoded is Map<String, dynamic>) {
          final newExpireTimeStr = decoded['expireTime'] as String?;
          if (newExpireTimeStr != null) {
            final updated = record.copyWith(
              expireTime: DateTime.parse(newExpireTimeStr),
            );
            _subscriptions[spaceId] = updated;
            await _saveToDisk();
            _scheduleRenewal(updated);
            _log.info('Renewed subscription for space $spaceId (expires $newExpireTimeStr)');
            return;
          }
        }
        _log.warning('Unexpected renewal response for space $spaceId');
      } else if (response.statusCode == 404) {
        _log.info('Subscription for space $spaceId not found on renewal — recreating');
        _subscriptions.remove(spaceId);
        await _createSubscription(spaceId);
      } else {
        _log.warning('Renewal failed for space $spaceId: HTTP ${response.statusCode} — ${response.body}');
        // Schedule a retry at half the remaining time
        final remaining = record.expireTime.difference(_now());
        if (remaining > const Duration(minutes: 5)) {
          final retryDelay = Duration(microseconds: (remaining.inMicroseconds * 0.5).round());
          final canceller = Completer<void>();
          _renewalCancellers[spaceId] = canceller;
          _log.fine('Scheduling renewal retry for space $spaceId in ${retryDelay.inMinutes}m');
          unawaited(() async {
            await _interruptibleDelay(retryDelay, canceller);
            if (!canceller.isCompleted && !_disposed) {
              await _executeRenewal(spaceId);
            }
          }());
        }
      }
    } on Exception catch (e, st) {
      _log.warning('Exception renewing subscription for space $spaceId', e, st);
    }
  }

  void _cancelRenewal(String spaceId) {
    final canceller = _renewalCancellers.remove(spaceId);
    if (canceller != null && !canceller.isCompleted) {
      canceller.complete();
    }
  }

  Future<void> _interruptibleDelay(Duration duration, Completer<void> canceller) async {
    final delay = _delayOverride ?? Future.delayed;
    await Future.any([delay(duration), canceller.future]);
  }
}
