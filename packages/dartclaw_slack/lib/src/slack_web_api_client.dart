import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

/// Default Slack Web API base URL.
const slackApiBase = 'https://slack.com/api';

/// [SlackApiException.errorCode] of a file whose body exceeded the download bound.
const slackFileTooLarge = 'file_too_large';

/// [SlackApiException.errorCode] of a download answered with a web page, which is what
/// Slack serves when the bot token lacks the `files:read` scope.
const slackFileScopeMissing = 'files_read_missing';

/// [SlackApiException.errorCode] of any other download that did not deliver the file.
const slackFileUnavailable = 'file_unavailable';

const _minPostInterval = Duration(seconds: 1);
const _maxRetryAfter = Duration(seconds: 60);
const _maxRedirects = 3;

/// A Slack API call that did not succeed.
///
/// The message carries the method and Slack's error code only: never a token,
/// an `Authorization` header, a response URL or the Socket Mode ticket URL.
class SlackApiException implements Exception {
  /// What failed, safe to log.
  final String message;

  /// Slack's `error` code, e.g. `channel_not_found`, when the API answered with one.
  final String? errorCode;

  /// HTTP status of the failed response, when there was one.
  final int? statusCode;

  /// Creates a Slack API exception.
  const new(this.message, {this.errorCode, this.statusCode});

  @override
  String toString() => 'SlackApiException($message)';
}

/// What `auth.test` reports for the bot token: its identity and the scopes
/// Slack granted it (empty when Slack sent none).
typedef SlackAuthInfo = ({String userId, String? botId, List<String> scopes});

/// Thin client for the Slack Web API methods the channel uses.
///
/// Posts to one channel are at least one second apart, and a rate-limited call
/// (HTTP 429) is retried once after its `Retry-After`.
class SlackWebApiClient {
  static final _log = Logger('SlackWebApiClient');

  final String _botToken;
  final String? _appToken;
  final http.Client _client;
  final String _apiBase;
  final Future<void> Function(Duration) _delay;
  final DateTime Function() _now;
  final Map<String, _ChannelPostQueue> _postQueues = {};
  final Map<String, String> _displayNames = {};
  String? _teamId;

  /// The workspace ID the last successful [authTest] reported, or `null` before one.
  String? get teamId => _teamId;

  /// Creates a client for [botToken]; [appToken] is needed only by [openSocketUrl].
  new({
    required String botToken,
    String? appToken,
    http.Client? httpClient,
    String? apiBase,
    Future<void> Function(Duration)? delay,
    DateTime Function()? now,
  }) : _botToken = botToken,
       _appToken = appToken,
       _client = httpClient ?? http.Client(),
       _apiBase = (apiBase ?? slackApiBase).replaceFirst(RegExp(r'/+$'), ''),
       _delay = delay ?? Future.delayed,
       _now = now ?? DateTime.now;

  /// Verifies the bot token and returns the bot's identity and granted scopes.
  ///
  /// The scopes come from the `X-OAuth-Scopes` response header.
  ///
  /// Throws [SlackApiException] when Slack refuses the token; its
  /// [SlackApiException.errorCode] is Slack's error code.
  Future<SlackAuthInfo> authTest() async {
    final (:body, :headers) = await _exchange('auth.test', token: _botToken);
    final userId = body['user_id'];
    if (userId is! String || userId.isEmpty) {
      throw const SlackApiException('Slack API auth.test returned no bot user ID');
    }
    final scopes = [
      for (final scope in (headers['x-oauth-scopes'] ?? '').split(','))
        if (scope.trim().isNotEmpty) scope.trim(),
    ];
    _teamId = switch (body['team_id']) {
      final String id when id.isNotEmpty => id,
      _ => null,
    };
    return (userId: userId, botId: body['bot_id'] as String?, scopes: scopes);
  }

  /// Opens a Socket Mode connection and returns its `wss://` URL.
  ///
  /// The URL carries a single-use ticket that expires within seconds: connect at
  /// once and never log it.
  Future<Uri> openSocketUrl() async {
    final appToken = _appToken;
    if (appToken == null) throw StateError('openSocketUrl needs an app-level token');
    final body = await _call('apps.connections.open', token: appToken);
    final url = body['url'];
    final uri = url is String ? Uri.tryParse(url) : null;
    if (uri == null || !uri.hasScheme) {
      throw const SlackApiException('Slack API apps.connections.open returned no connection URL');
    }
    return uri;
  }

