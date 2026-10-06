import '../slack_bot_scopes.dart';
import '../slack_web_api_client.dart';

/// Recording [SlackWebApiClient] that answers from scripted data and never
/// touches the network.
class FakeSlackWebApi extends SlackWebApiClient {
  /// Creates a fake whose `auth.test` reports [botUserId].
  new({this.botUserId = 'UBOT', this.botId = 'BBOT', Uri? socketUrl})
    : socketUrl = socketUrl ?? Uri.parse('ws://127.0.0.1:1/'),
      super(botToken: 'xoxb-fake', appToken: 'xapp-fake');

  /// The user ID `auth.test` reports.
  String botUserId;

  /// The bot ID `auth.test` reports.
  String botId;

  /// The URL `apps.connections.open` returns.
  Uri socketUrl;

  /// The scopes `auth.test` reports as granted; the manifest's ten by default.
  List<String> scopes = List.of(slackExpectedBotScopes);

  /// Throws from `auth.test` when set, as a revoked token would, or as an unreachable Slack when it has no error code.
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

  /// Throws from [postEphemeral] when set.
  SlackApiException? ephemeralError;

  /// Every post, in call order.
  final List<({String channel, String text, String? threadTs})> posts = [];

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

  @override
  Future<SlackAuthInfo> authTest() async {
    authTestCalls++;
    final error = authError;
    if (error != null) throw error;
    return (userId: botUserId, botId: botId, scopes: List.of(scopes));
  }

  @override
  Future<Uri> openSocketUrl() async {
    final error = socketUrlError;
    if (error != null) throw error;
    return socketUrl;
  }

  @override
  Future<String?> postMessage({required String channel, required String text, String? threadTs}) async {
    final error = onPost?.call(channel, threadTs);
    if (error != null) throw error;
    posts.add((channel: channel, text: text, threadTs: threadTs));
    return '1700000000.${(_nextTs++).toString().padLeft(6, '0')}';
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
