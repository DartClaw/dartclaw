import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

/// Default Google Chat REST API base URL.
const chatApiBase = 'https://chat.googleapis.com/v1';

final _spaceNamePattern = RegExp(r'^spaces/[^/]+$');
final _userNamePattern = RegExp(r'^users/[^/]+$');

/// Matches a valid Google Chat message resource name (`spaces/*/messages/*`).
final messageNamePattern = RegExp(r'^spaces/[^/]+/messages/[^/]+$');
final _resourceNamePattern = RegExp(r'^spaces/[^/]+/messages/[^/]+/attachments/[^/]+$');
final _reactionNamePattern = RegExp(r'^spaces/[^/]+/messages/[^/]+/reactions/[^/]+$');

/// Eyes emoji used as a typing indicator reaction in Google Chat.
const typingIndicatorEmoji = '\u{1F440}';

/// Exception thrown when the Google Chat API returns an unusable response.
class GoogleChatApiException implements Exception {
  /// Human-readable error message.
  final String message;

  /// Optional HTTP status associated with the failure.
  final int? statusCode;

  /// Optional lower-level cause object.
  final Object? cause;

  /// Creates a Google Chat API exception.
  const GoogleChatApiException(this.message, {this.statusCode, this.cause});

  @override
  String toString() => 'GoogleChatApiException($message${statusCode == null ? '' : ', statusCode: $statusCode'})';
}

/// Thin authenticated client for Google Chat REST endpoints used by DartClaw.
class GoogleChatRestClient {
  final http.Client _client;
  final http.Client? _reactionClient;
  final String _apiBase;
  final Future<void> Function(Duration) _delay;
  final Map<String, _SpaceWriteQueue> _spaceQueues = {};
  final Logger _log = Logger('GoogleChatRestClient');

  /// Latches to `true` after a 403 or insufficient-scope error on the first
  /// reaction API call. Once set, [addReaction] returns `null` immediately.
  /// A server restart is required after granting the reactions scope.
  bool _reactionScopeWarned = false;

  /// Creates a REST client backed by an authenticated HTTP client.
  GoogleChatRestClient({
    required http.Client authClient,
    http.Client? reactionClient,
    String? apiBase,
    Future<void> Function(Duration)? delay,
  }) : _client = authClient,
       _reactionClient = reactionClient,
       _apiBase = (apiBase ?? chatApiBase).replaceFirst(RegExp(r'/+$'), ''),
       _delay = delay ?? Future.delayed;

