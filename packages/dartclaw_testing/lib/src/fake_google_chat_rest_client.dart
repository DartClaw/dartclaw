import 'dart:convert';

import 'package:dartclaw_google_chat/dartclaw_google_chat.dart';
import 'package:http/http.dart' as http;

typedef GoogleChatSendMessageCallback =
    Future<String?> Function(
      String spaceName,
      String text, {
      String? quotedMessageName,
      String? quotedMessageLastUpdateTime,
    });

typedef GoogleChatSendMessageWithQuoteFallbackCallback =
    Future<({String? messageName, bool usedQuotedMessageMetadata})> Function(
      String spaceName,
      String text, {
      String? quotedMessageName,
      String? quotedMessageLastUpdateTime,
      String? textWithoutQuote,
      bool fallbackOnQuoteFailure,
    });

typedef GoogleChatSendCardCallback =
    Future<String?> Function(
      String spaceName,
      Map<String, dynamic> cardPayload, {
      String? quotedMessageName,
      String? quotedMessageLastUpdateTime,
    });

typedef GoogleChatEditMessageCallback = Future<bool> Function(String messageName, String newText);

typedef GoogleChatDeleteMessageCallback = Future<bool> Function(String messageName);

typedef GoogleChatAddReactionCallback = Future<String?> Function(String messageName, String emoji);

typedef GoogleChatRemoveReactionCallback = Future<bool> Function(String reactionName);

typedef GoogleChatGetMemberDisplayNameCallback = Future<String?> Function(String spaceName, String memberName);

typedef GoogleChatGetSpaceCallback = Future<({String name, String? displayName})?> Function(String spaceName);

typedef GoogleChatListSpacesCallback = Future<List<String>> Function();

typedef GoogleChatDownloadMediaCallback = Future<List<int>?> Function(String resourceName);

/// Recording [GoogleChatRestClient] fake with configurable operation callbacks.
class FakeGoogleChatRestClient extends GoogleChatRestClient {
  FakeGoogleChatRestClient({
    this.quoteFallbackUsesQuotedMessageMetadata = true,
    this.failQuotedSend = false,
    this.failCard = false,
    this.failEdit = false,
    this.failDelete = false,
    this.failAddReaction = false,
    this.failRemoveReaction = false,
    this.onSendMessage,
    this.onSendMessageWithQuoteFallback,
    this.onSendCard,
    this.onEditMessage,
    this.onDeleteMessage,
    this.onAddReaction,
    this.onRemoveReaction,
    this.onGetMemberDisplayName,
    this.onGetSpace,
    this.onListSpaces,
    this.onDownloadMedia,
    this.onTestConnection,
    this.onClose,
  }) : super(authClient: _NoopHttpClient());

  bool quoteFallbackUsesQuotedMessageMetadata;
  bool failQuotedSend;
  bool failCard;
  bool failEdit;
  bool failDelete;
  bool failAddReaction;
  bool failRemoveReaction;

  final GoogleChatSendMessageCallback? onSendMessage;
  final GoogleChatSendMessageWithQuoteFallbackCallback? onSendMessageWithQuoteFallback;
  final GoogleChatSendCardCallback? onSendCard;
  final GoogleChatEditMessageCallback? onEditMessage;
  final GoogleChatDeleteMessageCallback? onDeleteMessage;
  final GoogleChatAddReactionCallback? onAddReaction;
  final GoogleChatRemoveReactionCallback? onRemoveReaction;
  final GoogleChatGetMemberDisplayNameCallback? onGetMemberDisplayName;
  final GoogleChatGetSpaceCallback? onGetSpace;
  final GoogleChatListSpacesCallback? onListSpaces;
  final GoogleChatDownloadMediaCallback? onDownloadMedia;
  final Future<void> Function()? onTestConnection;
  final Future<void> Function()? onClose;

  final List<(String, String)> sentMessages = [];
  final List<(String, Map<String, dynamic>)> sentCards = [];
  final List<(String, String)> editedMessages = [];
  final List<String> deletedMessages = [];
  final List<(String, String)> addedReactions = [];
  final List<String> removedReactions = [];
  final List<(String, String)> getMemberDisplayNameCalls = [];
  final List<String> getSpaceCalls = [];
  final List<String> downloadMediaCalls = [];
  final List<
    ({
      String spaceName,
      String text,
      String? quotedMessageName,
      String? quotedMessageLastUpdateTime,
      String? textWithoutQuote,
    })
  >
  quoteFallbackCalls = [];

  final Map<String, String?> memberDisplayNames = {};
  final Map<String, ({String name, String? displayName})?> spaces = {};
  final Map<String, List<int>?> downloadedMedia = {};
  List<String> listedSpaces = const [];

  bool closeCalled = false;
  bool testConnectionCalled = false;
  String? lastQuotedMessageName;
  String? lastQuotedMessageLastUpdateTime;

  int _messageCounter = 0;
  int _reactionCounter = 0;

  @override
  Future<void> close() async {
    closeCalled = true;
    await onClose?.call();
  }

  @override
  Future<void> testConnection() async {
    testConnectionCalled = true;
    await onTestConnection?.call();
  }

  @override
  Future<String?> sendMessage(
    String spaceName,
    String text, {
    String? quotedMessageName,
    String? quotedMessageLastUpdateTime,
  }) async {
    sentMessages.add((spaceName, text));
    lastQuotedMessageName = quotedMessageName;
    lastQuotedMessageLastUpdateTime = quotedMessageLastUpdateTime;
    final callback = onSendMessage;
    if (callback != null) {
      return callback(
        spaceName,
        text,
        quotedMessageName: quotedMessageName,
        quotedMessageLastUpdateTime: quotedMessageLastUpdateTime,
      );
    }
    return _nextMessageName(spaceName);
  }

