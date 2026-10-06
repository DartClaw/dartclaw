import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../slack_web_api_client.dart';

/// One download the fake file host received, kept so tests can assert where the
/// bot token was sent.
typedef FakeSlackFileRequest = ({Uri url, Map<String, String> headers});

/// A file the fake host serves.
class FakeSlackFile {
  /// Serves [bytes] with [status] and [contentType]; the body arrives in 64 KiB
  /// chunks and, unless [sendsContentLength] is set, without a length header, so a
  /// reader can only learn it is too large by reading.
  new({
    this.bytes = const [],
    this.status = 200,
    this.contentType = 'application/octet-stream',
    this.sendsContentLength = false,
    this.dropsConnection = false,
    this.gate,
  });

  /// Response body.
  final List<int> bytes;

  /// Response status.
  final int status;

  /// Response `content-type`.
  final String contentType;

  /// Whether the response announces its length up front.
  final bool sendsContentLength;

  /// Fails the request with a transport error instead of answering.
  final bool dropsConnection;

  /// When set, the answer waits until it completes, to hold a download open.
  final Completer<void>? gate;
}

/// The fake's file server: the private URLs it knows, and every request it saw.
class FakeSlackFileHost {
  /// Files by URL.
  final Map<String, FakeSlackFile> files = {};

  /// Every download request, in order.
  final List<FakeSlackFileRequest> requests = [];

  /// How many body bytes were handed out; stops growing when a reader abandons the download.
  int bytesServed = 0;

  late final http.Client client = MockClient.streaming((request, _) async {
    requests.add((url: request.url, headers: Map.of(request.headers)));
    final file = files[request.url.toString()];
    if (file == null) return http.StreamedResponse(const Stream.empty(), 404);
    await file.gate?.future;
    if (file.dropsConnection) throw http.ClientException('connection dropped', request.url);
    return http.StreamedResponse(
      _chunks(file),
      file.status,
      contentLength: file.sendsContentLength ? file.bytes.length : null,
      headers: {'content-type': file.contentType},
    );
  });

  Stream<List<int>> _chunks(FakeSlackFile file) async* {
    const chunkSize = 64 * 1024;
    for (var offset = 0; offset < file.bytes.length; offset += chunkSize) {
      final end = offset + chunkSize > file.bytes.length ? file.bytes.length : offset + chunkSize;
      bytesServed += end - offset;
      yield file.bytes.sublist(offset, end);
    }
  }
}

/// Recording [SlackWebApiClient] that answers from scripted data and never
/// touches the network.
///
/// File downloads run the real client against [fileHost], so the bot token
/// rules are exercised rather than faked.
class FakeSlackWebApi extends SlackWebApiClient {
  /// Creates a fake whose `auth.test` reports [botUserId].
  new({String botUserId = 'UBOT', String botId = 'BBOT', Uri? socketUrl})
    : this._(botUserId, botId, socketUrl ?? Uri.parse('ws://127.0.0.1:1/'), FakeSlackFileHost());

  new _(this.botUserId, this.botId, this.socketUrl, this.fileHost)
    : super(botToken: 'xoxb-fake', appToken: 'xapp-fake', httpClient: fileHost.client);

  /// The user ID `auth.test` reports.
  String botUserId;

  /// The bot ID `auth.test` reports.
  String botId;

  /// The workspace ID `auth.test` reports.
  String? authTeamId = 'TTEAM';

  /// The URL `apps.connections.open` returns.
  Uri socketUrl;

  /// Serves the files [downloadFile] fetches.
  final FakeSlackFileHost fileHost;

  /// Throws from `auth.test` when set, as a revoked token would.
  SlackApiException? authError;

  /// Throws from `apps.connections.open` when set.
  SlackApiException? socketUrlError;

  /// Display names `users.info` resolves; an unknown user falls back to its ID.
  final Map<String, String> displayNames = {};

  /// Thread contents `conversations.replies` returns, keyed `channel:threadTs`.
  final Map<String, List<Map<String, dynamic>>> threads = {};

  /// Throws from `conversations.replies` when set.
  SlackApiException? repliesError;

  /// Decides whether a post fails; return the exception to throw, or `null` to let it succeed.
  SlackApiException? Function(String channel, String? threadTs)? onPost;

  /// Decides whether a stream, update or status call fails, by its Slack method name
  /// (`chat.startStream`, `chat.appendStream`, `chat.stopStream`, `chat.update`,
  /// `assistant.threads.setStatus`); return the exception to throw, or `null`.
  SlackApiException? Function(String method)? onCall;

