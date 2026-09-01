import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_core/dartclaw_core.dart'
    show
        Channel,
        ChannelManager,
        ChannelResponse,
        DmAccessController,
        MentionGating,
        chunkNativeChatMarkup,
        sourceMessageIdMetadataKey;
import 'package:logging/logging.dart';

import 'google_chat_config.dart';
import 'google_chat_rest_client.dart' show GoogleChatRestClient, messageNamePattern, typingIndicatorEmoji;
import 'markdown_converter.dart';

const _firstChunkMetadataKey = 'isFirstChunk';

/// Channel adapter that delivers DartClaw responses to Google Chat spaces.
class GoogleChatChannel extends Channel {
  static final _log = Logger('GoogleChatChannel');

  @override
  final String name = 'googlechat';

  @override
  final ChannelType type = ChannelType.googlechat;

  /// Parsed Google Chat runtime configuration.
  final GoogleChatConfig config;

  /// Authenticated REST client used for outbound Google Chat API calls.
  final GoogleChatRestClient restClient;

  /// Optional DM access controller for one-to-one spaces.
  final DmAccessController? dmAccess;

  /// Optional mention-gating helper for group spaces.
  final MentionGating? mentionGating;
  final ChannelManager? _channelManager;
  final Map<String, String> _pendingPlaceholders = {};
  final Map<String, String> _pendingReactions = {};

  /// Creates a Google Chat channel adapter.
  new({
    required this.config,
    required this.restClient,
    ChannelManager? channelManager,
    this.dmAccess,
    this.mentionGating,
  }) : _channelManager = channelManager;

  /// Channel manager used to route normalized inbound messages, if attached.
  ChannelManager? get channelManager => _channelManager;

  @override
  Future<void> connect() async {
    _log.info('Starting Google Chat channel');
    await restClient.testConnection();
    _log.info('Google Chat API credentials verified');
    _log.info('Google Chat channel connected');
  }

  @override
  Future<void> sendMessage(String recipientJid, ChannelResponse response) async {
    if (response.mediaAttachments.isNotEmpty) {
      _log.warning('Outbound Google Chat media attachments are not yet supported');
    }

    final sourceId = response.metadata[sourceMessageIdMetadataKey] as String?;
    final nativeQuoteName = _nativeQuotedMessageName(response);
    final nativeQuoteLastUpdateTime = _quotedMessageLastUpdateTime(response, nativeQuoteName);

    // Remove any pending emoji reaction for this turn.
    final pendingReaction = sourceId == null ? null : _pendingReactions.remove(_placeholderKey(recipientJid, sourceId));
    if (pendingReaction != null) {
      await restClient.removeReaction(pendingReaction);
    }

    final structuredPayload = response.structuredPayload;
    final fallbackText = _fallbackText(response);
    final isFirstChunk = response.metadata[_firstChunkMetadataKey] as bool? ?? true;
    final displayText = isFirstChunk ? _withSenderAttribution(response, fallbackText) : fallbackText;

    if (structuredPayload != null) {
      final sent = await restClient.send(
        spaceName: recipientJid,
        card: structuredPayload,
        quotedMessageName: nativeQuoteName,
        quotedMessageLastUpdateTime: nativeQuoteLastUpdateTime,
      );
      if (sent.messageName != null) {
        final turnId = response.metadata[sourceMessageIdMetadataKey] as String?;
        if (turnId != null) {
          _pendingPlaceholders.remove(_placeholderKey(recipientJid, turnId));
        }
        return;
      }
      _log.warning('Google Chat card send failed for $recipientJid, falling back to plain text');
    }

    if (fallbackText.isEmpty) {
      return;
    }

    final turnId = response.metadata[sourceMessageIdMetadataKey] as String?;
    final placeholder = turnId == null ? null : _pendingPlaceholders.remove(_placeholderKey(recipientJid, turnId));
    if (placeholder != null) {
      if (nativeQuoteName != null) {
        // Can't add quotedMessageMetadata via PATCH — try sending a new
        // quoted message first. If quoting succeeds, delete the placeholder.
        // If quoting fails (403/400), edit the placeholder with the response
        // text instead of deleting it, avoiding the "message deleted by its
        // author" artifact that Google Chat shows for deleted bot messages.
        final sent = await restClient.send(
          spaceName: recipientJid,
          text: fallbackText,
          quotedMessageName: nativeQuoteName,
          quotedMessageLastUpdateTime: nativeQuoteLastUpdateTime,
          fallbackOnQuoteFailure: false,
        );
        if (sent.messageName != null) {
          await restClient.deleteMessage(placeholder);
          return;
        }
        _log.info('Native quote send failed for $recipientJid, editing placeholder instead');
      }
      final updated = await restClient.editMessage(placeholder, displayText);
      if (updated) {
        return;
      }
      _log.warning('Failed to edit typing placeholder for $recipientJid, falling back to new message');
    }

    if (nativeQuoteName != null) {
      await restClient.send(
        spaceName: recipientJid,
        text: fallbackText,
        quotedMessageName: nativeQuoteName,
        quotedMessageLastUpdateTime: nativeQuoteLastUpdateTime,
        textWithoutQuote: displayText,
      );
      return;
    }

    await restClient.send(spaceName: recipientJid, text: displayText);
  }

