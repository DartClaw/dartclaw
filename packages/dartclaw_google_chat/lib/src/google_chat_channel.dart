import 'package:dartclaw_core/dartclaw_core.dart'
    show
        Channel,
        ChannelManager,
        ChannelResponse,
        ChannelType,
        DmAccessController,
        MentionGating,
        chunkText,
        sourceMessageIdMetadataKey;
import 'package:logging/logging.dart';

import 'google_chat_config.dart';
import 'google_chat_rest_client.dart' show GoogleChatRestClient, messageNamePattern, typingIndicatorEmoji;
import 'markdown_converter.dart';

const _firstChunkMetadataKey = 'isFirstChunk';

// Precompiled RegExp patterns for HTML-to-plain-text stripping.
final _brTagPattern = RegExp(r'<br\s*/?>', caseSensitive: false);
final _htmlTagPattern = RegExp(r'<[^>]+>');

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
  GoogleChatChannel({
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
      final name = await restClient.sendCard(
        recipientJid,
        structuredPayload,
        quotedMessageName: nativeQuoteName,
        quotedMessageLastUpdateTime: nativeQuoteLastUpdateTime,
      );
      if (name != null) {
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
        final sent = await restClient.sendMessageWithQuoteFallback(
          recipientJid,
          fallbackText,
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
      await restClient.sendMessageWithQuoteFallback(
        recipientJid,
        fallbackText,
        quotedMessageName: nativeQuoteName,
        quotedMessageLastUpdateTime: nativeQuoteLastUpdateTime,
        textWithoutQuote: displayText,
      );
      return;
    }

    await restClient.sendMessage(recipientJid, displayText);
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
      final result = await restClient.sendCardInThread(recipientJid, structuredPayload, threadKey: threadKey);
      if (result.messageName != null) {
        return result.threadName;
      }
      _log.warning('Google Chat threaded card send failed for $recipientJid, falling back to plain text');
    }

    if (fallbackText.isEmpty) {
      return null;
    }

    final result = await restClient.sendMessageInThread(recipientJid, fallbackText, threadKey: threadKey);
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
      final name = await restClient.sendCardToThread(recipientJid, structuredPayload, threadName: threadName);
      if (name != null) {
        return;
      }
      _log.warning('Google Chat thread-name card send failed for $recipientJid, falling back to plain text');
    }

    if (fallbackText.isEmpty) {
      return;
    }

    await restClient.sendMessageToThread(recipientJid, fallbackText, threadName: threadName);
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
        final placeholderName = await restClient.sendMessage(spaceName, typingMessage);
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
    final chunks = chunkText(markdownToGoogleChat(text.trimLeft()), maxSize: 4000);
    return [
      for (final entry in chunks.asMap().entries)
        ChannelResponse(
          text: entry.value,
          metadata: {_firstChunkMetadataKey: entry.key == 0},
        ),
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

    final structuredPayload = response.structuredPayload;
    if (structuredPayload == null) {
      return '';
    }

    final synthesized = _synthesizeFallbackText(structuredPayload);
    if (synthesized.isNotEmpty) {
      return synthesized;
    }

    return 'DartClaw sent an update.';
  }

  String _synthesizeFallbackText(Map<String, dynamic> structuredPayload) {
    final cards = structuredPayload['cardsV2'];
    if (cards is! List || cards.isEmpty) {
      return '';
    }

    final cardEntry = cards.first;
    if (cardEntry is! Map) {
      return '';
    }

    final card = cardEntry['card'];
    if (card is! Map) {
      return '';
    }

    final parts = <String>[];
    final header = card['header'];
    if (header is Map) {
      final title = _nonEmptyString(header['title']);
      final subtitle = _nonEmptyString(header['subtitle']);
      if (title != null) {
        parts.add(title);
      }
      if (subtitle != null) {
        parts.add(subtitle);
      }
    }

    final sections = card['sections'];
    if (sections is List) {
      for (final section in sections) {
        if (section is! Map) {
          continue;
        }
        final widgets = section['widgets'];
        if (widgets is! List) {
          continue;
        }
        for (final widget in widgets) {
          if (widget is! Map) {
            continue;
          }
          final textParagraph = widget['textParagraph'];
          if (textParagraph is! Map) {
            continue;
          }
          final text = _nonEmptyString(textParagraph['text']);
          if (text == null) {
            continue;
          }
          parts.add(_plainTextFromMarkup(text));
        }
      }
    }

    return parts.where((part) => part.isNotEmpty).join('\n');
  }

  String _plainTextFromMarkup(String value) {
    return value
        .replaceAll(_brTagPattern, '\n')
        .replaceAll(_htmlTagPattern, '')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', '\'')
        .replaceAll('&amp;', '&')
        .trim();
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
