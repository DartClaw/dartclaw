import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart'
    show
        ChannelRunApprovalAction,
        ChannelRunApprovalFailed,
        ChannelRunApprovalHandler,
        ChannelRunApprovalRefused,
        ChannelRunApprovalRequest,
        ChannelRunApprovalResolved,
        ChannelRunApprovalResult,
        runActionNonceKey,
        runActionRunIdKey,
        runActionStepIdKey;
import 'package:logging/logging.dart';

import 'slack_envelope.dart';
import 'slack_web_api_client.dart';

/// What a button carries back on a click, as one `value` string.
///
/// Compact JSON, so the nonce travels in no other form and the whole value
/// stays far below Slack's 2,000-character limit for run, step and nonce.
String encodeRunActionValue(Map<String, String> data) => jsonEncode(data);

Map<String, String>? _decodeRunActionValue(Object? value) {
  if (value is! String) return null;
  final Object? decoded;
  try {
    decoded = jsonDecode(value);
  } on FormatException {
    return null;
  }
  if (decoded is! Map) return null;
  final data = <String, String>{};
  for (final entry in decoded.entries) {
    if (entry.key is! String || entry.value is! String) return null;
    data[entry.key as String] = entry.value as String;
  }
  return data;
}

/// Reads a `block_actions` click on a run approval button, hands it to the
/// run-approval handler and answers the clicker privately when it did not resolve.
///
/// It never edits the post: whoever resolves the approval, the post is retired
/// by the one that owns it.
class SlackRunApprovals {
  static final _log = Logger('SlackRunApprovals');

  final SlackWebApiClient _api;
  final ChannelRunApprovalHandler? _handler;

  /// Creates the click reader; without a [handler] every run action is answered as unavailable.
  const new({required SlackWebApiClient api, ChannelRunApprovalHandler? handler}) : _api = api, _handler = handler;

  /// Handles one `block_actions` envelope. Anything that is not a run action is ignored.
  ///
  /// The value, the nonce inside it and the `response_url` are never logged.
  Future<void> handle(SlackEnvelope envelope) async {
    final payload = envelope.payload;
    final action = _firstAction(payload);
    final runAction = ChannelRunApprovalAction.fromActionId(action?['action_id'] as String?);
    if (action == null || runAction == null) {
      _log.fine('Ignoring a Slack block action that is not a run action');
      return;
    }
    final responseUrl = _responseUrl(payload);

    final data = _decodeRunActionValue(action['value']);
    final runId = data?[runActionRunIdKey];
    final stepId = data?[runActionStepIdKey];
    final nonce = data?[runActionNonceKey];
    final user = payload['user'] is Map ? payload['user'] as Map : const {};
    final senderId = user['id'];
    final postMessageId = _postMessageId(payload);
    if (runId == null ||
        stepId == null ||
        nonce == null ||
        runId.isEmpty ||
        stepId.isEmpty ||
        nonce.isEmpty ||
        senderId is! String ||
        senderId.isEmpty ||
        postMessageId == null) {
      _log.fine('Refusing a Slack ${runAction.actionId} click that does not carry a complete approval');
      await _answer(responseUrl, 'This approval button is not valid.');
      return;
    }

    final handler = _handler;
    if (handler == null) {
      await _answer(responseUrl, 'Run approvals are unavailable.');
      return;
    }

    final result = await _resolve(
      handler,
      ChannelRunApprovalRequest(
        action: runAction,
        runId: runId,
        stepId: stepId,
        nonce: nonce,
        senderId: senderId,
        senderDisplayName: _displayName(user),
        channelType: 'slack',
        postMessageId: postMessageId,
      ),
    );
    switch (result) {
      case ChannelRunApprovalResolved():
        break;
      case ChannelRunApprovalRefused(:final message):
        await _answer(responseUrl, message);
      case ChannelRunApprovalFailed(:final message):
        await _answer(responseUrl, message);
      case null:
        await _answer(responseUrl, 'The approval could not be resolved. Try again.');
    }
  }

  /// A thrown error becomes `null`, logged by type only: its text could quote the click.
  Future<ChannelRunApprovalResult?> _resolve(
    ChannelRunApprovalHandler handler,
    ChannelRunApprovalRequest request,
  ) async {
    try {
      return await handler(request);
    } catch (error) {
      _log.warning('A Slack run approval click failed (${error.runtimeType})');
      return null;
    }
  }

  Future<void> _answer(Uri? responseUrl, String text) async {
    if (responseUrl == null) {
      _log.fine('A Slack block action carried no usable response_url; the clicker gets no answer');
      return;
    }
    try {
      await _api.postEphemeral(responseUrl, text);
    } on SlackApiException catch (error) {
      _log.warning('Could not answer a Slack run approval click: $error');
    }
  }

  static Map<String, dynamic>? _firstAction(Map<String, dynamic> payload) {
    final actions = payload['actions'];
    if (actions is! List || actions.isEmpty || actions.first is! Map) return null;
    return Map<String, dynamic>.from(actions.first as Map);
  }

  static Uri? _responseUrl(Map<String, dynamic> payload) {
    final url = payload['response_url'];
    return url is String ? Uri.tryParse(url) : null;
  }

  /// The `ts` of the clicked message, which is the identity a post is sent with.
  static String? _postMessageId(Map<String, dynamic> payload) {
    final container = payload['container'];
    final fromContainer = container is Map ? container['message_ts'] : null;
    final message = payload['message'];
    final id = fromContainer ?? (message is Map ? message['ts'] : null);
    return id is String && id.isNotEmpty ? id : null;
  }

  static String? _displayName(Map<dynamic, dynamic> user) {
    final name = user['name'];
    return name is String && name.isNotEmpty ? name : null;
  }
}
