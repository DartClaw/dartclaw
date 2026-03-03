import 'dart:io';

import 'package:path/path.dart' as p;

/// Resolves the templates directory whether tests run from the package root
/// (`packages/dartclaw_server/`) or the workspace root.
String resolveTemplatesDir() {
  const fromPkg = 'lib/src/templates';
  if (Directory(fromPkg).existsSync()) return fromPkg;
  return p.join('packages', 'dartclaw_server', fromPkg);
}
