import 'dart:io';

import 'package:dartclaw_runtime/dartclaw_runtime.dart';
import 'package:test/test.dart';

void main() {
  group('TokenService', () {
    test('generate produces 64-char hex string', () {
      final token = TokenService.generate();
      expect(token.length, 64);
      expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(token), isTrue);
    });

    test('generate produces unique tokens', () {
      final a = TokenService.generate();
      final b = TokenService.generate();
      expect(a, isNot(b));
    });

    test('token getter auto-generates if not provided', () {
      final service = TokenService();
      final token = service.token;
      expect(token.length, 64);
      // Same token on subsequent calls
      expect(service.token, token);
    });

    test('token getter returns provided token', () {
      final service = TokenService(token: 'abc123');
      expect(service.token, 'abc123');
    });

    test('loadFromFile returns null for missing file', () {
      final tempDir = Directory.systemTemp.createTempSync('token_test_');
      addTearDown(() => tempDir.deleteSync(recursive: true));
      expect(TokenService.loadFromFile(tempDir.path), isNull);
    });

    test('persistToFile + loadFromFile round-trip', () {
      final tempDir = Directory.systemTemp.createTempSync('token_test_');
      addTearDown(() => tempDir.deleteSync(recursive: true));

      const token = 'a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2';
      TokenService.persistToFile(tempDir.path, token);

      final loaded = TokenService.loadFromFile(tempDir.path);
      expect(loaded, token);
    });

    test('rotateToken generates and persists new token', () {
      final tempDir = Directory.systemTemp.createTempSync('token_test_');
      addTearDown(() => tempDir.deleteSync(recursive: true));

      final newToken = TokenService.rotateToken(tempDir.path);
      expect(newToken.length, 64);
      expect(TokenService.loadFromFile(tempDir.path), newToken);
    });

    group('validateToken', () {
      test('returns true for matching token', () {
        final service = TokenService(token: 'secret123');
        expect(service.validateToken('secret123'), isTrue);
      });

      test('returns false for wrong token', () {
        final service = TokenService(token: 'secret123');
        expect(service.validateToken('wrong456'), isFalse);
      });

      test('returns false for different length', () {
        final service = TokenService(token: 'secret123');
        expect(service.validateToken('short'), isFalse);
      });

      // `Authorization: Bearer ` and `?token=` both arrive as an empty
      // candidate. Neither may authenticate against any configured token.
      test('returns false for an empty candidate', () {
        final service = TokenService(token: 'secret123');
        expect(service.validateToken(''), isFalse);
      });

      test('returns false for an empty candidate against a generated token', () {
        expect(TokenService().validateToken(''), isFalse);
      });
    });

    group('blank configured token', () {
      // A blank token is what an unresolvable `\${DARTCLAW_TOKEN}` degrades
      // into. It authenticates an empty bearer header and signs session cookies
      // with an empty HMAC key, so it must never reach the auth pipeline.
      test('constructor rejects an empty token', () {
        expect(() => TokenService(token: ''), throwsArgumentError);
      });

      test('constructor rejects a whitespace-only token', () {
        expect(() => TokenService(token: '   '), throwsArgumentError);
      });

      test('omitted token still generates rather than throwing', () {
        expect(TokenService().token.length, 64);
      });
    });
  });
}