  /// Posts [text] to [channel], into the thread [threadTs] when given, and
  /// returns the posted message's timestamp.
  ///
  /// [blocks] (Block Kit) are sent JSON-encoded beside [text], which Slack then
  /// uses as the notification fallback.
  ///
  /// Posts to one channel are queued at least one second apart.
  Future<String?> postMessage({
    required String channel,
    required String text,
    String? threadTs,
    List<Map<String, dynamic>>? blocks,
  }) {
    return _write(channel, () async {
      final body = await _call(
        'chat.postMessage',
        token: _botToken,
        form: {
          'channel': channel,
          'text': text,
          'thread_ts': ?threadTs,
          if (blocks != null) 'blocks': jsonEncode(blocks),
        },
      );
      return body['ts'] as String?;
    });
  }

  /// Opens a streamed reply in the thread [threadTs] of [channel] and returns
  /// the stream message's timestamp.
  ///
  /// [markdownText] (standard Markdown, at most 12,000 characters) is the first
  /// text. A stream in a channel needs [recipientTeamId] and [recipientUserId].
  /// The stream is text-only: later calls must keep to `markdown_text`.
  Future<String> startStream({
    required String channel,
    required String threadTs,
    String? recipientTeamId,
    String? recipientUserId,
    String? markdownText,
  }) {
    return _write(channel, () async {
      final body = await _call(
        'chat.startStream',
        token: _botToken,
        form: {
          'channel': channel,
          'thread_ts': threadTs,
          'recipient_team_id': ?recipientTeamId,
          'recipient_user_id': ?recipientUserId,
          'markdown_text': ?markdownText,
        },
      );
      final ts = body['ts'];
      if (ts is! String || ts.isEmpty) {
        throw const SlackApiException('Slack API chat.startStream returned no stream timestamp');
      }
      return ts;
    });
  }

  /// Appends [markdownText] (at most 12,000 characters) to the stream message [ts].
  Future<void> appendStream({required String channel, required String ts, required String markdownText}) {
    return _write(channel, () async {
      await _call(
        'chat.appendStream',
        token: _botToken,
        form: {'channel': channel, 'ts': ts, 'markdown_text': markdownText},
      );
    });
  }

  /// Ends the stream message [ts], appending [markdownText] first when given.
  Future<void> stopStream({required String channel, required String ts, String? markdownText}) {
    return _write(channel, () async {
      await _call(
        'chat.stopStream',
        token: _botToken,
        form: {'channel': channel, 'ts': ts, 'markdown_text': ?markdownText},
      );
    });
  }

  /// Replaces the text of the message [ts] in [channel].
  ///
  /// With [blocks] the message's Block Kit is replaced too, and an empty list
  /// removes it; without them Slack keeps the blocks the message already has.
  Future<void> updateMessage({
    required String channel,
    required String ts,
    required String text,
    List<Map<String, dynamic>>? blocks,
  }) {
    return _write(channel, () async {
      await _call(
        'chat.update',
        token: _botToken,
        form: {'channel': channel, 'ts': ts, 'text': text, if (blocks != null) 'blocks': jsonEncode(blocks)},
      );
    });
  }

  /// Shows [status] as the assistant status of the thread [threadTs]; an empty
  /// string clears it. Slack also clears it when the app replies.
  Future<void> setThreadStatus({required String channel, required String threadTs, required String status}) async {
    await _call(
      'assistant.threads.setStatus',
      token: _botToken,
      form: {'channel_id': channel, 'thread_ts': threadTs, 'status': status},
    );
  }

  /// Opens the modal [view] for the interaction that carried [triggerId], which Slack honours
  /// for three seconds and once. Needs no scope. Throws [SlackApiException] with Slack's code
  /// (`expired_trigger_id`, `exchanged_trigger_id`, `invalid_trigger_id`, ...) when it does not open.
  Future<void> openView(String triggerId, Map<String, dynamic> view) async {
    await _call('views.open', token: _botToken, form: {'trigger_id': triggerId, 'view': jsonEncode(view)});
  }

