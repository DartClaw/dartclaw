import 'package:dartclaw_config/dartclaw_config.dart';

/// Default HOME used by the [loadYaml] builder; the config file is served from
/// `<home>/.dartclaw/dartclaw.yaml`.
const String defaultTestHome = '/home/user';

/// A [DartclawConfig.load] `fileReader` that finds no config file (always
/// returns `null`), so `load` falls back to defaults.
String? noFile(String path) => null;

/// Loads a [DartclawConfig] with no config file present (pure defaults).
DartclawConfig loadNoFile({Map<String, String> env = const {'HOME': defaultTestHome}}) =>
    DartclawConfig.load(fileReader: noFile, env: env);

/// Loads a [DartclawConfig] from an in-memory [yaml] string, served at the
/// default discovery path (`<home>/.dartclaw/dartclaw.yaml`) unless a
/// [configPath] is supplied (in which case the YAML is served from there).
///
/// Collapses the repeated inline `fileReader`/`env` closure that every
/// load-based config test would otherwise hand-roll. Pass [env] to add or
/// override environment entries (HOME defaults to [defaultTestHome]); pass
/// [cli] for CLI overrides.
DartclawConfig loadYaml(
  String yaml, {
  Map<String, String> env = const {'HOME': defaultTestHome},
  String? configPath,
  Map<String, String>? cli,
}) {
  final home = env['HOME'] ?? defaultTestHome;
  final servePath = configPath ?? '$home/.dartclaw/dartclaw.yaml';
  return DartclawConfig.load(
    configPath: configPath,
    cliOverrides: cli,
    fileReader: (path) => path == servePath ? yaml : null,
    env: env,
  );
}
