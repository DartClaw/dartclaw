import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:path/path.dart' as p;

import 'atomic_write.dart';

/// Refusal of a dedicated store that resolves onto an operator login store.
class LoginStoreCollisionError implements Exception {
  /// Provider whose dedicated store collided.
  final String providerId;

  /// Symlink-resolved dedicated store path.
  final String dedicatedPath;

  /// Symlink-resolved operator login path it collides with.
  final String loginPath;

  /// Creates a collision refusal naming both sides.
  const new({required this.providerId, required this.dedicatedPath, required this.loginPath});

  @override
  String toString() =>
      'Dedicated $providerId credential store "$dedicatedPath" resolves onto the operator login store '
      '"$loginPath". Point data_dir (or --data-dir), CODEX_HOME or CLAUDE_CONFIG_DIR somewhere distinct.';
}

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
    final store = SubscriptionCredentialStore._(credentialsDir, environment ?? Platform.environment);
    store._guardLoginStores();
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

  /// Every dedicated path is compared against *every* operator login path, not
  /// just the same provider's: a Claude store aliased onto `~/.codex` would
  /// otherwise be written to unrefused.
  void _guardLoginStores() {
    final login = [
      ..._loginPaths('CODEX_HOME', '.codex', 'auth.json'),
      ..._loginPaths('CLAUDE_CONFIG_DIR', '.claude', '.credentials.json'),
    ].map(_resolve).toList();
    _refuseCollision(ProviderIdentity.claude, [claudeDir, claudeTokenPath], login);
    _refuseCollision(ProviderIdentity.codex, [codexHome, codexAuthPath], login);
  }

  /// Paths the operator's interactive login can occupy. A relocation variable
  /// does not retire the default home location, which can still hold a login,
  /// so both are guarded. The macOS Keychain item is unreachable by path and is
  /// protected by never being touched instead.
  List<String> _loginPaths(String relocationVar, String homeDirName, String credentialFile) {
    final relocated = _environment[relocationVar]?.trim();
    final home = PlatformCapabilities(environment: _environment).homeDirectory;
    return [
      if (relocated != null && relocated.isNotEmpty) relocated,
      if (home != null) p.join(home, homeDirName),
    ].expand((directory) => [directory, p.join(directory, credentialFile)]).toList();
  }

  static void _refuseCollision(String providerId, List<String> dedicated, List<String> login) {
    for (final dedicatedPath in dedicated.map(_resolve)) {
      for (final loginPath in login) {
        if (dedicatedPath == loginPath ||
            p.isWithin(loginPath, dedicatedPath) ||
            p.isWithin(dedicatedPath, loginPath)) {
          throw LoginStoreCollisionError(providerId: providerId, dedicatedPath: dedicatedPath, loginPath: loginPath);
        }
      }
    }
  }

  /// Resolves [path] through symlinks, keeping any not-yet-created tail, so a
  /// symlinked alias of a login store compares equal to the store itself.
  static String _resolve(String path) {
    var head = p.normalize(p.absolute(path));
    final tail = <String>[];
    while (FileSystemEntity.typeSync(head) == FileSystemEntityType.notFound) {
      final parent = p.dirname(head);
      if (parent == head) return p.joinAll([head, ...tail]);
      tail.insert(0, p.basename(head));
      head = parent;
    }
    return p.normalize(p.joinAll([Directory(head).resolveSymbolicLinksSync(), ...tail]));
  }
}