  /// Downloads the private file at [url], reading at most [maxBytes].
  ///
  /// The bot token goes only to an `https` host under `slack.com`, on every
  /// redirect hop too. Throws [SlackApiException] with [slackFileTooLarge] as
  /// the code when the body exceeds [maxBytes] (the read is abandoned and no
  /// part of it is returned), [slackFileScopeMissing] when Slack answers with a
  /// web page instead of the file, and [slackFileUnavailable] for anything else.
  /// [declaredMediaType] is the type Slack announced for the file: a web page
  /// is only a failure for a file that is not itself one.
  Future<List<int>> downloadFile(Uri url, {required int maxBytes, String? declaredMediaType}) async {
    var target = url;
    for (var hop = 0; hop <= _maxRedirects; hop++) {
      if (!_isSlackHost(target)) {
        throw const SlackApiException(
          'Slack file URL is not an https URL under slack.com',
          errorCode: slackFileUnavailable,
        );
      }
      final request = http.Request('GET', target)
        ..followRedirects = false
        ..headers['authorization'] = 'Bearer $_botToken';
      final http.StreamedResponse response;
      try {
        response = await _client.send(request);
      } on Exception catch (error) {
        // The type only: a transport error can quote the request, which carries the token's header.
        throw SlackApiException('Slack file download failed (${error.runtimeType})', errorCode: slackFileUnavailable);
      }
      final status = response.statusCode;
      if (status >= 300 && status < 400) {
        final location = response.headers['location'];
        unawaited(response.stream.listen(null).cancel());
        final next = location == null ? null : target.resolve(location);
        if (next == null) {
          throw SlackApiException(
            'Slack file download answered HTTP $status',
            errorCode: slackFileUnavailable,
            statusCode: status,
          );
        }
        target = next;
        continue;
      }
      if (status != 200) {
        unawaited(response.stream.listen(null).cancel());
        throw SlackApiException(
          'Slack file download answered HTTP $status',
          errorCode: slackFileUnavailable,
          statusCode: status,
        );
      }
      final contentType = (response.headers['content-type'] ?? '').toLowerCase();
      if (contentType.startsWith('text/html') && !(declaredMediaType ?? '').toLowerCase().startsWith('text/html')) {
        unawaited(response.stream.listen(null).cancel());
        throw const SlackApiException(
          'Slack file download returned a web page; the app likely lacks the files:read scope',
          errorCode: slackFileScopeMissing,
        );
      }
      if ((response.contentLength ?? 0) > maxBytes) {
        unawaited(response.stream.listen(null).cancel());
        throw const SlackApiException('Slack file is larger than the allowed size', errorCode: slackFileTooLarge);
      }
      final bytes = BytesBuilder(copy: false);
      try {
        await for (final chunk in response.stream) {
          bytes.add(chunk);
          if (bytes.length > maxBytes) {
            throw const SlackApiException('Slack file is larger than the allowed size', errorCode: slackFileTooLarge);
          }
        }
      } on SlackApiException {
        rethrow;
      } on Exception catch (error) {
        throw SlackApiException('Slack file download failed (${error.runtimeType})', errorCode: slackFileUnavailable);
      }
      return bytes.takeBytes();
    }
    throw const SlackApiException('Slack file download redirected too often', errorCode: slackFileUnavailable);
  }

  static bool _isSlackHost(Uri url) =>
      url.scheme == 'https' && (url.host == 'slack.com' || url.host.endsWith('.slack.com'));

  Future<T> _write<T>(String channel, Future<T> Function() call) =>
      _postQueues.putIfAbsent(channel, () => _ChannelPostQueue(delay: _delay, now: _now)).enqueue(call);

  /// The display name of [userId], cached for the life of the process.
  ///
  /// Falls back to [userId] itself when the lookup fails; a failure is not cached.
  Future<String> displayName(String userId) async {
    final cached = _displayNames[userId];
    if (cached != null) return cached;
    try {
      final body = await _call('users.info', token: _botToken, form: {'user': userId});
      final user = body['user'];
      if (user is Map) {
        final profile = user['profile'];
        for (final candidate in [
          if (profile is Map) profile['display_name'],
          if (profile is Map) profile['real_name'],
          user['real_name'],
          user['name'],
        ]) {
          if (candidate is String && candidate.trim().isNotEmpty) {
            return _displayNames[userId] = candidate.trim();
          }
        }
      }
    } on SlackApiException catch (error) {
      _log.fine('Slack users.info failed for $userId: $error');
    }
    return userId;
  }

