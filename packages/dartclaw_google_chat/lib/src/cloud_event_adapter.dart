import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart' show ChannelMessage, ChannelType;
import 'package:logging/logging.dart';

import 'pubsub_client.dart';

// ---------------------------------------------------------------------------
// Adapter result types
// ---------------------------------------------------------------------------

/// Result of processing a CloudEvent Pub/Sub message.
sealed class AdapterResult {
  const AdapterResult();
}

/// One or more [ChannelMessage] objects parsed from a CloudEvent.
class MessageResult extends AdapterResult {
  /// Parsed inbound messages ready for the channel pipeline.
  final List<ChannelMessage> messages;

  const MessageResult(this.messages);
}

/// Message was filtered (e.g., bot-originated).
class Filtered extends AdapterResult {
  /// Human-readable reason the message was filtered.
  final String reason;

  const Filtered(this.reason);
}

/// Event was logged but not processed (e.g., message.updated, message.deleted).
class LogOnly extends AdapterResult {
  /// The CloudEvent type that was logged.
  final String eventType;

  const LogOnly(this.eventType);
}

/// Malformed payload acknowledged to prevent redelivery loops.
class Acknowledged extends AdapterResult {
  /// Human-readable reason the payload was acknowledged without processing.
  final String reason;

  const Acknowledged(this.reason);
}

// ---------------------------------------------------------------------------
// CloudEventAdapter
// ---------------------------------------------------------------------------

/// Converts CloudEvent-formatted Pub/Sub messages into [ChannelMessage]
/// objects for the existing channel pipeline.
///
/// Stateless transformation layer — receives [ReceivedMessage] from
/// [PubSubClient] and returns structured [AdapterResult] values.
class CloudEventAdapter {
  static final _log = Logger('CloudEventAdapter');

  // Full CloudEvent type strings for routing.
  static const _typeCreated = 'google.workspace.chat.message.v1.created';
  static const _typeBatchCreated = 'google.workspace.chat.message.v1.batchCreated';
  static const _typeUpdated = 'google.workspace.chat.message.v1.updated';
  static const _typeDeleted = 'google.workspace.chat.message.v1.deleted';
  static const _typeBatchUpdated = 'google.workspace.chat.message.v1.batchUpdated';
  static const _typeBatchDeleted = 'google.workspace.chat.message.v1.batchDeleted';

  /// Log-only event types (updated, deleted, and their batch variants).
  static const _logOnlyTypes = {
    _typeUpdated,
    _typeDeleted,
    _typeBatchUpdated,
    _typeBatchDeleted,
  };

  /// Optional bot user resource name for bot message filtering.
  final String? _botUser;

  /// Creates a CloudEvent message adapter.
  ///
  /// [botUser] — optional bot user resource name (e.g., `users/BOT_ID`)
  /// used to filter self-originated messages. Matches
  /// [GoogleChatConfig.botUser].
  CloudEventAdapter({String? botUser}) : _botUser = botUser;

  /// Processes a raw Pub/Sub [ReceivedMessage] and returns a structured result.
  ///
  /// Never throws — all error paths return an [AdapterResult] variant.
  /// The caller should always acknowledge the message (return `true` to
  /// [PubSubClient]) regardless of the result variant.
  AdapterResult processMessage(ReceivedMessage message) {
    // 1. Decode base64 data → JSON string
    final Map<String, dynamic> cloudEvent;
    try {
      final bytes = base64.decode(message.data);
      final jsonString = utf8.decode(bytes);
      final decoded = jsonDecode(jsonString);
      if (decoded is! Map<String, dynamic>) {
        _log.warning('CloudEvent payload is not a JSON object (${message.messageId})');
        return const Acknowledged('payload is not a JSON object');
      }
      cloudEvent = decoded;
    } on FormatException catch (e) {
      _log.warning('Malformed CloudEvent payload (${message.messageId}): $e');
      return Acknowledged('malformed payload: $e');
    } on Exception catch (e) {
      _log.warning('Failed to decode CloudEvent (${message.messageId}): $e');
      return Acknowledged('decode failed: $e');
    }

    // 2. Extract event type
    final type = cloudEvent['type'] as String?;
    if (type == null || type.isEmpty) {
      _log.warning('CloudEvent missing type field (${message.messageId})');
      return const Acknowledged('missing type field');
    }

    // 3. Route by event type
    if (type == _typeCreated) {
      return _handleMessageCreated(cloudEvent, message.messageId);
    }
    if (type == _typeBatchCreated) {
      return _handleBatchCreated(cloudEvent, message.messageId);
    }
    if (_logOnlyTypes.contains(type)) {
      _log.fine('Received $type event (${message.messageId}) — log only');
      return LogOnly(type);
    }

    // Unknown event type — log and acknowledge
    _log.fine('Received unknown CloudEvent type "$type" (${message.messageId}) — log only');
    return LogOnly(type);
  }

  // ---------------------------------------------------------------------------
  // Event type handlers
  // ---------------------------------------------------------------------------

  /// Parses a single `message.v1.created` CloudEvent.
  AdapterResult _handleMessageCreated(
    Map<String, dynamic> cloudEvent,
    String pubsubMessageId,
  ) {
    final data = _asMap(cloudEvent['data']);
    final messageResource = _asMap(data?['message']);
    if (messageResource == null) {
      _log.warning('CloudEvent missing data.message (pubsub: $pubsubMessageId)');
      return const Acknowledged('missing data.message');
    }

    final sender = _asMap(messageResource['sender']);
    if (_isBotMessage(sender)) {
      _log.fine('Filtering bot message (pubsub: $pubsubMessageId)');
      return const Filtered('bot message');
    }

    final channelMessage = _parseMessageResource(messageResource, cloudEvent, pubsubMessageId);
    if (channelMessage == null) {
      return const Acknowledged('unparseable message resource');
    }

    return MessageResult([channelMessage]);
  }

