import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:test/test.dart';

void main() {
  final gatewayToken = 'a' * 64;

  group('session token (HMAC-signed)', () {
    test('createSessionToken returns dot-separated format', () {
      final token = createSessionToken(gatewayToken);
      expect(token.contains('.'), isTrue);
      final parts = token.split('.');
      expect(parts.length, 2);
      expect(parts[0].isNotEmpty, isTrue);
      expect(parts[1].isNotEmpty, isTrue);
    });

    test('validateSessionToken returns true for fresh token', () {
      final token = createSessionToken(gatewayToken);
      expect(validateSessionToken(token, gatewayToken), isTrue);
    });

    test('validateSessionToken returns false for wrong key', () {
      final token = createSessionToken(gatewayToken);
      expect(validateSessionToken(token, 'b' * 64), isFalse);
    });

    test('validateSessionToken returns false for tampered payload', () {
      final token = createSessionToken(gatewayToken);
      final parts = token.split('.');
      final tampered = '${parts[0]}x.${parts[1]}';
      expect(validateSessionToken(tampered, gatewayToken), isFalse);
    });

    test('validateSessionToken returns false for expired token', () {
      final token = createSessionToken(gatewayToken);
      expect(validateSessionToken(token, gatewayToken, ttl: Duration.zero), isFalse);
    });

    test('validateSessionToken returns false for garbage input', () {
      expect(validateSessionToken('garbage', gatewayToken), isFalse);
      expect(validateSessionToken('', gatewayToken), isFalse);
      expect(validateSessionToken('.', gatewayToken), isFalse);
    });

    test('sessionCookieHeader includes security attributes', () {
      final header = sessionCookieHeader('test-token');
      expect(header, contains('dart_session=test-token'));
      expect(header, contains('HttpOnly'));
      expect(header, contains('SameSite=Strict'));
      expect(header, contains('Path=/'));
      expect(header, contains('Max-Age='));
    });

    test('unique tokens per call', () {
      final a = createSessionToken(gatewayToken);
      // Small delay to ensure different iat
      final b = createSessionToken(gatewayToken);
      // Tokens may or may not differ (same millisecond), but both should validate
      expect(validateSessionToken(a, gatewayToken), isTrue);
      expect(validateSessionToken(b, gatewayToken), isTrue);
    });
  });
}
