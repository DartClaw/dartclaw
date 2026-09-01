import 'package:dartclaw_kernel/dartclaw_kernel.dart';

/// Default HOME used by the [loadYaml] builder; the config file is served from
/// `<home>/.dartclaw/dartclaw.yaml`.
///
/// Mirrors `dartclaw_kernel`'s own `test/support/load_config.dart`. The two
/// cannot be shared — a test support file is not importable across packages —
/// and this package's suites load through `DartclawConfig.load` for the same
/// reason that one does: `harness.acp` reaches [acpConfigFor] only as a loaded
/// config's retained raw section.
const String defaultTestHome = '/home/user';

/// Loads a [DartclawConfig] from an in-memory [yaml] string, served at the
/// default discovery path (`<home>/.dartclaw/dartclaw.yaml`) unless a
/// [configPath] is supplied.
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
