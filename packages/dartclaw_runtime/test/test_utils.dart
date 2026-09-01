import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

final Future<String> _packageRoot = _resolvePackageRoot();

Future<String> _resolvePackageRoot() async {
  final library = await Isolate.resolvePackageUri(Uri.parse('package:dartclaw_runtime/dartclaw_runtime.dart'));
  if (library == null || !library.isScheme('file')) {
    throw StateError('Could not resolve dartclaw_runtime package root');
  }
  return File.fromUri(library).parent.parent.path;
}

Future<String> resolveServerPackageRoot() => _packageRoot;

Future<String> resolveServerPackagePath(String first, [String? second, String? third, String? fourth]) async {
  return p.joinAll([await _packageRoot, first, ?second, ?third, ?fourth]);
}

Future<String> resolveWorkspacePath(String first, [String? second, String? third]) async =>
    p.joinAll([Directory(await _packageRoot).parent.parent.path, first, ?second, ?third]);

Future<String> resolveTemplatesDir() => resolveServerPackagePath('lib', 'src', 'templates');

Future<String> resolveStaticDir() => resolveServerPackagePath('lib', 'src', 'static');

Future<String> resolveDesignSystemCss(String name) => resolveWorkspacePath('dev', 'design-system', name);