  @override
  Future<({String? messageName, bool usedQuotedMessageMetadata})> sendMessageWithQuoteFallback(
    String spaceName,
    String text, {
    String? quotedMessageName,
    String? quotedMessageLastUpdateTime,
    String? textWithoutQuote,
    bool fallbackOnQuoteFailure = true,
  }) async {
    quoteFallbackCalls.add((
      spaceName: spaceName,
      text: text,
      quotedMessageName: quotedMessageName,
      quotedMessageLastUpdateTime: quotedMessageLastUpdateTime,
      textWithoutQuote: textWithoutQuote,
    ));
    final callback = onSendMessageWithQuoteFallback;
    if (callback != null) {
      return callback(
        spaceName,
        text,
        quotedMessageName: quotedMessageName,
        quotedMessageLastUpdateTime: quotedMessageLastUpdateTime,
        textWithoutQuote: textWithoutQuote,
        fallbackOnQuoteFailure: fallbackOnQuoteFailure,
      );
    }

    if (failQuotedSend && quotedMessageName != null) {
      if (!fallbackOnQuoteFailure) {
        return (messageName: null, usedQuotedMessageMetadata: false);
      }
      sentMessages.add((spaceName, textWithoutQuote ?? text));
      lastQuotedMessageName = null;
      lastQuotedMessageLastUpdateTime = null;
      return (messageName: _nextMessageName(spaceName), usedQuotedMessageMetadata: false);
    }

    final usedQuotedMessageMetadata = quoteFallbackUsesQuotedMessageMetadata && quotedMessageName != null;
    lastQuotedMessageName = usedQuotedMessageMetadata ? quotedMessageName : null;
    lastQuotedMessageLastUpdateTime = usedQuotedMessageMetadata ? quotedMessageLastUpdateTime : null;
    sentMessages.add((spaceName, usedQuotedMessageMetadata ? text : (textWithoutQuote ?? text)));
    return (messageName: _nextMessageName(spaceName), usedQuotedMessageMetadata: usedQuotedMessageMetadata);
  }

  @override
  Future<String?> sendCard(
    String spaceName,
    Map<String, dynamic> cardPayload, {
    String? quotedMessageName,
    String? quotedMessageLastUpdateTime,
  }) async {
    sentCards.add((spaceName, Map<String, dynamic>.from(cardPayload)));
    lastQuotedMessageName = quotedMessageName;
    lastQuotedMessageLastUpdateTime = quotedMessageLastUpdateTime;
    final callback = onSendCard;
    if (callback != null) {
      return callback(
        spaceName,
        cardPayload,
        quotedMessageName: quotedMessageName,
        quotedMessageLastUpdateTime: quotedMessageLastUpdateTime,
      );
    }
    if (failCard) {
      return null;
    }
    return _nextMessageName(spaceName, kind: 'card');
  }

  @override
  Future<bool> editMessage(String messageName, String newText) async {
    editedMessages.add((messageName, newText));
    final callback = onEditMessage;
    if (callback != null) {
      return callback(messageName, newText);
    }
    return !failEdit;
  }

  @override
  Future<bool> deleteMessage(String messageName) async {
    deletedMessages.add(messageName);
    final callback = onDeleteMessage;
    if (callback != null) {
      return callback(messageName);
    }
    return !failDelete;
  }

  @override
  Future<String?> addReaction(String messageName, String emoji) async {
    addedReactions.add((messageName, emoji));
    final callback = onAddReaction;
    if (callback != null) {
      return callback(messageName, emoji);
    }
    if (failAddReaction) {
      return null;
    }
    _reactionCounter += 1;
    return '$messageName/reactions/$_reactionCounter';
  }

  @override
  Future<bool> removeReaction(String reactionName) async {
    removedReactions.add(reactionName);
    final callback = onRemoveReaction;
    if (callback != null) {
      return callback(reactionName);
    }
    return !failRemoveReaction;
  }

  @override
  Future<String?> getMemberDisplayName(String spaceName, String memberName) async {
    getMemberDisplayNameCalls.add((spaceName, memberName));
    final callback = onGetMemberDisplayName;
    if (callback != null) {
      return callback(spaceName, memberName);
    }
    return memberDisplayNames[memberName];
  }

  @override
  Future<({String name, String? displayName})?> getSpace(String spaceName) async {
    getSpaceCalls.add(spaceName);
    final callback = onGetSpace;
    if (callback != null) {
      return callback(spaceName);
    }
    return spaces[spaceName];
  }

  @override
  Future<List<String>> listSpaces() async {
    final callback = onListSpaces;
    if (callback != null) {
      return callback();
    }
    return List<String>.from(listedSpaces);
  }

  @override
  Future<List<int>?> downloadMedia(String resourceName) async {
    downloadMediaCalls.add(resourceName);
    final callback = onDownloadMedia;
    if (callback != null) {
      return callback(resourceName);
    }
    return downloadedMedia[resourceName];
  }

  String _nextMessageName(String spaceName, {String kind = 'message'}) {
    _messageCounter += 1;
    return '$spaceName/messages/$kind-$_messageCounter';
  }
}

class _NoopHttpClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    final stream = Stream<List<int>>.fromIterable(<List<int>>[utf8.encode('{}')]);
    return Future<http.StreamedResponse>.value(http.StreamedResponse(stream, 200));
  }
}
