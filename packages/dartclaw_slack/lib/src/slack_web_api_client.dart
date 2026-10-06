import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

/// Default Slack Web API base URL.
const slackApiBase = 'https://slack.com/api';

const _minPostInterval = Duration(seconds: 1);
const _maxRetryAfter = Duration(seconds: 60);

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

/// The identity `auth.test` reports for the bot token.
typedef SlackAuthInfo = ({String userId, String? botId});

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

  /// Verifies the bot token and returns the bot's identity.
  ///
  /// Throws [SlackApiException] when Slack refuses the token.
  Future<SlackAuthInfo> authTest() async {
    final body = await _call('auth.test', token: _botToken);
    final userId = body['user_id'];
    if (userId is! String || userId.isEmpty) {
      throw const SlackApiException('Slack API auth.test returned no bot user ID');
    }
    return (userId: userId, botId: body['bot_id'] as String?);
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
  /// Posts to one channel are queued at least one second apart.
  Future<String?> postMessage({required String channel, required String text, String? threadTs}) {
    final queue = _postQueues.putIfAbsent(channel, () => _ChannelPostQueue(delay: _delay, now: _now));
    return queue.enqueue(() async {
      final body = await _call(
        'chat.postMessage',
        token: _botToken,
        form: {'channel': channel, 'text': text, 'thread_ts': ?threadTs},
      );
      return body['ts'] as String?;
    });
  }

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

  /// Answers a slash command through its [responseUrl], visible only to the sender.
  Future<void> postEphemeral(Uri responseUrl, String text) async {
    if (responseUrl.scheme != 'https') {
      throw const SlackApiException('Slack response URL is not https');
    }
    final http.Response response;
    try {
      response = await _client.post(
        responseUrl,
        headers: const {'content-type': 'application/json; charset=utf-8'},
        body: jsonEncode({'response_type': 'ephemeral', 'text': text}),
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
      return decoded;
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