  /// Sends a notification [response] to [recipientJid] in a new or existing
  /// thread identified by [threadKey].
  ///
  /// Returns the server-assigned thread name from the API response, or `null`
  /// if the send failed. The thread name can be stored as a [ThreadBinding]
  /// to route subsequent inbound messages from that thread to the task session.
  Future<String?> sendMessageWithThread(
    String recipientJid,
    ChannelResponse response, {
    required String threadKey,
  }) async {
    final structuredPayload = response.structuredPayload;
    final fallbackText = _fallbackText(response);

    if (structuredPayload != null) {
      final result = await restClient.send(spaceName: recipientJid, card: structuredPayload, threadKey: threadKey);
      if (result.messageName != null) {
        return result.threadName;
      }
      _log.warning('Google Chat threaded card send failed for $recipientJid, falling back to plain text');
    }

    if (fallbackText.isEmpty) {
      return null;
    }

    final result = await restClient.send(spaceName: recipientJid, text: fallbackText, threadKey: threadKey);
    return result.threadName;
  }

  /// Sends a notification [response] to [recipientJid] in an existing
  /// server-assigned thread named [threadName].
  Future<void> sendMessageToThreadName(
    String recipientJid,
    ChannelResponse response, {
    required String threadName,
  }) async {
    final structuredPayload = response.structuredPayload;
    final fallbackText = _fallbackText(response);

    if (structuredPayload != null) {
      final sent = await restClient.send(spaceName: recipientJid, card: structuredPayload, threadName: threadName);
      if (sent.messageName != null) {
        return;
      }
      _log.warning('Google Chat thread-name card send failed for $recipientJid, falling back to plain text');
    }

    if (fallbackText.isEmpty) {
      return;
    }

    await restClient.send(spaceName: recipientJid, text: fallbackText, threadName: threadName);
  }

  /// Associates a pending typing placeholder with an outbound turn id.
  void setPlaceholder({required String spaceName, required String turnId, required String messageName}) {
    _pendingPlaceholders[_placeholderKey(spaceName, turnId)] = messageName;
  }

  /// Returns the pending typing placeholder for [turnId] without removing it.
  String? peekPlaceholderMessageId({required String spaceName, required String turnId}) {
    return _pendingPlaceholders[_placeholderKey(spaceName, turnId)];
  }

  /// Removes the pending typing placeholder for [turnId], if present.
  void clearPlaceholder({required String spaceName, required String turnId}) {
    _pendingPlaceholders.remove(_placeholderKey(spaceName, turnId));
  }

  /// Associates a pending emoji reaction with an outbound turn id.
  void setReaction({required String spaceName, required String turnId, required String reactionName}) {
    _pendingReactions[_placeholderKey(spaceName, turnId)] = reactionName;
  }

  /// Typing indicator placeholder text shown while DartClaw processes a message.
  static const typingMessage = '_DartClaw is typing..._';

