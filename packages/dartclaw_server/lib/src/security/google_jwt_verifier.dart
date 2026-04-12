import 'dart:convert';
import 'dart:typed_data';

import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'package:dartclaw_google_chat/dartclaw_google_chat.dart';
import 'package:http/http.dart' as http;
import 'package:pointycastle/pointycastle.dart' as pc;
import 'package:logging/logging.dart';

class GoogleJwtVerifier {
  static final Uri googleCertsUrl = Uri.parse('https://www.googleapis.com/oauth2/v1/certs');
  static final Uri googleOidcCertsUrl = Uri.parse('https://www.googleapis.com/oauth2/v3/certs');
  static final Uri chatServiceAccountCertsUrl = Uri.parse(
    'https://www.googleapis.com/service_accounts/v1/metadata/x509/chat%40system.gserviceaccount.com',
  );
  static const String expectedIssuer = 'chat@system.gserviceaccount.com';
  static const String oidcIssuer = 'https://accounts.google.com';

  final GoogleChatAudienceConfig _audience;
  final http.Client _httpClient;
  final Duration _cacheTtl;
  final DateTime Function() _now;
  final Uri? _certsUrlOverride;
  final Logger _log = Logger('GoogleJwtVerifier');

  /// Per-issuer cert caches (legacy and OIDC use different key sets).
  final Map<String, _CertCacheEntry> _certCaches = {};

  GoogleJwtVerifier({
    required GoogleChatAudienceConfig audience,
    http.Client? httpClient,
    Duration cacheTtl = const Duration(minutes: 10),
    DateTime Function()? now,
    Uri? certsUrl,
  }) : _audience = audience,
       _httpClient = httpClient ?? http.Client(),
       _cacheTtl = cacheTtl,
       _now = now ?? DateTime.now,
       _certsUrlOverride = certsUrl;

  Future<bool> verify(String? authHeader) async {
    if (authHeader == null || !authHeader.startsWith('Bearer ')) {
      _log.warning('JWT verification failed: missing or invalid Authorization header');
      return false;
    }

    final token = authHeader.substring('Bearer '.length).trim();
    if (token.isEmpty) {
      _log.warning('JWT verification failed: empty bearer token');
      return false;
    }

    try {
      final decoded = JWT.decode(token);
      final kid = decoded.header?['kid'];
      if (kid is! String || kid.isEmpty) {
        _log.warning('JWT verification failed: missing key id');
        return false;
      }

      final payload = decoded.payload;
      final issuer = payload is Map ? payload['iss'] as String? : null;
      final isOidc = issuer == oidcIssuer;
      final resolvedIssuer = isOidc ? oidcIssuer : expectedIssuer;

      final certs = await _fetchCerts(isOidc: isOidc);
      final key = certs[kid];
      if (key == null) {
        _log.warning('JWT verification failed: unknown key id "$kid"');
        return false;
      }

      final verified = JWT.verify(
        token,
        key,
        issuer: resolvedIssuer,
        audience: Audience.one(_audience.value),
        checkHeaderType: false,
      );
      _verifyModeSpecificClaims(verified.payload, isOidc: isOidc);
      return true;
    } catch (error) {
      _log.warning('JWT verification failed: $error');
      return false;
    }
  }

  void _verifyModeSpecificClaims(Object? payload, {required bool isOidc}) {
    if (_audience.mode != GoogleChatAudienceMode.appUrl) {
      return;
    }
    if (payload is! Map) {
      throw const FormatException('JWT payload must be an object');
    }

    // OIDC tokens from new GCP Console apps don't carry the legacy email
    // claim — audience + issuer verification is sufficient.
    if (isOidc) return;

    final email = payload['email'];
    if (email != expectedIssuer) {
      throw StateError('JWT email claim did not match expected Google Chat identity');
    }

    if (payload['email_verified'] != true) {
      throw StateError('JWT email_verified claim was not true');
    }
  }

  Uri _resolvedCertsUrl({required bool isOidc}) {
    if (_certsUrlOverride != null) {
      return _certsUrlOverride;
    }
    if (isOidc) return googleOidcCertsUrl;
    return switch (_audience.mode) {
      GoogleChatAudienceMode.appUrl => googleCertsUrl,
      GoogleChatAudienceMode.projectNumber => chatServiceAccountCertsUrl,
    };
  }

  Future<Map<String, RSAPublicKey>> _fetchCerts({required bool isOidc}) async {
    final now = _now();
    final cacheKey = isOidc ? 'oidc' : 'legacy';
    final cached = _certCaches[cacheKey];
    if (cached != null && cached.expiry.isAfter(now)) {
      return cached.certs;
    }

    final url = _resolvedCertsUrl(isOidc: isOidc);
    final response = await _httpClient.get(url);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError('Certificate fetch failed with HTTP ${response.statusCode}');
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! Map) {
      throw const FormatException('Certificate response must be a JSON object');
    }

    // JWK format (v3): { "keys": [{ "kid": "...", "n": "...", "e": "..." }] }
    // PEM format (v1): { "kid": "PEM cert string" }
    final certs = decoded.containsKey('keys') ? _parseJwkKeys(decoded) : _parsePemCerts(decoded);
    if (certs.isEmpty) {
      throw const FormatException('No certificates found in response');
    }

    _certCaches[cacheKey] = _CertCacheEntry(certs, now.add(_cacheTtl));
    _log.fine('Fetched ${isOidc ? "OIDC" : "legacy"} Google certs, ${certs.length} keys cached');
    return certs;
  }

  static Map<String, RSAPublicKey> _parsePemCerts(Map<dynamic, dynamic> data) {
    final certs = <String, RSAPublicKey>{};
    for (final entry in data.entries) {
      final kid = entry.key;
      final value = entry.value;
      if (kid is String && value is String) {
        certs[kid] = RSAPublicKey.cert(value);
      }
    }
    return certs;
  }

  static Map<String, RSAPublicKey> _parseJwkKeys(Map<dynamic, dynamic> data) {
    final keys = data['keys'];
    if (keys is! List) return {};
    final certs = <String, RSAPublicKey>{};
    for (final key in keys) {
      if (key is! Map) continue;
      final kid = key['kid'] as String?;
      final kty = key['kty'] as String?;
      final n = key['n'] as String?;
      final e = key['e'] as String?;
      if (kid == null || kty != 'RSA' || n == null || e == null) continue;
      final modulus = _base64UrlToBigInt(n);
      final exponent = _base64UrlToBigInt(e);
      certs[kid] = RSAPublicKey.raw(pc.RSAPublicKey(modulus, exponent));
    }
    return certs;
  }

  static BigInt _base64UrlToBigInt(String b64) {
    final bytes = base64Url.decode(base64Url.normalize(b64));
    return _bytesToBigInt(Uint8List.fromList(bytes));
  }

  static BigInt _bytesToBigInt(Uint8List bytes) {
    var result = BigInt.zero;
    for (final byte in bytes) {
      result = (result << 8) | BigInt.from(byte);
    }
    return result;
  }

  void invalidateCache() {
    _certCaches.clear();
  }
}

class _CertCacheEntry {
  final Map<String, RSAPublicKey> certs;
  final DateTime expiry;
  _CertCacheEntry(this.certs, this.expiry);
}
