import 'dart:io';

import 'package:dartclaw_acp/dartclaw_acp.dart' show acpConfigFor;
import 'package:dartclaw_core/dartclaw_core.dart' show LoginStoreCollisionError, NamedCredentialStore;
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart' show loadDartclawConfig;
import 'package:path/path.dart' as p;

/// Registers the named credential store as the source of stored credentials.
///
/// `DartclawConfig.load` calls the registered closure on every load, passing
/// that load's credentials directory, so every re-read path — the config API,
/// the guard editor, the reload trigger — resolves a credential stored since
/// the last one without knowing the store exists. An unusable store is no
/// store: it degrades to no stored credentials rather than failing the load,
/// the same way `setup_checks` treats the subscription store.
void ensureStoredCredentialProviderRegistered({Map<String, String>? env}) {
  final environment = env ?? Platform.environment;
  DartclawConfig.registerStoredCredentialProvider((credentialsDir) {
    try {
      return NamedCredentialStore.readOnly(credentialsDir: credentialsDir, environment: environment).readAll();
    } on LoginStoreCollisionError {
      return const {};
    } on FileSystemException {
      return const {};
    }
  });
}

String defaultInstanceDir({Map<String, String>? env}) {
  final environment = env ?? Platform.environment;
  final homeEnv = environment['DARTCLAW_HOME'];
  if (homeEnv != null && homeEnv.isNotEmpty) {
    return expandHome(homeEnv, env: environment);
  }

  final home = environment['HOME'] ?? environment['USERPROFILE'] ?? '.';
  return p.join(home, '.dartclaw');
}

String resolveCliConfigPath({String? configPath, Map<String, String>? env}) {
  final environment = env ?? Platform.environment;
  if (configPath != null && configPath.isNotEmpty) {
    return expandHome(configPath, env: environment);
  }

  final envPath = environment['DARTCLAW_CONFIG'];
  if (envPath != null && envPath.isNotEmpty) {
    return expandHome(envPath, env: environment);
  }

  return p.join(defaultInstanceDir(env: environment), 'dartclaw.yaml');
}

/// Resolves the config path for `dartclaw workflow --standalone` commands.
///
/// Explicit `--config` and `DARTCLAW_CONFIG` stay authoritative. Otherwise the
/// resolver prefers a cwd-local `./.dartclaw/dartclaw.yaml` — the file
/// `dartclaw init --workflow` writes — so a freshly initialized project runs a
/// bare `dartclaw workflow run --standalone <name>` without `--config`. When no
/// cwd-local config exists it falls back to the normal CLI config path.
String resolveStandaloneWorkflowConfigPath({
  String? configPath,
  Map<String, String>? env,
  String? currentDirectory,
  bool Function(String path)? exists,
}) {
  final environment = env ?? Platform.environment;
  if (configPath != null && configPath.isNotEmpty) {
    return resolveCliConfigPath(configPath: configPath, env: environment);
  }
  final envPath = environment['DARTCLAW_CONFIG'];
  if (envPath != null && envPath.isNotEmpty) {
    return resolveCliConfigPath(env: environment);
  }
  final homePath = environment['DARTCLAW_HOME'];
  if (homePath != null && homePath.isNotEmpty) {
    return resolveCliConfigPath(env: environment);
  }

  bool defaultExists(String path) => File(path).existsSync();
  final fileExists = exists ?? defaultExists;
  final cwd = currentDirectory ?? Directory.current.path;
  final cwdConfig = p.join(cwd, '.dartclaw', 'dartclaw.yaml');
  if (fileExists(cwdConfig)) return cwdConfig;

  return resolveCliConfigPath(env: environment);
}

/// The `harness.<name>` sections this CLI composed a parser for.
///
/// `dartclaw_kernel` retains a harness section as raw data and never parses one
/// — the package that owns the section's types depends on it, so a parser there
/// would invert the dependency direction. This is the composition root's half:
/// it runs each composed parse against the loaded config, so the section's
/// warnings reach `config.warnings` and stay reload-blocking, and then refuses
/// a config carrying a section nothing here claims rather than running with it
/// silently dropped.
DartclawConfig primeHarnessSections(
  DartclawConfig config, {
  Map<String, void Function(DartclawConfig config)> sectionPrimers = const {},
}) {
  for (final primer in sectionPrimers.values) {
    primer(config);
  }
  config.harness.assertSectionsHandled(sectionPrimers.keys.toSet());
  return config;
}

/// Harness sections composed into every production load by this CLI.
const cliHarnessSectionPrimers = <String, void Function(DartclawConfig config)>{'acp': acpConfigFor};

/// Loads CLI config with the GitHub webhook extension parser registered.
///
/// [resolveStoredCredentials] registers the named credential store first, so
/// the load — and every later one in this process — merges stored entries into
/// `credentials:`. Passing `false` skips the registered provider for this load,
/// so audit callers see the file's own view even after another load registered it.
DartclawConfig loadCliConfig({
  String? configPath,
  Map<String, String>? cliOverrides,
  Map<String, String>? env,
  String? Function(String path)? fileReader,
  Map<String, void Function(DartclawConfig config)> harnessSectionPrimers = cliHarnessSectionPrimers,
  bool resolveStoredCredentials = true,
}) {
  ensureGitHubWebhookConfigRegistered();
  if (resolveStoredCredentials) ensureStoredCredentialProviderRegistered(env: env);
  return primeHarnessSections(
    loadDartclawConfig(
      configPath: configPath,
      cliOverrides: cliOverrides,
      env: env,
      fileReader: fileReader,
      resolveStoredCredentials: resolveStoredCredentials,
    ),
    sectionPrimers: harnessSectionPrimers,
  );
}