  /// Throws from [postEphemeral] when set.
  SlackApiException? ephemeralError;

  /// Every post, in call order.
  final List<({String channel, String text, String? threadTs})> posts = [];

  /// Every `chat.startStream`, in call order.
  final List<
    ({String channel, String threadTs, String? recipientTeamId, String? recipientUserId, String? markdownText})
  >
  startedStreams = [];

  /// Every `chat.appendStream`, in call order.
  final List<({String channel, String ts, String markdownText})> appends = [];

  /// Every `chat.stopStream`, in call order.
  final List<({String channel, String ts, String? markdownText})> stops = [];

  /// Every `chat.update`, in call order.
  final List<({String channel, String ts, String text})> updates = [];

  /// Every `assistant.threads.setStatus`, in call order; an empty status is a clear.
  final List<({String channel, String threadTs, String status})> statuses = [];

  /// The Slack method of every stream, update, status and post call, in call order.
  final List<String> calls = [];

  /// Every ephemeral slash-command answer, in call order.
  final List<({Uri url, String text})> ephemerals = [];

  /// Every `conversations.replies` call, as `channel:threadTs`.
  final List<String> repliesCalls = [];

  /// Every `users.info` lookup, in call order.
  final List<String> displayNameCalls = [];

  /// How many times `auth.test` ran.
  int authTestCalls = 0;

  /// Whether [close] ran.
  bool closed = false;

  int _nextTs = 0;

  String _newTs() => '1700000000.${(_nextTs++).toString().padLeft(6, '0')}';

  void _enter(String method) {
    calls.add(method);
    final error = onCall?.call(method);
    if (error != null) throw error;
  }

  @override
  String? get teamId => authTeamId;

  @override
  Future<SlackAuthInfo> authTest() async {
    authTestCalls++;
    final error = authError;
    if (error != null) throw error;
    return (userId: botUserId, botId: botId);
  }

  @override
  Future<Uri> openSocketUrl() async {
    final error = socketUrlError;
    if (error != null) throw error;
    return socketUrl;
  }

  @override
  Future<String?> postMessage({required String channel, required String text, String? threadTs}) async {
    calls.add('chat.postMessage');
    final error = onPost?.call(channel, threadTs);
    if (error != null) throw error;
    posts.add((channel: channel, text: text, threadTs: threadTs));
    return _newTs();
  }

  @override
  Future<String> startStream({
    required String channel,
    required String threadTs,
    String? recipientTeamId,
    String? recipientUserId,
    String? markdownText,
  }) async {
    _enter('chat.startStream');
    startedStreams.add((
      channel: channel,
      threadTs: threadTs,
      recipientTeamId: recipientTeamId,
      recipientUserId: recipientUserId,
      markdownText: markdownText,
    ));
    return _newTs();
  }

  @override
  Future<void> appendStream({required String channel, required String ts, required String markdownText}) async {
    _enter('chat.appendStream');
    appends.add((channel: channel, ts: ts, markdownText: markdownText));
  }

  @override
  Future<void> stopStream({required String channel, required String ts, String? markdownText}) async {
    _enter('chat.stopStream');
    stops.add((channel: channel, ts: ts, markdownText: markdownText));
  }

  @override
  Future<void> updateMessage({required String channel, required String ts, required String text}) async {
    _enter('chat.update');
    updates.add((channel: channel, ts: ts, text: text));
  }

  @override
  Future<void> setThreadStatus({required String channel, required String threadTs, required String status}) async {
    _enter('assistant.threads.setStatus');
    statuses.add((channel: channel, threadTs: threadTs, status: status));
  }

  @override
  Future<String> displayName(String userId) async {
    displayNameCalls.add(userId);
    return displayNames[userId] ?? userId;
  }

  @override
  Future<List<Map<String, dynamic>>> conversationsReplies({required String channel, required String threadTs}) async {
    repliesCalls.add('$channel:$threadTs');
    final error = repliesError;
    if (error != null) throw error;
    return threads['$channel:$threadTs'] ?? const [];
  }

  @override
  Future<void> postEphemeral(Uri responseUrl, String text) async {
    final error = ephemeralError;
    if (error != null) throw error;
    ephemerals.add((url: responseUrl, text: text));
  }

  @override
  void close() => closed = true;
}
