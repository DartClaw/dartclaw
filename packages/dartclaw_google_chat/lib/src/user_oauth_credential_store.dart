import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Stored user OAuth credentials for Workspace Events API access.
class StoredUserCredentials {
  final String clientId;
  final String clientSecret;
  final String refreshToken;
  final List<String> scopes;
  final DateTime createdAt;

  const StoredUserCredentials({
    required this.clientId,
    required this.clientSecret,
    required this.refreshToken,
    required this.scopes,
    required this.createdAt,
  });

  factory StoredUserCredentials.fromJson(Map<String, dynamic> json) {
    return StoredUserCredentials(
      clientId: json['clientId'] as String,
      clientSecret: json['clientSecret'] as String,
      refreshToken: json['refreshToken'] as String,
      scopes: (json['scopes'] as List<dynamic>).cast<String>(),
      createdAt: DateTime.parse(json['createdAt'] as String),
    );
  }

  Map<String, dynamic> toJson() => {
    'clientId': clientId,
    'clientSecret': clientSecret,
    'refreshToken': refreshToken,
    'scopes': scopes,
    'createdAt': createdAt.toUtc().toIso8601String(),
  };
}

/// File-based storage for user OAuth credentials with restricted permissions.
///
/// Stores credentials in `$dataDir/google-chat-user-oauth.json` using atomic
/// writes (temp file + rename) and `chmod 600` on non-Windows platforms.
class UserOAuthCredentialStore {
  static const _fileName = 'google-chat-user-oauth.json';

  final String _dataDir;

  UserOAuthCredentialStore({required String dataDir}) : _dataDir = dataDir;

  /// Path to the credentials file.
  String get filePath => p.join(_dataDir, _fileName);

  /// Whether stored credentials exist on disk.
  bool get hasCredentials => File(filePath).existsSync();

  /// Loads stored credentials. Returns `null` if missing or corrupt.
  StoredUserCredentials? load() {
    final file = File(filePath);
    if (!file.existsSync()) return null;
    try {
      final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      return StoredUserCredentials.fromJson(json);
    } catch (_) {
      return null;
    }
  }

  /// Persists credentials via atomic write with restricted file permissions.
  void save(StoredUserCredentials credentials) {
    final dir = Directory(_dataDir);
    if (!dir.existsSync()) dir.createSync(recursive: true);

    final target = File(filePath);
    final temp = File('${target.path}.tmp');
    temp.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(credentials.toJson()),
    );
    temp.renameSync(target.path);

    if (!Platform.isWindows) {
      try {
        Process.runSync('chmod', ['600', target.path]);
      } catch (_) {
        // chmod not available — non-critical.
      }
    }
  }

  /// Deletes stored credentials. Returns `true` if file existed.
  bool delete() {
    final file = File(filePath);
    if (!file.existsSync()) return false;
    file.deleteSync();
    return true;
  }
}
