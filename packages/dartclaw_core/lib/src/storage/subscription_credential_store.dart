import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:path/path.dart' as p;

import 'atomic_write.dart';
import 'login_store_guard.dart';

/// DartClaw-owned per-provider subscription credential stores.
///
/// DartClaw is the single owner of these stores; the operator's interactive
/// login (`~/.claude`, `~/.codex`, the macOS Keychain item) is never read,
/// written, or probed. A missing or unreadable store reads as an absent
/// credential so admission can fail closed rather than crash.
class SubscriptionCredentialStore {
  /// Documented `setup-token` lifetime, from which the Claude expiry is derived.
  static const claudeTokenLifetime = Duration(days: 365);

  /// 2100-01-01T00:00:00Z — the upper bound for a credible `exp` claim.
  static const _maxExpirySeconds = 4102444800;

  final String _credentialsDir;
  final Map<String, String> _environment;

  new _(this._credentialsDir, this._environment);

  /// Opens the stores under [credentialsDir], creating owner-only directories.
  ///
  /// Throws [LoginStoreCollisionError] — before any credential is read — when a
  /// dedicated path resolves onto one of the operator's login paths.
  factory open({required String credentialsDir, Map<String, String>? environment}) {
    return _open(credentialsDir: credentialsDir, environment: environment, provision: true);
  }

  /// Opens for inspection without creating or chmodding paths.
  /// Throws [LoginStoreCollisionError] before reading a colliding login store.
  factory readOnly({required String credentialsDir, Map<String, String>? environment}) {
    return _open(credentialsDir: credentialsDir, environment: environment, provision: false);
  }

  static SubscriptionCredentialStore _open({
    required String credentialsDir,
    required Map<String, String>? environment,
    required bool provision,
  }) {
    final store = SubscriptionCredentialStore._(credentialsDir, environment ?? Platform.environment);
    store._guardLoginStores();
    if (!provision) return store;
    for (final path in [credentialsDir, store.claudeDir, store.codexHome]) {
      final directory = Directory(path);
      if (!directory.existsSync()) directory.createSync(recursive: true);
      chmodOwnerOnlyDirSync(path);
    }
    return store;
  }

  /// Dedicated Claude store directory.
  String get claudeDir => p.join(_credentialsDir, ProviderIdentity.claude);

  /// Dedicated Claude `setup-token` record.
  String get claudeTokenPath => p.join(claudeDir, 'setup-token.json');

  /// Dedicated `CODEX_HOME` the vendor CLI logs into and refreshes.
  String get codexHome => p.join(_credentialsDir, ProviderIdentity.codex);

  /// Dedicated Codex `auth.json`, written by the vendor CLI.
  String get codexAuthPath => p.join(codexHome, 'auth.json');

  /// Stores a Claude `setup-token` issued at [issuedAt] (defaults to now).
  ///
  /// Throws [ArgumentError] when [token] is blank.
  void storeClaudeSetupToken(String token, {DateTime? issuedAt}) {
    final trimmed = token.trim();
    if (trimmed.isEmpty) throw ArgumentError.value(token, 'token', 'must not be blank');
    final issued = (issuedAt ?? DateTime.now()).toUtc();
    secureWriteFileSync(File(claudeTokenPath), jsonEncode({'token': trimmed, 'issued_at': issued.toIso8601String()}));
  }

  /// Snapshot of the stored subscription credentials, keyed by provider family.
  Map<String, CredentialEntry> readAll() => {
    for (final family in const [ProviderIdentity.claude, ProviderIdentity.codex]) family: ?read(family),
  };

  /// Reads the subscription credential for [providerFamily].
  ///
  /// Returns `null` — never throws — when [providerFamily] is blank or names no
  /// store, or when the store is missing, unreadable, malformed, or holds no
  /// token. A blank family resolves to no credential rather than defaulting to a
  /// provider the caller did not name. A returned entry may carry a null expiry
  /// (see [_readClaude]); consumers classify that as unknown health rather than
  /// as an absent credential.
  CredentialEntry? read(String providerFamily) {
    if (providerFamily.trim().isEmpty) return null;
    try {
      return switch (ProviderIdentity.family(providerFamily)) {
        ProviderIdentity.claude => _readClaude(),
        ProviderIdentity.codex => _readCodex(),
        _ => null,
      };
    } on FormatException {
      return null;
    } on FileSystemException {
      return null;
    }
  }

