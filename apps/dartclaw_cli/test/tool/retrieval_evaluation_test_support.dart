import 'dart:isolate';

import 'package:path/path.dart' as p;

Future<String> resolveRetrievalEvaluationRepositoryRoot() async {
  final uri = await Isolate.resolvePackageUri(Uri.parse('package:dartclaw_cli/src/runner.dart'));
  if (uri == null) throw StateError('Could not resolve package:dartclaw_cli.');
  final packageRoot = p.dirname(p.dirname(p.dirname(uri.toFilePath())));
  return p.dirname(p.dirname(packageRoot));
}
