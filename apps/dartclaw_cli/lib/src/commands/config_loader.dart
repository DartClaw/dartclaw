import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_google_chat/dartclaw_google_chat.dart';
import 'package:dartclaw_signal/dartclaw_signal.dart';
import 'package:dartclaw_whatsapp/dartclaw_whatsapp.dart';

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
