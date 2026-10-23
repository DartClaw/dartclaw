import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dartclaw_core/dartclaw_core.dart' show MessageDeduplicator;
import 'package:logging/logging.dart';

import 'slack_envelope.dart';

const _replayWindow = Duration(minutes: 5);
final _timestampPattern = RegExp(r'^\d{1,12}$');
final _signaturePattern = RegExp(r'^v0=([0-9a-fA-F]{64})$');

/// Why a request was refused before any of it was read.
enum SlackRequestRejection {
  /// The signature or timestamp header is absent or malformed.
  missingSignature,

  /// The timestamp is more than five minutes from now, in either direction.
  staleTimestamp,

  /// The signature does not match the body.
  invalidSignature;

  /// The stable code the failed-auth event and the audit entry carry.
  String get reason => switch (this) {
    missingSignature => 'missing_slack_signature',
    staleTimestamp => 'stale_slack_timestamp',
    invalidSignature => 'invalid_slack_signature',
  };
}

/// The answer to one Events API request, for the transport to send.
class SlackEventsResponse {
  /// HTTP status code.
  final int statusCode;

  /// Response body; empty for an acknowledgement.
  final String body;

  /// Response content type.
  final String contentType;

  /// Why the request was refused, when [statusCode] is 401.
  final SlackRequestRejection? rejection;

  /// Creates a response.
  const new({required this.statusCode, this.body = '', this.contentType = 'text/plain', this.rejection});
}

/// Verifies and decodes Slack's HTTP deliveries (Events API, slash commands,
/// interactivity) into the envelopes Socket Mode would deliver.
///
/// Framework-neutral: raw bytes and headers in, status and body out. Nothing
/// reads the body before its signature is verified over the exact bytes.
class SlackEventsHandler {
  static final _log = Logger('SlackEventsHandler');

  final List<int> _signingKey;
  final SlackEnvelopeDispatch _dispatch;
  final DateTime Function() _now;
  final bool Function() _isReady;
  final MessageDeduplicator _ledger = MessageDeduplicator();

  DateTime? _lastVerifiedAt;
  SlackRequestRejection? _lastRejection;
  DateTime? _lastRejectionAt;

  /// Creates a handler. An empty [signingSecret] verifies nothing.
  ///
  /// Accepted envelopes go to [dispatch], which is never awaited. [now]
  /// replaces the clock for the replay window. [isReady] answers whether the
  /// app can act on a delivery yet; until it does, a verified event, slash
  /// command or interaction is answered 503 so Slack retries it, never
  /// acknowledged and lost.
  new({
    required String signingSecret,
    required SlackEnvelopeDispatch dispatch,
    DateTime Function()? now,
    bool Function()? isReady,
  }) : _signingKey = utf8.encode(signingSecret),
       _dispatch = dispatch,
       _now = now ?? DateTime.now,
       _isReady = isReady ?? (() => true);

  /// When a request last passed verification, or `null` if none has.
  DateTime? get lastVerifiedAt => _lastVerifiedAt;

  /// Why the latest request was refused, or `null` if none was.
  SlackRequestRejection? get lastRejection => _lastRejection;

  /// When the latest request was refused.
  DateTime? get lastRejectionAt => _lastRejectionAt;

  /// Answers one request. [headers] are matched case-insensitively.
  ///
  /// A refused request answers 401 with its [SlackEventsResponse.rejection];
  /// the caller reports it. A verified one answers within the acknowledgement
  /// window whatever its processing does; a kind the dispatch answers (a modal
  /// submission) is answered with the handler's body, as JSON, once it is done.
  Future<SlackEventsResponse> handle(Uint8List body, Map<String, String> headers) async {
    final lowered = {for (final MapEntry(:key, :value) in headers.entries) key.toLowerCase(): value};
    final rejection = _verify(body, lowered);
    if (rejection != null) {
      _lastRejection = rejection;
      _lastRejectionAt = _now();
      return SlackEventsResponse(statusCode: 401, body: 'Unauthorized', rejection: rejection);
    }
    _lastVerifiedAt = _now();

    final String text;
    try {
      text = utf8.decode(body);
    } on FormatException {
      return _badRequest('body is not UTF-8');
    }
    final isForm = (lowered['content-type'] ?? '').toLowerCase().startsWith('application/x-www-form-urlencoded');
    return isForm ? await _handleForm(text) : _handleJson(text);
  }

