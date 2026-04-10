import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
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
