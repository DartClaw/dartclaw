// Regenerates `schemas/dartclaw.schema.json` from the config field registry.
//
//   dart run packages/dartclaw_kernel/tool/generate_config_schema.dart
//   dart run packages/dartclaw_kernel/tool/generate_config_schema.dart --check
//
// `--check` regenerates in memory and fails when the committed artifact
// differs or is missing. The fitness harness runs it on every commit.
import 'dart:io';

import '../test/support/config_schema_artifact.dart';

Future<void> main(List<String> args) async {
  final repoRoot = await resolveRepoRoot();
  final file = File(configSchemaPath(repoRoot));
  final rendered = renderConfigSchema(version: configSchemaVersion(repoRoot));

  if (args.contains('--check')) {
    final drift = configSchemaDrift(
      artifactPath: file.path,
      committed: file.existsSync() ? file.readAsStringSync() : null,
      rendered: rendered,
    );
    if (drift == null) {
      stdout.writeln('${file.path} is up to date');
      return;
    }
    stderr.writeln(drift);
    exit(1);
  }

  file.parent.createSync(recursive: true);
  file.writeAsStringSync(rendered);
  stdout.writeln('Wrote ${file.path}');
}