  /// Parses a `message.v1.batchCreated` CloudEvent.
  ///
  /// Iterates over `data.messages[]`, parsing each entry's `message` field.
  /// Skips individual messages that are bot-originated or malformed.
  AdapterResult _handleBatchCreated(
    Map<String, dynamic> cloudEvent,
    String pubsubMessageId,
  ) {
    final data = _asMap(cloudEvent['data']);
    final messagesArray = data?['messages'];
    if (messagesArray is! List || messagesArray.isEmpty) {
      _log.warning(
        'CloudEvent batchCreated missing or empty data.messages (pubsub: $pubsubMessageId)',
      );
      return const Acknowledged('missing or empty data.messages');
    }

    final channelMessages = <ChannelMessage>[];
    for (var i = 0; i < messagesArray.length; i++) {
      final entry = _asMap(messagesArray[i]);
      final messageResource = _asMap(entry?['message']);
      if (messageResource == null) {
        _log.fine('Skipping batch entry $i — missing message resource (pubsub: $pubsubMessageId)');
        continue;
      }

      final sender = _asMap(messageResource['sender']);
      if (_isBotMessage(sender)) {
        _log.fine('Filtering bot message in batch entry $i (pubsub: $pubsubMessageId)');
        continue;
      }

      final channelMessage = _parseMessageResource(messageResource, cloudEvent, pubsubMessageId);
      if (channelMessage != null) {
        channelMessages.add(channelMessage);
      }
    }

    if (channelMessages.isEmpty) {
      _log.fine('All messages in batchCreated were filtered or malformed (pubsub: $pubsubMessageId)');
      return const Filtered('all batch messages filtered');
    }

    return MessageResult(channelMessages);
  }

  // ---------------------------------------------------------------------------
  // Field extraction
  // ---------------------------------------------------------------------------

  /// Parses a Chat API message resource into a [ChannelMessage].
  ///
  /// Returns `null` if required fields are missing or the message is
  /// otherwise unparseable. Caller is responsible for bot filtering before
  /// calling this method.
  ChannelMessage? _parseMessageResource(
    Map<String, dynamic> messageResource,
    Map<String, dynamic> cloudEvent,
    String pubsubMessageId,
  ) {
    final sender = _asMap(messageResource['sender']);
    final senderJid = sender?['name'] as String?;
    final space = _asMap(messageResource['space']);
    final spaceName = space?['name'] as String?;

    if (senderJid == null || senderJid.isEmpty || spaceName == null || spaceName.isEmpty) {
      _log.warning('CloudEvent message missing sender or space (pubsub: $pubsubMessageId)');
      return null;
    }

    // Prefer argumentText (strips @mention prefix), fall back to text
    final argumentText = (messageResource['argumentText'] as String?)?.trim();
    final plainText = (messageResource['text'] as String?)?.trim();
    final text = (argumentText != null && argumentText.isNotEmpty) ? argumentText : plainText;
    if (text == null || text.isEmpty) {
      _log.fine('CloudEvent message has empty text (pubsub: $pubsubMessageId)');
      return null;
    }

    // Resolve space type and group JID (same logic as GoogleChatWebhookHandler)
    final spaceType = space?['type'] as String?;
    final groupJid = switch (spaceType) {
      'DM' => null,
      'ROOM' || 'SPACE' => spaceName,
      _ => spaceName, // Default to group for unknown space types
    };

    // Parse timestamp
    DateTime? timestamp;
    final createTimeRaw = messageResource['createTime'] as String?;
    if (createTimeRaw != null) {
      timestamp = DateTime.tryParse(createTimeRaw);
    }

    final messageName = messageResource['name'] as String?;
    final senderDisplayName = sender?['displayName'] as String?;
    final senderAvatarUrl = sender?['avatarUrl'] as String?;

    final thread = messageResource['thread'];
    final threadName = (thread is Map) ? thread['name'] as String? : null;

    return ChannelMessage(
      id: messageName ?? (cloudEvent['id'] as String?),
      channelType: ChannelType.googlechat,
      senderJid: senderJid,
      groupJid: groupJid,
      text: text,
      timestamp: timestamp,
      metadata: {
        'spaceName': spaceName,
        'spaceType': ?spaceType,
        'senderDisplayName': ?senderDisplayName,
        'senderAvatarUrl': ?senderAvatarUrl,
        'messageName': ?messageName,
        if (threadName != null && threadName.isNotEmpty) 'threadName': threadName,
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  /// Returns `true` if the sender is a bot (type `BOT` or matching
  /// configured [_botUser]).
  bool _isBotMessage(Map<String, dynamic>? sender) {
    if (sender == null) return false;
    if (sender['type'] == 'BOT') return true;
    final configuredBotUser = _botUser;
    return configuredBotUser != null &&
        configuredBotUser.isNotEmpty &&
        sender['name'] == configuredBotUser;
  }

  /// Safely casts a value to `Map<String, dynamic>`, or returns `null`.
  static Map<String, dynamic>? _asMap(Object? value) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) return value.map((key, value) => MapEntry('$key', value));
    return null;
  }
}