  /// Verifies that the authenticated client can successfully call the Chat API.
  Future<void> testConnection() async {
    final uri = Uri.parse('$_apiBase/spaces?pageSize=1');
    try {
      final response = await _client.get(uri);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        _log.warning('Google Chat API test connection failed with HTTP ${response.statusCode}');
        throw GoogleChatApiException('Google Chat API test connection failed', statusCode: response.statusCode);
      }
    } on GoogleChatApiException {
      rethrow;
    } on Exception catch (error, stackTrace) {
      _log.warning('Google Chat API test connection request failed', error, stackTrace);
      throw GoogleChatApiException('Google Chat API test connection request failed', cause: error);
    }
  }

  /// Sends a plain-text message to [spaceName] and returns its resource name.
  ///
  /// When [quotedMessageName] is provided, the response quotes the referenced
  /// message (Google Chat "reply" UI). Must be a valid message resource name
  /// (`spaces/*/messages/*`).
  Future<String?> sendMessage(
    String spaceName,
    String text, {
    String? quotedMessageName,
    String? quotedMessageLastUpdateTime,
  }) async {
    final result = await sendMessageWithQuoteFallback(
      spaceName,
      text,
      quotedMessageName: quotedMessageName,
      quotedMessageLastUpdateTime: quotedMessageLastUpdateTime,
    );
    return result.messageName;
  }

  /// Sends a plain-text message and reports whether native quoting was applied.
  ///
  /// When a quoted send fails with 400/403 and [fallbackOnQuoteFailure] is
  /// `true` (default), Google Chat is retried without `quotedMessageMetadata`
  /// using [textWithoutQuote] when provided. When `false`, no retry is
  /// attempted — the caller can handle the fallback (e.g. editing an existing
  /// placeholder message instead of sending a new one).
  Future<({String? messageName, bool usedQuotedMessageMetadata})> sendMessageWithQuoteFallback(
    String spaceName,
    String text, {
    String? quotedMessageName,
    String? quotedMessageLastUpdateTime,
    String? textWithoutQuote,
    bool fallbackOnQuoteFailure = true,
  }) async {
    if (!_spaceNamePattern.hasMatch(spaceName)) {
      _log.warning('Rejected Google Chat send for invalid space name "$spaceName"');
      return (messageName: null, usedQuotedMessageMetadata: false);
    }

    return _queueFor(spaceName).enqueue(() async {
      try {
        final quotedMessageMetadata = quotedMessageName == null
            ? null
            : _quotedMessageMetadata(quotedMessageName, lastUpdateTime: quotedMessageLastUpdateTime);
        if (quotedMessageMetadata != null) {
          _log.fine('Google Chat quotedMessageMetadata payload: $quotedMessageMetadata');
        }
        final response = await _client.post(
          Uri.parse('$_apiBase/$spaceName/messages'),
          headers: const {'content-type': 'application/json'},
          body: jsonEncode({'text': text, 'quotedMessageMetadata': ?quotedMessageMetadata}),
        );
        if (response.statusCode < 200 || response.statusCode >= 300) {
          // Retry without quote if the quoted message was rejected (400) or
          // the bot lacks permission to quote it (403).
          if ((response.statusCode == 400 || response.statusCode == 403) && quotedMessageName != null) {
            if (!fallbackOnQuoteFailure) {
              _log.warning('Google Chat quoted send failed (${response.statusCode}) — no fallback requested');
              return (messageName: null, usedQuotedMessageMetadata: false);
            }
            _log.warning('Google Chat quoted send failed (${response.statusCode}) — retrying without quote');
            final retry = await _client.post(
              Uri.parse('$_apiBase/$spaceName/messages'),
              headers: const {'content-type': 'application/json'},
              body: jsonEncode({'text': textWithoutQuote ?? text}),
            );
            if (retry.statusCode >= 200 && retry.statusCode < 300) {
              final decoded = jsonDecode(retry.body);
              return (
                messageName: (decoded is Map<String, dynamic>) ? decoded['name'] as String? : null,
                usedQuotedMessageMetadata: false,
              );
            }
          }
          _log.warning('Google Chat send failed for $spaceName with HTTP ${response.statusCode} — ${response.body}');
          return (messageName: null, usedQuotedMessageMetadata: false);
        }

        final decoded = jsonDecode(response.body);
        if (decoded is! Map<String, dynamic>) {
          _log.warning('Google Chat send returned invalid JSON for $spaceName');
          return (messageName: null, usedQuotedMessageMetadata: false);
        }
        return (messageName: decoded['name'] as String?, usedQuotedMessageMetadata: quotedMessageMetadata != null);
      } on Exception catch (error, stackTrace) {
        _log.warning('Google Chat send failed for $spaceName', error, stackTrace);
        return (messageName: null, usedQuotedMessageMetadata: false);
      }
    });
  }

  /// Fetches metadata for a Google Chat space.
  ///
  /// Returns the resource name and display name on success, or `null` when the
  /// request fails or the response is invalid.
  Future<({String name, String? displayName})?> getSpace(String spaceName) async {
    if (!_spaceNamePattern.hasMatch(spaceName)) {
      _log.warning('Rejected Google Chat getSpace for invalid space name "$spaceName"');
      return null;
    }

    try {
      final response = await _client.get(Uri.parse('$_apiBase/$spaceName'));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        _log.warning('Google Chat getSpace failed for $spaceName with HTTP ${response.statusCode}');
        return null;
      }

      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        _log.warning('Google Chat getSpace returned invalid JSON for $spaceName');
        return null;
      }

      final name = decoded['name'] as String?;
      if (name == null || name.isEmpty) {
        _log.warning('Google Chat getSpace returned no name for $spaceName');
        return null;
      }

      final displayName = decoded['displayName'] as String?;
      return (name: name, displayName: displayName);
    } on Exception catch (error, stackTrace) {
      _log.warning('Google Chat getSpace failed for $spaceName', error, stackTrace);
      return null;
    }
  }

  /// Fetches the display name of a space member.
  ///
  /// Calls `GET /v1/{spaceName}/members/{memberId}` and returns the
  /// member's display name, or `null` when the request fails or the response
  /// is invalid. The [memberName] should be in `users/{id}` format — the
  /// `users/` prefix is stripped to form the API member resource path.
  Future<String?> getMemberDisplayName(String spaceName, String memberName) async {
    if (!_spaceNamePattern.hasMatch(spaceName)) {
      _log.warning('Rejected getMemberDisplayName for invalid space name "$spaceName"');
      return null;
    }
    if (!_userNamePattern.hasMatch(memberName)) {
      _log.warning('Rejected getMemberDisplayName for invalid member name "$memberName"');
      return null;
    }

    // Google Chat members API uses spaces/{space}/members/{id} — strip
    // the users/ prefix from the sender JID to form the member resource path.
    final memberId = memberName.replaceFirst('users/', '');

    try {
      final response = await _client.get(Uri.parse('$_apiBase/$spaceName/members/$memberId'));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        _log.warning(
          'Google Chat getMemberDisplayName failed for $memberName in $spaceName with HTTP ${response.statusCode}',
        );
        return null;
      }

      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        _log.warning('Google Chat getMemberDisplayName returned invalid JSON for $memberName');
        return null;
      }

      final member = decoded['member'] as Map<String, dynamic>?;
      return (member ?? decoded)['displayName'] as String?;
    } on Exception catch (error, stackTrace) {
      _log.warning('Google Chat getMemberDisplayName failed for $memberName in $spaceName', error, stackTrace);
      return null;
    }
  }

  /// Lists named Google Chat spaces the bot is a member of.
  ///
  /// Returns only `spaces[].name` values for `SPACE` resources. Returns `[]`
  /// if the API response is invalid or the request fails.
  Future<List<String>> listSpaces() async {
    final spaces = <String>[];
    String? nextPageToken;

    // Keep discovery all-or-nothing. If any page fails, discard accumulated
    // results so a later reconcile retries the full space list from scratch.
    try {
      do {
        final uri = Uri.parse('$_apiBase/spaces').replace(
          queryParameters: {
            'pageSize': '100',
            'filter': 'spaceType = "SPACE"',
            if (nextPageToken != null && nextPageToken.isNotEmpty) 'pageToken': nextPageToken,
          },
        );
        final response = await _client.get(uri);
        if (response.statusCode < 200 || response.statusCode >= 300) {
          _log.warning('Google Chat listSpaces failed with HTTP ${response.statusCode}');
          return [];
        }

        final decoded = jsonDecode(response.body);
        if (decoded is! Map<String, dynamic>) {
          _log.warning('Google Chat listSpaces returned invalid JSON');
          return [];
        }

        final rawSpaces = decoded['spaces'];
        if (rawSpaces is! List) {
          _log.warning('Google Chat listSpaces response missing spaces list');
          return [];
        }

        for (final rawSpace in rawSpaces) {
          if (rawSpace is! Map<String, dynamic>) {
            continue;
          }
          final name = rawSpace['name'] as String?;
          if (name != null && name.isNotEmpty) {
            spaces.add(name);
          }
        }

        nextPageToken = decoded['nextPageToken'] as String?;
      } while (nextPageToken != null && nextPageToken.isNotEmpty);

      _log.info('Google Chat listSpaces succeeded: ${spaces.length} spaces');
      return spaces;
    } on Exception catch (error, stackTrace) {
      _log.warning('Google Chat listSpaces failed', error, stackTrace);
      return [];
    }
  }

  /// Sends a structured Cards v2 message to [spaceName].
  ///
  /// When [quotedMessageName] is provided, the card quotes the referenced
  /// message.
  Future<String?> sendCard(
    String spaceName,
    Map<String, dynamic> cardPayload, {
    String? quotedMessageName,
    String? quotedMessageLastUpdateTime,
  }) async {
    if (!_spaceNamePattern.hasMatch(spaceName)) {
      _log.warning('Rejected Google Chat card send for invalid space name "$spaceName"');
      return null;
    }

    return _queueFor(spaceName).enqueue<String?>(() async {
      try {
        final quotedMessageMetadata = quotedMessageName == null
            ? null
            : _quotedMessageMetadata(quotedMessageName, lastUpdateTime: quotedMessageLastUpdateTime);
        if (quotedMessageMetadata != null) {
          _log.fine('Google Chat quotedMessageMetadata payload: $quotedMessageMetadata');
        }
        final response = await _client.post(
          Uri.parse('$_apiBase/$spaceName/messages'),
          headers: const {'content-type': 'application/json'},
          body: jsonEncode({...cardPayload, 'quotedMessageMetadata': ?quotedMessageMetadata}),
        );
        if (response.statusCode < 200 || response.statusCode >= 300) {
          if ((response.statusCode == 400 || response.statusCode == 403) && quotedMessageName != null) {
            _log.warning('Google Chat quoted card send failed (${response.statusCode}) — retrying without quote');
            final retry = await _client.post(
              Uri.parse('$_apiBase/$spaceName/messages'),
              headers: const {'content-type': 'application/json'},
              body: jsonEncode(cardPayload),
            );
            if (retry.statusCode >= 200 && retry.statusCode < 300) {
              final decoded = jsonDecode(retry.body);
              return (decoded is Map<String, dynamic>) ? decoded['name'] as String? : null;
            }
          }
          _log.warning(
            'Google Chat card send failed for $spaceName with HTTP ${response.statusCode} — ${response.body}',
          );
          return null;
        }

        final decoded = jsonDecode(response.body);
        if (decoded is! Map<String, dynamic>) {
          _log.warning('Google Chat card send returned invalid JSON for $spaceName');
          return null;
        }
        return decoded['name'] as String?;
      } on Exception catch (error, stackTrace) {
        _log.warning('Google Chat card send failed for $spaceName', error, stackTrace);
        return null;
      }
    });
  }

  /// Edits an existing Google Chat message in place.
  Future<bool> editMessage(String messageName, String newText) async {
    if (!messageNamePattern.hasMatch(messageName)) {
      _log.warning('Rejected Google Chat edit for invalid message name "$messageName"');
      return false;
    }

    final messageIndex = messageName.indexOf('/messages/');
    final spaceName = messageName.substring(0, messageIndex);

    return _queueFor(spaceName).enqueue<bool>(() async {
      try {
        final response = await _client.patch(
          Uri.parse('$_apiBase/$messageName?updateMask=text'),
          headers: const {'content-type': 'application/json'},
          body: jsonEncode({'text': newText}),
        );
        if (response.statusCode < 200 || response.statusCode >= 300) {
          _log.warning('Google Chat edit failed for $messageName with HTTP ${response.statusCode}');
          return false;
        }
        return true;
      } on Exception catch (error, stackTrace) {
        _log.warning('Google Chat edit failed for $messageName', error, stackTrace);
        return false;
      }
    });
  }

  /// Deletes a Google Chat message. Returns true on success or 404.
  Future<bool> deleteMessage(String messageName) async {
    if (!messageNamePattern.hasMatch(messageName)) {
      _log.warning('Rejected Google Chat delete for invalid message name "$messageName"');
      return false;
    }

    final messageIndex = messageName.indexOf('/messages/');
    final spaceName = messageName.substring(0, messageIndex);

    return _queueFor(spaceName).enqueue<bool>(() async {
      try {
        final response = await _client.delete(Uri.parse('$_apiBase/$messageName'));
        if (response.statusCode == 404) {
          return true;
        }
        if (response.statusCode < 200 || response.statusCode >= 300) {
          _log.warning('Google Chat delete failed for $messageName with HTTP ${response.statusCode}');
          return false;
        }
        return true;
      } on Exception catch (error, stackTrace) {
        _log.warning('Google Chat delete failed for $messageName', error, stackTrace);
        return false;
      }
    });
  }

  /// Adds an emoji reaction to a message. Returns the reaction resource name.
  ///
  Future<String?> addReaction(String messageName, String emoji) async {
    if (_reactionScopeWarned) return null;

    if (!messageNamePattern.hasMatch(messageName)) {
      _log.warning('Rejected Google Chat addReaction for invalid message name "$messageName"');
      return null;
    }

    try {
      final response = await (_reactionClient ?? _client).post(
        Uri.parse('$_apiBase/$messageName/reactions'),
        headers: const {'content-type': 'application/json'},
        body: jsonEncode({
          'emoji': {'unicode': emoji},
        }),
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        if (response.statusCode == 403) {
          _reactionScopeWarned = true;
          _log.warning(
            'Google Chat addReaction: insufficient scope — emoji typing indicator disabled for this session',
          );
          return null;
        }
        _log.warning('Google Chat addReaction failed for $messageName with HTTP ${response.statusCode}');
        return null;
      }
      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        _log.warning('Google Chat addReaction returned invalid JSON for $messageName');
        return null;
      }
      return decoded['name'] as String?;
    } on Exception catch (error, stackTrace) {
      // googleapis_auth throws AccessDeniedException for insufficient scope
      // instead of returning HTTP 403.
      if (error.toString().contains('insufficient_scope') || error.toString().contains('Access was denied')) {
        _reactionScopeWarned = true;
        _log.warning('Google Chat addReaction: insufficient scope — emoji typing indicator disabled for this session');
        return null;
      }
      _log.warning('Google Chat addReaction failed for $messageName', error, stackTrace);
      return null;
    }
  }

  /// Removes an emoji reaction by resource name. Returns true on success or 404.
  Future<bool> removeReaction(String reactionName) async {
    if (!_reactionNamePattern.hasMatch(reactionName)) {
      _log.warning('Rejected Google Chat removeReaction for invalid reaction name "$reactionName"');
      return false;
    }

    try {
      final response = await (_reactionClient ?? _client).delete(Uri.parse('$_apiBase/$reactionName'));
      if (response.statusCode == 404) {
        return true;
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        _log.warning('Google Chat removeReaction failed for $reactionName with HTTP ${response.statusCode}');
        return false;
      }
      return true;
    } on Exception catch (error, stackTrace) {
      _log.warning('Google Chat removeReaction failed for $reactionName', error, stackTrace);
      return false;
    }
  }

  /// Downloads binary attachment data for a Google Chat media resource.
  Future<List<int>?> downloadMedia(String resourceName) async {
    if (!_resourceNamePattern.hasMatch(resourceName)) {
      _log.warning('Rejected Google Chat media download for invalid resource "$resourceName"');
      return null;
    }

    try {
      final response = await _client.get(Uri.parse('$_apiBase/media/$resourceName?alt=media'));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        _log.warning('Google Chat media download failed for $resourceName with HTTP ${response.statusCode}');
        return null;
      }
      return response.bodyBytes;
    } on Exception catch (error, stackTrace) {
      _log.warning('Google Chat media download failed for $resourceName', error, stackTrace);
      return null;
    }
  }

  /// Sends a text message to [spaceName] in a new or existing thread.
  ///
  /// [threadKey] is used with `messageReplyOption:
  /// REPLY_MESSAGE_FALLBACK_TO_NEW_THREAD` to create a new thread on the first
  /// send and reply to it on subsequent sends with the same key.
  ///
  /// Returns the message name and server-assigned thread name from the API
  /// response. Both fields are `null` on failure.
  Future<({String? messageName, String? threadName})> sendMessageInThread(
    String spaceName,
    String text, {
    required String threadKey,
  }) async {
    if (!_spaceNamePattern.hasMatch(spaceName)) {
      _log.warning('Rejected Google Chat threaded send for invalid space name "$spaceName"');
      return (messageName: null, threadName: null);
    }

    return _queueFor(spaceName).enqueue(() async {
      try {
        final response = await _client.post(
          Uri.parse('$_apiBase/$spaceName/messages'),
          headers: const {'content-type': 'application/json'},
          body: jsonEncode({
            'text': text,
            'thread': {'threadKey': threadKey},
            'messageReplyOption': 'REPLY_MESSAGE_FALLBACK_TO_NEW_THREAD',
          }),
        );
        if (response.statusCode < 200 || response.statusCode >= 300) {
          _log.warning('Google Chat threaded send failed for $spaceName with HTTP ${response.statusCode}');
          return (messageName: null, threadName: null);
        }
        final decoded = jsonDecode(response.body);
        if (decoded is! Map<String, dynamic>) {
          return (messageName: null, threadName: null);
        }
        final messageName = decoded['name'] as String?;
        final thread = decoded['thread'];
        final threadName = (thread is Map) ? thread['name'] as String? : null;
        return (messageName: messageName, threadName: threadName);
      } on Exception catch (error, stackTrace) {
        _log.warning('Google Chat threaded send failed for $spaceName', error, stackTrace);
        return (messageName: null, threadName: null);
      }
    });
  }

  /// Sends a structured Cards v2 message to [spaceName] in a new or existing
  /// thread identified by [threadKey].
  ///
  /// Returns the message name and server-assigned thread name from the API
  /// response. Both fields are `null` on failure.
  Future<({String? messageName, String? threadName})> sendCardInThread(
    String spaceName,
    Map<String, dynamic> cardPayload, {
    required String threadKey,
  }) async {
    if (!_spaceNamePattern.hasMatch(spaceName)) {
      _log.warning('Rejected Google Chat threaded card send for invalid space name "$spaceName"');
      return (messageName: null, threadName: null);
    }

    return _queueFor(spaceName).enqueue(() async {
      try {
        final body = Map<String, dynamic>.of(cardPayload)
          ..['thread'] = {'threadKey': threadKey}
          ..['messageReplyOption'] = 'REPLY_MESSAGE_FALLBACK_TO_NEW_THREAD';
        final response = await _client.post(
          Uri.parse('$_apiBase/$spaceName/messages'),
          headers: const {'content-type': 'application/json'},
          body: jsonEncode(body),
        );
        if (response.statusCode < 200 || response.statusCode >= 300) {
          _log.warning('Google Chat threaded card send failed for $spaceName with HTTP ${response.statusCode}');
          return (messageName: null, threadName: null);
        }
        final decoded = jsonDecode(response.body);
        if (decoded is! Map<String, dynamic>) {
          return (messageName: null, threadName: null);
        }
        final messageName = decoded['name'] as String?;
        final thread = decoded['thread'];
        final threadName = (thread is Map) ? thread['name'] as String? : null;
        return (messageName: messageName, threadName: threadName);
      } on Exception catch (error, stackTrace) {
        _log.warning('Google Chat threaded card send failed for $spaceName', error, stackTrace);
        return (messageName: null, threadName: null);
      }
    });
  }

  /// Sends a text message to an existing server-assigned thread.
  Future<String?> sendMessageToThread(String spaceName, String text, {required String threadName}) async {
    if (!_spaceNamePattern.hasMatch(spaceName)) {
      _log.warning('Rejected Google Chat thread-name send for invalid space name "$spaceName"');
      return null;
    }

    return _queueFor(spaceName).enqueue<String?>(() async {
      try {
        final response = await _client.post(
          Uri.parse('$_apiBase/$spaceName/messages'),
          headers: const {'content-type': 'application/json'},
          body: jsonEncode({
            'text': text,
            'thread': {'name': threadName},
          }),
        );
        if (response.statusCode < 200 || response.statusCode >= 300) {
          _log.warning('Google Chat thread-name send failed for $spaceName with HTTP ${response.statusCode}');
          return null;
        }
        final decoded = jsonDecode(response.body);
        if (decoded is! Map<String, dynamic>) {
          return null;
        }
        return decoded['name'] as String?;
      } on Exception catch (error, stackTrace) {
        _log.warning('Google Chat thread-name send failed for $spaceName', error, stackTrace);
        return null;
      }
    });
  }

  /// Sends a structured Cards v2 payload to an existing server-assigned thread.
  Future<String?> sendCardToThread(
    String spaceName,
    Map<String, dynamic> cardPayload, {
    required String threadName,
  }) async {
    if (!_spaceNamePattern.hasMatch(spaceName)) {
      _log.warning('Rejected Google Chat thread-name card send for invalid space name "$spaceName"');
      return null;
    }

    return _queueFor(spaceName).enqueue<String?>(() async {
      try {
        final body = Map<String, dynamic>.of(cardPayload)..['thread'] = {'name': threadName};
        final response = await _client.post(
          Uri.parse('$_apiBase/$spaceName/messages'),
          headers: const {'content-type': 'application/json'},
          body: jsonEncode(body),
        );
        if (response.statusCode < 200 || response.statusCode >= 300) {
          _log.warning('Google Chat thread-name card send failed for $spaceName with HTTP ${response.statusCode}');
          return null;
        }
        final decoded = jsonDecode(response.body);
        if (decoded is! Map<String, dynamic>) {
          return null;
        }
        return decoded['name'] as String?;
      } on Exception catch (error, stackTrace) {
        _log.warning('Google Chat thread-name card send failed for $spaceName', error, stackTrace);
        return null;
      }
    });
  }

  /// Flushes pending writes and closes the underlying HTTP client.
  Future<void> close() async {
    final flushes = _spaceQueues.values.map((queue) => queue.flush()).toList(growable: false);
    _spaceQueues.clear();
    try {
      await Future.wait(flushes).timeout(const Duration(seconds: 2));
    } on TimeoutException {
      _log.warning('Timed out waiting for Google Chat write queues to flush');
    } finally {
      _reactionClient?.close();
      _client.close();
    }
  }

  _SpaceWriteQueue _queueFor(String spaceName) {
    return _spaceQueues.putIfAbsent(spaceName, () => _SpaceWriteQueue(delay: _delay));
  }

  Map<String, String> _quotedMessageMetadata(String name, {String? lastUpdateTime}) {
    final metadata = <String, String>{'name': name};
    if (lastUpdateTime != null) {
      metadata['lastUpdateTime'] = lastUpdateTime;
    }
    return metadata;
  }
}

