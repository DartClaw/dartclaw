import 'dart:io';

import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:path/path.dart' as p;

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

/// Every path the operator's interactive logins can occupy, symlink-resolved.
///
/// A relocation variable does not retire the default home location, which can
/// still hold a login, so both are guarded. The macOS Keychain item is
/// unreachable by path and is protected by never being touched instead.
List<String> operatorLoginPaths(Map<String, String> environment) => [
  ..._loginPaths(environment, 'CODEX_HOME', '.codex', 'auth.json'),
  ..._loginPaths(environment, 'CLAUDE_CONFIG_DIR', '.claude', '.credentials.json'),
].map(resolveThroughSymlinks).toList();

List<String> _loginPaths(
  Map<String, String> environment,
  String relocationVar,
  String homeDirName,
  String credentialFile,
) {
  final relocated = environment[relocationVar]?.trim();
  final home = PlatformCapabilities(environment: environment).homeDirectory;
  return [
    if (relocated != null && relocated.isNotEmpty) relocated,
    if (home != null) p.join(home, homeDirName),
  ].expand((directory) => [directory, p.join(directory, credentialFile)]).toList();
}

/// Throws [LoginStoreCollisionError] when any of [dedicated] resolves onto one
/// of [login].
///
/// Every dedicated path is compared against *every* operator login path, not
/// just the same provider's: a Claude store aliased onto `~/.codex` would
/// otherwise be written to unrefused.
void refuseLoginStoreCollision(String providerId, List<String> dedicated, List<String> login) {
  for (final dedicatedPath in dedicated.map(resolveThroughSymlinks)) {
    for (final loginPath in login) {
      if (dedicatedPath == loginPath || p.isWithin(loginPath, dedicatedPath) || p.isWithin(dedicatedPath, loginPath)) {
        throw LoginStoreCollisionError(providerId: providerId, dedicatedPath: dedicatedPath, loginPath: loginPath);
      }
    }
  }
}

/// Resolves [path] through symlinks, keeping any not-yet-created tail, so a
/// symlinked alias of a login store compares equal to the store itself.
String resolveThroughSymlinks(String path) {
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
