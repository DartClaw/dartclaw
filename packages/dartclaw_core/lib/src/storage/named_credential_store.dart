import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:path/path.dart' as p;

import 'atomic_write.dart';
import 'login_store_guard.dart';

/// DartClaw-owned store of operator-named credentials.
///
/// One JSON file per name under `<credentialsDir>/named/`, owner-only, holding
/// `{"type": "api-key"|"github-token", "secret": "…", "repository": "…"}` with
/// `repository` present only for a GitHub token. Protection is file
/// permissions: nothing here encrypts, and nothing here touches an OS keychain.
///
/// A missing, malformed, or shape-less file reads as an absent credential,
/// never a throw — the same contract [SubscriptionCredentialStore] keeps.
class NamedCredentialStore {
  /// The only shape a stored name may take.
  ///
  /// The store is addressed by filename, so an unvalidated name taken from argv
  /// is an arbitrary-path write.
  static final RegExp namePattern = RegExp(r'^[a-z0-9][a-z0-9_-]{0,63}$');

  /// Store identity in a [LoginStoreCollisionError] refusal.
  static const _storeId = 'named';

  static const _apiKeyType = 'api-key';
  static const _githubTokenType = 'github-token';

  final String _credentialsDir;

  new _(this._credentialsDir);

  /// Opens the named store under [credentialsDir], creating it owner-only.
  ///
  /// Throws [LoginStoreCollisionError] — before any credential is read — when
  /// the store resolves onto one of the operator's login paths.
  factory open({required String credentialsDir, Map<String, String>? environment}) {
    return _open(credentialsDir: credentialsDir, environment: environment, provision: true);
  }

  /// Opens the named store for inspection without creating or chmodding paths.
  ///
  /// The login-store collision refusal still runs before any credential read.
  factory readOnly({required String credentialsDir, Map<String, String>? environment}) {
    return _open(credentialsDir: credentialsDir, environment: environment, provision: false);
  }

  static NamedCredentialStore _open({
    required String credentialsDir,
    required Map<String, String>? environment,
    required bool provision,
  }) {
    final store = NamedCredentialStore._(credentialsDir);
    refuseLoginStoreCollision(_storeId, [
      credentialsDir,
      store.namedDir,
    ], operatorLoginPaths(environment ?? Platform.environment));
    if (!provision) return store;
    // Only a directory this call creates is chmodded: the store is opened on
    // every config load, and `chmodOwnerOnlyDirSync` spawns `chmod`. A
    // directory loosened after creation is reported by `dartclaw secrets audit`
    // rather than silently repaired on a read path.
    for (final path in [credentialsDir, store.namedDir]) {
      final directory = Directory(path);
      if (directory.existsSync()) continue;
      directory.createSync(recursive: true);
      chmodOwnerOnlyDirSync(path);
    }
    return store;
  }

  /// Whether [name] is a storable credential name.
  static bool isValidName(String name) => namePattern.hasMatch(name);

  /// Directory holding one file per named credential.
  String get namedDir => p.join(_credentialsDir, _storeId);

  /// On-disk path of the entry called [name].
  ///
  /// Throws [ArgumentError] when [name] is not a storable name, so no caller
  /// can build a path from operator input the pattern would refuse.
  String pathFor(String name) {
    if (!isValidName(name)) {
      throw ArgumentError.value(name, 'name', 'must match ${namePattern.pattern}');
    }
    return p.join(namedDir, '$name.json');
  }

  /// Snapshot of every readable stored entry, keyed by name.
  Map<String, CredentialEntry> readAll() {
    final directory = Directory(namedDir);
    if (!directory.existsSync()) return const {};
    final entries = <String, CredentialEntry>{};
    for (final file in directory.listSync().whereType<File>()) {
      final name = p.basenameWithoutExtension(file.path);
      if (p.extension(file.path) != '.json' || !isValidName(name)) continue;
      final entry = _readFile(file);
      if (entry != null) entries[name] = entry;
    }
    return entries;
  }

  /// Reads the entry called [name].
  ///
  /// Returns `null` — never throws — when [name] is not a storable name, or
  /// when the file is missing, unreadable, malformed, or carries no usable
  /// type/secret pair.
  CredentialEntry? read(String name) {
    if (!isValidName(name)) return null;
    return _readFile(File(pathFor(name)));
  }

  /// Stores [entry] under [name], replacing any existing entry silently.
  ///
  /// Throws [ArgumentError] when [name] is not a storable name or [entry] is a
  /// type this store does not hold.
  void write(String name, CredentialEntry entry) {
    final path = pathFor(name);
    final type = switch (entry.type) {
      CredentialType.apiKey => _apiKeyType,
      CredentialType.githubToken => _githubTokenType,
      CredentialType.subscription => throw ArgumentError.value(
        entry.type.name,
        'entry',
        'subscription credentials live in the dedicated per-provider stores',
      ),
    };
    final repository = entry.repository?.trim();
    secureWriteFileSync(
      File(path),
      jsonEncode({
        'type': type,
        'secret': entry.secret,
        if (entry.type == CredentialType.githubToken && repository != null && repository.isNotEmpty)
          'repository': repository,
      }),
    );
  }

  /// Removes the entry called [name], answering whether one was there.
  ///
  /// Answers `false` — never throws — for a name this store cannot hold.
  bool remove(String name) {
    if (!isValidName(name)) return false;
    final file = File(pathFor(name));
    if (!file.existsSync()) return false;
    file.deleteSync();
    return true;
  }

  /// A file that cannot be read as an entry is an absent one: an operator
  /// editing the store by hand must not take the whole instance down.
  CredentialEntry? _readFile(File file) {
    try {
      if (!file.existsSync()) return null;
      final record = jsonDecode(file.readAsStringSync());
      if (record is! Map) return null;
      final secret = record['secret'];
      if (secret is! String || secret.isEmpty) return null;
      final repositoryRaw = record['repository'];
      final repository = repositoryRaw is String && repositoryRaw.trim().isNotEmpty ? repositoryRaw.trim() : null;
      return switch (record['type']) {
        _apiKeyType => CredentialEntry(apiKey: secret),
        _githubTokenType => CredentialEntry.githubToken(token: secret, repository: repository),
        _ => null,
      };
    } on FormatException {
      return null;
    } on FileSystemException {
      return null;
    }
  }
}
