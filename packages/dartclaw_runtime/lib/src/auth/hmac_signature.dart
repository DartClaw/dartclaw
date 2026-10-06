import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'auth_utils.dart';

/// Signs [data] with HMAC-SHA256 under [key], as unpadded base64url.
///
/// The one signing construction behind session cookies and source-link tokens,
/// both keyed by the gateway token.
String hmacSign(String data, String key) {
  final hmac = Hmac(sha256, utf8.encode(key));
  final digest = hmac.convert(utf8.encode(data));
  return base64Url.encode(digest.bytes).replaceAll('=', '');
}

/// Whether [signature] is the signature of [data] under [key], compared in constant time.
bool hmacVerify(String data, String signature, String key) => constantTimeEquals(signature, hmacSign(data, key));
