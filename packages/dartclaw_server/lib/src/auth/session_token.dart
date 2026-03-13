import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'auth_utils.dart';

/// Default session TTL (30 days).
const sessionTtl = Duration(days: 30);

const _cookieName = 'dart_session';
const _cookieMaxAge = 2592000; // 30 days in seconds

/// The cookie name used for session tokens.
String get sessionCookieName => _cookieName;

/// Creates an HMAC-signed session token.
///
/// Format: `base64url(payload).base64url(signature)` where
/// payload = `{"iat": unix_ms}` and signature = HMAC-SHA256(payload, key).
///
/// Stateless — no server-side session storage needed. The gateway token
/// is the signing key; `token rotate` naturally invalidates all cookies.
String createSessionToken(String gatewayToken) {
  final payload = jsonEncode({'iat': DateTime.now().millisecondsSinceEpoch});
  final payloadB64 = base64Url.encode(utf8.encode(payload));
  final sig = _sign(payloadB64, gatewayToken);
  return '$payloadB64.$sig';
}

/// Validates an HMAC-signed session token.
///
/// Returns true if the HMAC is valid and the token has not expired
/// (issued within [ttl]).
bool validateSessionToken(String token, String gatewayToken, {Duration ttl = sessionTtl}) {
  final dot = token.indexOf('.');
  if (dot < 0 || dot == token.length - 1) return false;

  final payloadB64 = token.substring(0, dot);
  final sig = token.substring(dot + 1);

  // Verify HMAC
  final expected = _sign(payloadB64, gatewayToken);
  if (!constantTimeEquals(sig, expected)) return false;

  // Decode payload and check TTL
  try {
    final payloadJson = utf8.decode(base64Url.decode(payloadB64));
    final payload = jsonDecode(payloadJson) as Map<String, dynamic>;
    final iat = payload['iat'] as int;
    final issuedAt = DateTime.fromMillisecondsSinceEpoch(iat);
    return DateTime.now().difference(issuedAt) <= ttl;
  } catch (_) {
    return false;
  }
}

/// Builds a Set-Cookie header value for a session token.
String sessionCookieHeader(String token, {bool secure = false}) {
  final secureAttr = secure ? '; Secure' : '';
  return '$_cookieName=$token; HttpOnly; SameSite=Strict; Path=/; Max-Age=$_cookieMaxAge$secureAttr';
}

String _sign(String data, String key) {
  final hmac = Hmac(sha256, utf8.encode(key));
  final digest = hmac.convert(utf8.encode(data));
  return base64Url.encode(digest.bytes).replaceAll('=', '');
}
