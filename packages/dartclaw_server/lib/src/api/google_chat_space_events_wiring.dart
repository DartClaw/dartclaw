import 'dart:async';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_google_chat/dartclaw_google_chat.dart';
import 'package:logging/logging.dart';

/// Wires the Pub/Sub → CloudEvent → dedup → ChannelManager pipeline.
///
/// Encapsulates the callback used by [PubSubClient.onMessage] to process
/// incoming Pub/Sub messages through the Space Events pipeline. Also manages
/// startup (reconcile + pull loop start) and shutdown of the infrastructure.
class GoogleChatSpaceEventsWiring {
  static final _log = Logger('GoogleChatSpaceEventsWiring');
  final PubSubClient _pubSubClient;
  final WorkspaceEventsManager _subscriptionManager;
  final CloudEventAdapter _adapter;
  final MessageDeduplicator _deduplicator;
  final ChannelManager _channelManager;
  final GoogleChatChannel? _channel;

  /// Cache of resolved sender display names keyed by sender JID.
  final Map<String, ({String displayName, DateTime cachedAt})> _senderDisplayNames = {};
  static const _senderCacheTtl = Duration(hours: 1);
  static const _senderCacheMaxSize = 500;

  GoogleChatSpaceEventsWiring({
    required PubSubClient pubSubClient,
    required WorkspaceEventsManager subscriptionManager,
    required CloudEventAdapter adapter,
    required MessageDeduplicator deduplicator,
    required ChannelManager channelManager,
    GoogleChatChannel? channel,
  }) : _pubSubClient = pubSubClient,
       _subscriptionManager = subscriptionManager,
       _adapter = adapter,
       _deduplicator = deduplicator,
       _channelManager = channelManager,
       _channel = channel;

  /// The [PubSubClient] managed by this wiring.
  PubSubClient get pubSubClient => _pubSubClient;

  /// The [WorkspaceEventsManager] managed by this wiring.
  WorkspaceEventsManager get subscriptionManager => _subscriptionManager;

  /// The [MessageDeduplicator] shared between webhook and Pub/Sub paths.
  MessageDeduplicator get deduplicator => _deduplicator;

  /// Reconciles existing subscriptions and starts the Pub/Sub pull loop.
  ///
  /// Reconciliation is awaited (with a timeout); the pull loop runs
  /// asynchronously after start and does not block callers.
  Future<void> start({Duration reconcileTimeout = const Duration(seconds: 30)}) async {
    try {
      await _subscriptionManager.reconcile().timeout(reconcileTimeout);
      _log.info('Space Events subscription reconciliation complete');
    } on TimeoutException {
      _log.warning(
        'Space Events subscription reconciliation timed out after '
        '${reconcileTimeout.inSeconds}s — continuing',
      );
    } catch (e, st) {
      _log.warning('Space Events subscription reconciliation failed — continuing', e, st);
    }

    // Start the Pub/Sub pull loop (fire-and-forget — loop runs asynchronously).
    _pubSubClient.start();
    _log.info('Space Events Pub/Sub pull client started');
  }

  /// Processes a single Pub/Sub [ReceivedMessage] through the pipeline.
  ///
  /// Returns `true` to acknowledge the message (processed, filtered, or
  /// log-only), `false` to nack (unexpected error — may be retried).
  Future<bool> processMessage(ReceivedMessage message) async {
    try {
      final result = _adapter.processMessage(message);

      return switch (result) {
        MessageResult(:final messages) => await _dispatchMessages(messages, message.messageId),
        Filtered() || LogOnly() || Acknowledged() => true, // ack, no further processing
      };
    } catch (e, st) {
      _log.warning('Failed to process Pub/Sub message ${message.messageId}', e, st);
      // Nack — Pub/Sub will redeliver after ack deadline.
      return false;
    }
  }

  Future<bool> _dispatchMessages(List<ChannelMessage> messages, String pubsubMessageId) async {
    for (final channelMessage in messages) {
      final messageName = channelMessage.metadata['messageName'] as String?;
      if (messageName != null && messageName.isNotEmpty) {
        if (!_deduplicator.tryProcess(messageName)) {
          _log.fine('Duplicate message $messageName (already seen via webhook) — acking');
          continue;
        }
      }
      await _enrichSenderDisplayName(channelMessage);

      final channel = _channel;
      if (channel != null) {
        final spaceName = channelMessage.metadata['spaceName'] as String?;
        if (spaceName != null && spaceName.isNotEmpty) {
          await channel.sendTypingIndicator(
            spaceName: spaceName,
            turnId: channelMessage.id,
            reactionTargetMessageName: channelMessage.metadata['messageName'] as String?,
          );
        }
      }
      _channelManager.handleInboundMessage(channelMessage);
    }
    return true;
  }

  /// Resolves [message]'s `senderDisplayName` metadata via the members API.
  ///
  /// Skips resolution when the display name is already populated (webhook path).
  /// Caches results per sender JID for [_senderCacheTtl]. On lookup failure,
  /// removes the key entirely — no attribution rather than a raw user ID.
  Future<void> _enrichSenderDisplayName(ChannelMessage message) async {
    final existing = message.metadata['senderDisplayName'] as String?;
    if (existing != null && existing.isNotEmpty && existing != message.senderJid) {
      return; // Already resolved (e.g. webhook-sourced).
    }

    final senderJid = message.senderJid;
    final spaceName = message.metadata['spaceName'] as String?;
    if (spaceName == null || spaceName.isEmpty) return;

    final restClient = _channel?.restClient;
    if (restClient == null) return;

    // Check cache.
    final cached = _senderDisplayNames[senderJid];
    if (cached != null && DateTime.now().difference(cached.cachedAt) < _senderCacheTtl) {
      message.metadata['senderDisplayName'] = cached.displayName;
      return;
    }

    // Resolve via API.
    final displayName = await restClient.getMemberDisplayName(spaceName, senderJid);
    if (displayName != null && displayName.isNotEmpty) {
      // Evict oldest entry when cache is full (LRU via insertion order).
      if (_senderDisplayNames.length >= _senderCacheMaxSize) {
        _senderDisplayNames.remove(_senderDisplayNames.keys.first);
      }
      _senderDisplayNames[senderJid] = (displayName: displayName, cachedAt: DateTime.now());
      message.metadata['senderDisplayName'] = displayName;
    } else {
      // Graceful: omit attribution rather than show raw ID.
      _senderDisplayNames.remove(senderJid);
      message.metadata.remove('senderDisplayName');
    }
  }

  /// Stops the pull loop and disposes the subscription manager.
  Future<void> stop() async {
    await _pubSubClient.stop();
    _subscriptionManager.dispose();
    _log.info('Space Events wiring stopped');
  }

  /// Stops the pull loop, disposes the subscription manager, and frees
  /// the underlying HTTP client.
  Future<void> dispose() async {
    await _pubSubClient.dispose();
    _subscriptionManager.dispose();
    _log.info('Space Events wiring disposed');
  }
}
