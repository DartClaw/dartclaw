import 'dart:convert';

import 'hmac_signature.dart';
import 'session_token.dart' show sessionTtl;

/// The route that serves a source link; the only knowledge route open without a session.
const sourceLinkPath = '/knowledge/source';

/// The knowledge source a link token opens: a layer wire name and its layer-local locator.
typedef SourceLinkTarget = ({String layer, String locator});

/// Creates a token naming one [layer] source at [locator].
///
/// Format: unpadded `base64url(payload).base64url(signature)`, signed with the session
/// cookie's HMAC under [key] (the gateway token), so `token rotate` revokes every
/// link. A null [key] is `auth_mode: none`: the token carries the payload alone.
String createSourceLinkToken({required String layer, required String locator, String? key, DateTime? now}) {
  final payload = jsonEncode({
    'layer': layer,
    'locator': locator,
    'iat': (now ?? DateTime.now()).millisecondsSinceEpoch,
  });
  final payloadB64 = base64Url.encode(utf8.encode(payload)).replaceAll('=', '');
  return key == null ? payloadB64 : '$payloadB64.${hmacSign(payloadB64, key)}';
}

/// The target [token] names, or null for anything that is not a live token under [key].
///
/// With a [key] the token must be signed under it and issued within [ttl]; with a
/// null [key] (`auth_mode: none`) only the payload and the age limit are read.
SourceLinkTarget? validateSourceLinkToken(String token, {String? key, DateTime? now, Duration ttl = sessionTtl}) {
  final dot = token.indexOf('.');
  final String payloadB64;
  if (key == null) {
    if (dot >= 0) return null;
    payloadB64 = token;
  } else {
    if (dot < 0 || dot == token.length - 1) return null;
    payloadB64 = token.substring(0, dot);
    if (!hmacVerify(payloadB64, token.substring(dot + 1), key)) return null;
  }

  try {
    final payload = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(payloadB64)))) as Map<String, dynamic>;
    final issuedAt = DateTime.fromMillisecondsSinceEpoch(payload['iat'] as int);
    if ((now ?? DateTime.now()).difference(issuedAt) > ttl) return null;
    return (layer: payload['layer'] as String, locator: payload['locator'] as String);
  } on Object {
    return null;
  }
}
