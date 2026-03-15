import 'dart:io';

import 'package:path/path.dart' as p;

/// Expands a leading `~` or `~/` to the user's home directory.
///
/// When [env] is null, reads from [Platform.environment].
String expandHome(String path, {Map<String, String>? env}) {
  if (!path.startsWith('~/') && path != '~') return path;
  final envMap = env ?? Platform.environment;
  final home = envMap['HOME'] ?? envMap['USERPROFILE'] ?? '';
  if (home.isEmpty) return path;
  return path == '~' ? home : p.join(home, path.substring(2));
}
