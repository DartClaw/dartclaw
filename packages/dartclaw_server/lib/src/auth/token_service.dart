import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import 'auth_utils.dart';

/// Manages the gateway authentication token.
///
/// The token is a 64-character hex string generated from 32 cryptographically
/// secure random bytes. It is persisted to a `gateway_token` file in the
/// data directory.
class TokenService {
  String? _token;

  TokenService({String? token}) : _token = token;

  /// Returns the current token, generating one if not yet set.
  String get token => _token ??= generate();

  /// Generates a 64-character hex string from 32 secure random bytes.
  static String generate() {
    final rng = Random.secure();
    final bytes = List<int>.generate(32, (_) => rng.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Loads token from `$dataDir/gateway_token`. Returns null if missing.
  static String? loadFromFile(String dataDir) {
    final file = File(p.join(dataDir, 'gateway_token'));
    if (!file.existsSync()) return null;
    final content = file.readAsStringSync().trim();
    return content.isEmpty ? null : content;
  }

  /// Persists [token] to `$dataDir/gateway_token` via atomic write.
  /// Sets file mode to 600 on non-Windows platforms.
  static void persistToFile(String dataDir, String token) {
    final target = File(p.join(dataDir, 'gateway_token'));
    final temp = File('${target.path}.tmp');
    temp.writeAsStringSync(token);
    temp.renameSync(target.path);
    if (!Platform.isWindows) {
      try {
        Process.runSync('chmod', ['600', target.path]);
      } catch (e) {
        // chmod not available — non-critical
      }
    }
  }

  /// Generates a new token, persists it, and returns it.
  static String rotateToken(String dataDir) {
    final newToken = generate();
    persistToFile(dataDir, newToken);
    return newToken;
  }

  /// Constant-time comparison to prevent timing attacks.
  bool validateToken(String candidate) => constantTimeEquals(candidate, token);
}