  /// The `setup-token` carries no expiry claim, so its expiry is derived from
  /// the recorded issue time plus the documented lifetime.
  ///
  /// A record whose issue time is missing or unparseable still yields the token,
  /// with no expiry: the token may well work, and reporting it absent would page
  /// the operator to re-authenticate a credential this store is holding.
  CredentialEntry? _readClaude() {
    final file = File(claudeTokenPath);
    if (!file.existsSync()) return null;
    final record = jsonDecode(file.readAsStringSync());
    final token = record is Map ? record['token'] : null;
    if (token is! String || token.isEmpty) return null;
    final issuedAt = record is Map ? DateTime.tryParse('${record['issued_at']}') : null;
    if (issuedAt == null) return CredentialEntry.subscription(token: token);
    return CredentialEntry.subscription(
      token: token,
      expiry: CredentialExpiry(
        issuedAt: issuedAt.toUtc(),
        expiresAt: issuedAt.toUtc().add(claudeTokenLifetime),
        derived: true,
      ),
    );
  }

  /// The dedicated Codex store exactly as the vendor CLI last persisted it.
  ///
  /// Returns `null` — never throws — when the store is missing, unreadable,
  /// malformed, or holds no access token whose expiry can be resolved. The
  /// refresh token is deliberately not read: the vendor CLI is its only
  /// consumer, and a value DartClaw never holds cannot leak from DartClaw.
  /// `lastRefresh` is the vendor's own record of its last rotation, which is
  /// how a spent refresh token is told apart from one that merely failed to
  /// reach the endpoint.
  ({String accessToken, String? accountId, DateTime expiresAt, DateTime? lastRefresh})? readCodexAuth() {
    try {
      final file = File(codexAuthPath);
      if (!file.existsSync()) return null;
      final record = jsonDecode(file.readAsStringSync());
      final tokens = record is Map ? record['tokens'] : null;
      final token = tokens is Map ? tokens['access_token'] : null;
      if (token is! String || token.isEmpty) return null;
      final expiresAt = _jwtExpiry(token);
      if (expiresAt == null) return null;
      final accountId = tokens is Map ? tokens['account_id'] : null;
      return (
        accessToken: token,
        accountId: accountId is String && accountId.trim().isNotEmpty ? accountId : null,
        expiresAt: expiresAt,
        lastRefresh: record is Map ? DateTime.tryParse('${record['last_refresh']}')?.toUtc() : null,
      );
    } on FormatException {
      return null;
    } on FileSystemException {
      return null;
    }
  }

  /// The ChatGPT access token is a JWT, so its expiry is read exactly from the
  /// `exp` claim rather than estimated; the issue time is the store's last
  /// write, since the vendor CLI owns the record's contents.
  CredentialEntry? _readCodex() {
    final auth = readCodexAuth();
    if (auth == null) return null;
    return CredentialEntry.subscription(
      token: auth.accessToken,
      expiry: CredentialExpiry(
        issuedAt: File(codexAuthPath).lastModifiedSync().toUtc(),
        expiresAt: auth.expiresAt,
        derived: false,
      ),
    );
  }

  static DateTime? _jwtExpiry(String jwt) {
    final segments = jwt.split('.');
    if (segments.length != 3) return null;
    final payload = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(segments[1]))));
    final exp = payload is Map ? payload['exp'] : null;
    // `exp` is epoch *seconds* (RFC 7519). Anything outside a plausible range —
    // a millisecond-scaled claim, a negative, or a value that would overflow
    // DateTime — is an unreadable expiry, not an absurd "exact" one.
    if (exp is! int || exp <= 0 || exp > _maxExpirySeconds) return null;
    return DateTime.fromMillisecondsSinceEpoch(exp * 1000, isUtc: true);
  }

  void _guardLoginStores() {
    final login = operatorLoginPaths(_environment);
    refuseLoginStoreCollision(ProviderIdentity.claude, [claudeDir, claudeTokenPath], login);
    refuseLoginStoreCollision(ProviderIdentity.codex, [codexHome, codexAuthPath], login);
  }
}
