import 'dart:io';

import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:dartclaw_google_chat/dartclaw_google_chat.dart';
import 'package:dartclaw_signal/dartclaw_signal.dart';
import 'package:dartclaw_whatsapp/dartclaw_whatsapp.dart';
import 'package:path/path.dart' as p;

/// Bundled channel packages self-register their config parsers on import.
///
/// CLI commands must call this before [DartclawConfig.load] so the current
/// bootstrap contract stays explicit in one place. If a bundled import stops
/// registering, the existing [StateError] path in `DartclawConfig` still fails
/// the load.
void ensureCliChannelConfigsRegistered() {
  ensureDartclawGoogleChatRegistered();
  ensureDartclawWhatsappRegistered();
  ensureDartclawSignalRegistered();
  ensureGitHubWebhookConfigRegistered();
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

/// Loads CLI config after verifying the bundled channel parser imports ran.
DartclawConfig loadCliConfig({
  String? configPath,
  Map<String, String>? cliOverrides,
  Map<String, String>? env,
  String? Function(String path)? fileReader,
}) {
  ensureCliChannelConfigsRegistered();
  return DartclawConfig.load(configPath: configPath, cliOverrides: cliOverrides, env: env, fileReader: fileReader);
}