  /// The messages of the thread [threadTs] in [channel], oldest first, up to 200.
  Future<List<Map<String, dynamic>>> conversationsReplies({required String channel, required String threadTs}) async {
    final body = await _call(
      'conversations.replies',
      token: _botToken,
      form: {'channel': channel, 'ts': threadTs, 'limit': '200'},
    );
    final messages = body['messages'];
    if (messages is! List) return const [];
    return [
      for (final message in messages)
        if (message is Map) Map<String, dynamic>.from(message),
    ];
  }

  /// Answers a slash command or an interaction through its [responseUrl], visible only to the sender.
  /// The message it replaces is left as it is.
  Future<void> postEphemeral(Uri responseUrl, String text) async {
    if (responseUrl.scheme != 'https') {
      throw const SlackApiException('Slack response URL is not https');
    }
    final http.Response response;
    try {
      response = await _client.post(
        responseUrl,
        headers: const {'content-type': 'application/json; charset=utf-8'},
        body: jsonEncode({'response_type': 'ephemeral', 'replace_original': false, 'text': text}),
      );
    } on Exception catch (error) {
      // The type only: the exception's own text names the request URL, which is a secret here.
      throw SlackApiException('Slack response URL request failed (${error.runtimeType})');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw SlackApiException(
        'Slack response URL answered HTTP ${response.statusCode}',
        statusCode: response.statusCode,
      );
    }
  }

  /// Releases the HTTP client.
  void close() => _client.close();

  Future<Map<String, dynamic>> _call(
    String method, {
    required String token,
    Map<String, String> form = const {},
  }) async => (await _exchange(method, token: token, form: form)).body;

  Future<({Map<String, dynamic> body, Map<String, String> headers})> _exchange(
    String method, {
    required String token,
    Map<String, String> form = const {},
  }) async {
    for (var attempt = 1; ; attempt++) {
      final http.Response response;
      try {
        response = await _client.post(
          Uri.parse('$_apiBase/$method'),
          headers: {'authorization': 'Bearer $token'},
          body: form,
        );
      } on Exception catch (error) {
        // The type only: a transport error can quote the request, which carries the token's header.
        throw SlackApiException('Slack API $method request failed (${error.runtimeType})');
      }

      if (response.statusCode == 429) {
        final retryAfter = _retryAfter(response.headers['retry-after']);
        if (attempt >= 2) {
          throw SlackApiException('Slack API $method rate limited', errorCode: 'ratelimited', statusCode: 429);
        }
        _log.fine('Slack API $method rate limited; retrying in ${retryAfter.inSeconds}s');
        await _delay(retryAfter);
        continue;
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw SlackApiException(
          'Slack API $method answered HTTP ${response.statusCode}',
          statusCode: response.statusCode,
        );
      }

      final Object? decoded;
      try {
        decoded = jsonDecode(response.body);
      } on FormatException {
        throw SlackApiException('Slack API $method returned invalid JSON', statusCode: response.statusCode);
      }
      if (decoded is! Map<String, dynamic>) {
        throw SlackApiException('Slack API $method returned an unexpected payload', statusCode: response.statusCode);
      }
      if (decoded['ok'] != true) {
        final code = decoded['error'] is String ? decoded['error'] as String : 'unknown_error';
        throw SlackApiException('Slack API $method failed: $code', errorCode: code, statusCode: response.statusCode);
      }
      return (body: decoded, headers: response.headers);
    }
  }

  static Duration _retryAfter(String? header) {
    final seconds = int.tryParse(header ?? '') ?? 1;
    final delay = Duration(seconds: seconds < 1 ? 1 : seconds);
    return delay > _maxRetryAfter ? _maxRetryAfter : delay;
  }
}

/// Runs one channel's posts in order, at least [_minPostInterval] apart.
class _ChannelPostQueue {
  final Future<void> Function(Duration) _delay;
  final DateTime Function() _now;
  Future<void> _tail = Future.value();
  DateTime? _lastPostEnd;

  new({required Future<void> Function(Duration) delay, required DateTime Function() now}) : _delay = delay, _now = now;

  Future<T> enqueue<T>(Future<T> Function() post) {
    final result = _tail.then((_) async {
      final last = _lastPostEnd;
      if (last != null) {
        final wait = _minPostInterval - _now().difference(last);
        if (wait > Duration.zero) await _delay(wait);
      }
      try {
        return await post();
      } finally {
        _lastPostEnd = _now();
      }
    });
    _tail = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }
}
