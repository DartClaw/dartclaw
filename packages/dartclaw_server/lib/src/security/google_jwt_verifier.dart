import 'dart:convert';

import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'package:dartclaw_google_chat/dartclaw_google_chat.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

class GoogleJwtVerifier {
  static final Uri googleCertsUrl = Uri.parse('https://www.googleapis.com/oauth2/v1/certs');
  static final Uri chatServiceAccountCertsUrl = Uri.parse(
    'https://www.googleapis.com/service_accounts/v1/metadata/x509/chat%40system.gserviceaccount.com',
  );
  static const String expectedIssuer = 'chat@system.gserviceaccount.com';

  final GoogleChatAudienceConfig _audience;
  final http.Client _httpClient;
  final Duration _cacheTtl;
  final DateTime Function() _now;
  final Uri? _certsUrlOverride;
  final Logger _log = Logger('GoogleJwtVerifier');

  Map<String, RSAPublicKey>? _certCache;
  DateTime? _cacheExpiry;

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

      final certs = await _fetchCerts();
      final key = certs[kid];
      if (key == null) {
        _log.warning('JWT verification failed: unknown key id "$kid"');
        return false;
      }

      final verified = JWT.verify(
        token,
        key,
        issuer: expectedIssuer,
        audience: Audience.one(_audience.value),
        checkHeaderType: false,
      );
      _verifyModeSpecificClaims(verified.payload);
      return true;
    } catch (error) {
      _log.warning('JWT verification failed: $error');
      return false;
    }
  }

  void _verifyModeSpecificClaims(Object? payload) {
    if (_audience.mode != GoogleChatAudienceMode.appUrl) {
      return;
    }
    if (payload is! Map) {
      throw const FormatException('JWT payload must be an object');
    }

    final email = payload['email'];
    if (email != expectedIssuer) {
      throw StateError('JWT email claim did not match expected Google Chat identity');
    }

    if (payload['email_verified'] != true) {
      throw StateError('JWT email_verified claim was not true');
    }
  }

  Uri get _resolvedCertsUrl {
    if (_certsUrlOverride != null) {
      return _certsUrlOverride;
    }
    return switch (_audience.mode) {
      GoogleChatAudienceMode.appUrl => googleCertsUrl,
      GoogleChatAudienceMode.projectNumber => chatServiceAccountCertsUrl,
    };
  }

  Future<Map<String, RSAPublicKey>> _fetchCerts() async {
    final now = _now();
    final cache = _certCache;
    final expiry = _cacheExpiry;
    if (cache != null && expiry != null && expiry.isAfter(now)) {
      return cache;
    }

    final response = await _httpClient.get(_resolvedCertsUrl);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError('Certificate fetch failed with HTTP ${response.statusCode}');
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! Map) {
      throw const FormatException('Certificate response must be a JSON object');
    }

    final certs = <String, RSAPublicKey>{};
    for (final entry in decoded.entries) {
      final kid = entry.key;
      final value = entry.value;
      if (kid is String && value is String) {
        certs[kid] = RSAPublicKey.cert(value);
      }
    }
    if (certs.isEmpty) {
      throw const FormatException('No certificates found in response');
    }

    _certCache = certs;
    _cacheExpiry = now.add(_cacheTtl);
    _log.fine('Fetched Google certs, ${certs.length} keys cached');
    return certs;
  }

  void invalidateCache() {
    _certCache = null;
    _cacheExpiry = null;
  }
}
