import 'dart:convert';

import 'package:crypto/crypto.dart';

/// The `X-Slack-Signature` value Slack sends for [body] at [timestamp] (Unix seconds).
String slackSignature(String signingSecret, int timestamp, List<int> body) {
  final basestring = [...utf8.encode('v0:$timestamp:'), ...body];
  return 'v0=${Hmac(sha256, utf8.encode(signingSecret)).convert(basestring)}';
}

/// The headers Slack sends with a signed request carrying [body].
///
/// [timestamp] defaults to now; [signingSecret] may differ from the verifier's
/// to build a forged request.
Map<String, String> signedSlackHeaders(
  String signingSecret,
  List<int> body, {
  int? timestamp,
  String contentType = 'application/json',
}) {
  final ts = timestamp ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;
  return {
    'content-type': contentType,
    'x-slack-request-timestamp': '$ts',
    'x-slack-signature': slackSignature(signingSecret, ts, body),
  };
}