class _SpaceWriteQueue {
  final Future<void> Function(Duration) _delay;
  final Queue<_QueuedWrite<dynamic>> _pending = Queue<_QueuedWrite<dynamic>>();
  Completer<void> _idle = Completer<void>()..complete();
  bool _draining = false;

  _SpaceWriteQueue({required Future<void> Function(Duration) delay}) : _delay = delay;

  Future<T> enqueue<T>(Future<T> Function() write) {
    if (_pending.isEmpty && _idle.isCompleted) {
      _idle = Completer<void>();
    }
    final completer = Completer<T>();
    _pending.add(_QueuedWrite<T>(run: write, completer: completer));
    if (!_draining) {
      unawaited(_drain());
    }
    return completer.future;
  }

  Future<void> flush() async {
    if (_pending.isEmpty && !_draining) {
      return;
    }
    await _idle.future;
  }

  Future<void> _drain() async {
    _draining = true;
    try {
      while (_pending.isNotEmpty) {
        final entry = _pending.removeFirst();
        try {
          final result = await entry.run();
          entry.completer.complete(result);
        } catch (error, stackTrace) {
          entry.completer.completeError(error, stackTrace);
        }
        if (_pending.isNotEmpty) {
          await _delay(const Duration(seconds: 1));
        }
      }
    } finally {
      _draining = false;
      if (!_idle.isCompleted) {
        _idle.complete();
      }
    }
  }
}

class _QueuedWrite<T> {
  final Future<T> Function() run;
  final Completer<T> completer;

  const _QueuedWrite({required this.run, required this.completer});
}