  SlackRequestRejection? _verify(Uint8List body, Map<String, String> headers) {
    final timestamp = headers['x-slack-request-timestamp'];
    final signature = headers['x-slack-signature'];
    final signatureMatch = signature == null ? null : _signaturePattern.firstMatch(signature);
    if (timestamp == null || !_timestampPattern.hasMatch(timestamp) || signatureMatch == null) {
      return SlackRequestRejection.missingSignature;
    }
    final skewMs = _now().millisecondsSinceEpoch - int.parse(timestamp) * 1000;
    if (skewMs.abs() > _replayWindow.inMilliseconds) return SlackRequestRejection.staleTimestamp;
    if (_signingKey.isEmpty) return SlackRequestRejection.invalidSignature;

    final expected = Hmac(sha256, _signingKey).convert([...utf8.encode('v0:$timestamp:'), ...body]);
    final hex = signatureMatch.group(1)!;
    final received = Digest([for (var i = 0; i < hex.length; i += 2) int.parse(hex.substring(i, i + 2), radix: 16)]);
    return received == expected ? null : SlackRequestRejection.invalidSignature;
  }

  SlackEventsResponse _handleJson(String text) {
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      return _badRequest('body is not JSON');
    }
    if (decoded is! Map<String, dynamic>) return _badRequest('body is not a JSON object');

    switch (decoded['type']) {
      case 'url_verification':
        final challenge = decoded['challenge'];
        return challenge is String
            ? SlackEventsResponse(statusCode: 200, body: challenge)
            : _badRequest('url_verification carries no challenge');
      case 'event_callback':
        if (!_isReady()) return _unavailable();
        final eventId = decoded['event_id'];
        if (eventId is! String || eventId.isEmpty || decoded['event'] is! Map) {
          return _badRequest('event_callback lacks an event_id or an event');
        }
        if (_ledger.tryProcess(eventId)) {
          _hand(SlackEnvelope(kind: SlackEnvelopeKind.event, payload: decoded));
        }
        return _acknowledged;
      case 'app_rate_limited':
        _log.warning('Slack reports this app is rate limited; some events were dropped');
        return _acknowledged;
      case final type:
        _log.fine('Ignoring a Slack request of unknown type ${type is String ? '"$type"' : '(none)'}');
        return _acknowledged;
    }
  }

  Future<SlackEventsResponse> _handleForm(String text) async {
    if (!_isReady()) return _unavailable();
    final Map<String, String> fields;
    try {
      fields = Uri.splitQueryString(text);
    } on FormatException {
      return _badRequest('form body is malformed');
    } on ArgumentError {
      return _badRequest('form body is malformed');
    }

    final interaction = fields['payload'];
    if (interaction != null) {
      final Object? decoded;
      try {
        decoded = jsonDecode(interaction);
      } on FormatException {
        return _badRequest('interaction payload is not JSON');
      }
      if (decoded is! Map<String, dynamic>) return _badRequest('interaction payload is not a JSON object');
      final envelope = SlackEnvelope(kind: slackInteractionKind(decoded['type']), payload: decoded);
      if (_dispatch.answers(envelope.kind)) {
        final body = await _dispatch.dispatchAnswering(envelope);
        return body == null
            ? _acknowledged
            : SlackEventsResponse(statusCode: 200, body: jsonEncode(body), contentType: 'application/json');
      }
      _hand(envelope);
      return _acknowledged;
    }
    if (fields['command'] != null) {
      _hand(SlackEnvelope(kind: SlackEnvelopeKind.slashCommand, payload: Map<String, dynamic>.of(fields)));
      return _acknowledged;
    }
    return _badRequest('form body is neither a slash command nor an interaction');
  }

  /// Starts the dispatch without waiting for it; a failure is logged by type only,
  /// as its text can quote the request.
  void _hand(SlackEnvelope envelope) {
    unawaited(
      Future<void>.sync(() => _dispatch.dispatch(envelope)).catchError((Object error) {
        _log.warning('Slack ${envelope.kind.name} dispatch failed (${error.runtimeType})');
      }),
    );
  }

  static const _acknowledged = SlackEventsResponse(statusCode: 200);

  static SlackEventsResponse _unavailable() {
    _log.warning('Refusing a verified Slack request with 503: the bot token has not been verified');
    return const SlackEventsResponse(statusCode: 503, body: 'Service Unavailable');
  }

  static SlackEventsResponse _badRequest(String why) {
    _log.fine('Refusing a verified Slack request: $why');
    return const SlackEventsResponse(statusCode: 400, body: 'Bad Request');
  }
}
