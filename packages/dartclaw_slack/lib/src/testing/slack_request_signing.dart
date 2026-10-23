import 'dart:convert';

import 'package:crypto/crypto.dart';

/// The headers Slack sends with a signed request carrying [body].
///
/// [timestamp] (Unix seconds) defaults to now; [signingSecret] may differ from
/// the verifier's to build a forged request.
Map<String, String> signedSlackHeaders(
  String signingSecret,
  List<int> body, {
  int? timestamp,
  String contentType = 'application/json',
}) {
  final ts = timestamp ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final basestring = [...utf8.encode('v0:$ts:'), ...body];
  return {
    'content-type': contentType,
    'x-slack-request-timestamp': '$ts',
    'x-slack-signature': 'v0=${Hmac(sha256, utf8.encode(signingSecret)).convert(basestring)}',
  };
}
