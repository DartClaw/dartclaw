import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:path/path.dart' as p;

/// Command that rewrites the committed artifact. Named in the drift failure so
/// a contributor never has to look it up.
const String configSchemaRegenerationCommand = 'dart run packages/dartclaw_kernel/tool/generate_config_schema.dart';

/// Config files DartClaw ships, relative to the repo root.
///
/// These are what an operator copies from, so an emitted schema that flags one
/// of them is a defect in the schema rather than in the file.
const List<String> shippedConfigCorpus = [
  'examples/dev.yaml',
  'examples/personal-assistant.yaml',
  'examples/production.yaml',
  'dev/testing/profiles/channels/data/dartclaw.yaml',
  'dev/testing/profiles/governance/data/dartclaw.yaml',
  'dev/testing/profiles/plain/data/dartclaw.yaml',
  'dev/testing/profiles/visual/data/dartclaw.yaml',
  'dev/testing/profiles/workflows/data/dartclaw.yaml',
];

/// Walks up to the workspace root from this package's own resolved location.
///
/// Resolved from the package URI rather than the working directory: `dart
/// test` runs every suite in one process, and a discovery test that chdirs
/// moves the working directory out from under a concurrent suite.
Future<String> resolveRepoRoot() async {
  final barrel = await Isolate.resolvePackageUri(Uri.parse('package:dartclaw_kernel/dartclaw_kernel.dart'));
  if (barrel == null) throw StateError('Could not resolve package:dartclaw_kernel.');
  var current = Directory(p.dirname(barrel.toFilePath())).absolute;
  while (true) {
    if (Directory(p.join(current.path, 'packages', 'dartclaw_kernel')).existsSync()) {
      return current.path;
    }
    final parent = current.parent;
    if (parent.path == current.path) {
      throw StateError('Could not resolve the DartClaw workspace root.');
    }
    current = parent;
  }
}

String configSchemaPath(String repoRoot) => p.join(repoRoot, 'schemas', 'dartclaw.schema.json');

/// The artifact's bytes as the generator writes them: two-space indent, LF
/// endings, one trailing newline, no timestamp and no version stamp.
String renderConfigSchema() => '${const JsonEncoder.withIndent('  ').convert(ConfigMeta.toJsonSchema())}\n';

/// Why the committed artifact no longer answers for the registry, or null when
/// it does.
///
/// Line endings are normalized on both sides: the repo carries no
/// `.gitattributes`, so on an autocrlf clone the committed bytes read back with
/// CRLF while the generator emits LF, and a raw byte comparison would be red
/// for reasons that have nothing to do with drift.
String? configSchemaDrift({required String artifactPath, required String? committed, required String rendered}) {
  if (committed != null && _normalize(committed) == _normalize(rendered)) return null;
  final cause = committed == null
      ? '$artifactPath is missing.'
      : '$artifactPath has drifted from the config field registry.';
  return '$cause\nRegenerate it with: $configSchemaRegenerationCommand';
}

String _normalize(String source) => source.replaceAll('\r\n', '\n');
