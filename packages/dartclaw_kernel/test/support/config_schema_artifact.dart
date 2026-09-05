import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

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

String configSchemaVersion(String repoRoot) {
  final pubspec =
      loadYaml(File(p.join(repoRoot, 'packages', 'dartclaw_kernel', 'pubspec.yaml')).readAsStringSync()) as YamlMap;
  return pubspec['version'] as String;
}

String renderConfigSchema({required String version}) => ConfigMeta.jsonSchemaSource(version: version);

/// Why the committed artifact no longer answers for the registry, or null when
/// it does.
///
/// Line endings are normalized on both sides: the repo carries no
/// `.gitattributes`, so on an autocrlf clone the committed bytes read back with
/// CRLF while the generator emits LF, and a raw byte comparison would be red
/// for reasons that have nothing to do with drift.
String? configSchemaDrift({required String artifactPath, required String? committed, required String rendered}) {
  if (committed != null && _normalize(committed) == _normalize(rendered)) return null;
  var cause = committed == null
      ? '$artifactPath is missing.'
      : '$artifactPath has drifted from the config field registry.';
  if (committed != null) {
    try {
      final expectedId = (jsonDecode(rendered) as Map<String, dynamic>)[r'$id'];
      final decoded = jsonDecode(committed);
      if (decoded is Map<String, dynamic> && decoded[r'$id'] != expectedId) {
        cause =
            '$artifactPath has drifted: \$id names a different version than the workspace. '
            'Committed: ${decoded[r'$id']}; expected: $expectedId.';
      }
    } on FormatException {
      // Malformed JSON is still registry drift and needs the same regeneration.
    }
  }
  return '$cause\nRegenerate it with: $configSchemaRegenerationCommand';
}

String _normalize(String source) => source.replaceAll('\r\n', '\n');