  /// Sends a typing indicator based on [config.typingIndicatorMode].
  ///
  /// For [TypingIndicatorMode.message], sends a placeholder message and tracks
  /// it for later replacement. For [TypingIndicatorMode.emoji], adds a reaction
  /// to [reactionTargetMessageName] (the inbound message resource name).
  Future<void> sendTypingIndicator({
    required String spaceName,
    required String turnId,
    String? reactionTargetMessageName,
  }) async {
    switch (config.typingIndicatorMode) {
      case TypingIndicatorMode.message:
        final placeholder = await restClient.send(spaceName: spaceName, text: typingMessage);
        final placeholderName = placeholder.messageName;
        if (placeholderName != null) {
          setPlaceholder(spaceName: spaceName, turnId: turnId, messageName: placeholderName);
        }
      case TypingIndicatorMode.emoji:
        final target = reactionTargetMessageName;
        if (target != null && target.isNotEmpty) {
          final reactionName = await restClient.addReaction(target, typingIndicatorEmoji);
          if (reactionName != null) {
            setReaction(spaceName: spaceName, turnId: turnId, reactionName: reactionName);
          }
        }
      case TypingIndicatorMode.disabled:
        break;
    }
  }

  @override
  bool ownsJid(String jid) => jid.startsWith('spaces/');

  @override
  List<ChannelResponse> formatResponse(String text) {
    final chunks = chunkNativeChatMarkup(markdownToGoogleChat(text.trimLeft()), maxSize: 4000);
    return [
      for (final entry in chunks.asMap().entries)
        ChannelResponse(text: entry.value, metadata: {_firstChunkMetadataKey: entry.key == 0}),
    ];
  }

  @override
  Future<void> disconnect() async {
    _log.info('Disconnecting Google Chat channel');
    await restClient.close();
    _pendingPlaceholders.clear();
    _pendingReactions.clear();
    _log.info('Google Chat channel disconnected');
  }

  String _fallbackText(ChannelResponse response) {
    if (response.text.isNotEmpty) {
      return response.text;
    }
    return response.structuredPayload == null ? '' : 'DartClaw sent an update.';
  }

  String? _nonEmptyString(Object? value) {
    if (value is! String) {
      return null;
    }
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  /// Prepends `*@Sender* – ` to the response text when quote-reply is
  /// enabled (`sender` or `native`) and the context is a multi-user space.
  ///
  /// Skips DMs (no ambiguity). GROUP_CHAT is included for `sender` mode
  /// (useful in group conversations) but excluded for `native` (API limitation).
  String _withSenderAttribution(ChannelResponse response, String text) {
    if (text.isEmpty) return text;
    if (config.quoteReplyMode == QuoteReplyMode.disabled) return text;
    final spaceType = response.metadata['spaceType'] as String?;
    if (spaceType == 'DM') return text;
    final senderDisplayName = _nonEmptyString(response.metadata['senderDisplayName']);
    if (senderDisplayName == null) return text;
    return '*@$senderDisplayName* – $text';
  }

  /// Returns the message name for native API-level quoting, or null.
  String? _nativeQuotedMessageName(ChannelResponse response) {
    if (config.quoteReplyMode != QuoteReplyMode.native) return null;
    final spaceType = response.metadata['spaceType'] as String?;
    if (spaceType == 'DM' || spaceType == 'GROUP_CHAT') return null;
    final replyToMessageId = response.replyToMessageId;
    if (replyToMessageId != null && messageNamePattern.hasMatch(replyToMessageId)) {
      return replyToMessageId;
    }
    final sourceMessageId = response.metadata[sourceMessageIdMetadataKey] as String?;
    if (sourceMessageId != null && messageNamePattern.hasMatch(sourceMessageId)) {
      return sourceMessageId;
    }
    final messageName = response.metadata['messageName'] as String?;
    if (messageName != null && messageNamePattern.hasMatch(messageName)) {
      return messageName;
    }
    return null;
  }

  String? _quotedMessageLastUpdateTime(ChannelResponse response, String? quotedMessageName) {
    if (quotedMessageName == null) return null;
    final lastUpdateTime = response.metadata['messageCreateTime'] as String?;
    if (lastUpdateTime == null || lastUpdateTime.isEmpty) return null;
    return lastUpdateTime;
  }

  String _placeholderKey(String spaceName, String turnId) => '$spaceName::$turnId';
}
