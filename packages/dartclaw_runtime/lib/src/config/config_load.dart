import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_core/dartclaw_core.dart' show GroupEntry;
import 'package:dartclaw_google_chat/dartclaw_google_chat.dart';
import 'package:dartclaw_signal/dartclaw_signal.dart';
import 'package:dartclaw_whatsapp/dartclaw_whatsapp.dart';

import 'channel_config_resolver.dart';

/// Loads config and parses every channel section.
///
/// Channel sections parse lazily per config instance, so a production load that
/// skipped this would drop channel parse warnings from [DartclawConfig.warnings]
/// and stop them blocking a hot reload. Every production load goes through here;
/// `DartclawConfig.load` is called nowhere else outside tests.
///
/// Throws [FormatException] when an allowlist row binds an agent that
/// `agent.agents` does not declare: a warning would leave that peer silently on
/// the primary lane, the opposite of what the binding was written for.
DartclawConfig loadDartclawConfig({
  String? configPath,
  Map<String, String>? cliOverrides,
  Map<String, String>? env,
  String? Function(String path)? fileReader,
  bool resolveStoredCredentials = true,
}) {
  final config = DartclawConfig.load(
    configPath: configPath,
    cliOverrides: cliOverrides,
    env: env,
    fileReader: fileReader,
    resolveStoredCredentials: resolveStoredCredentials,
  );
  for (final channelType in channelConfigTypes) {
    resolveChannelConfig<Object>(config, channelType);
  }
  _refuseUnknownBoundAgents(config);
  return config;
}

void _refuseUnknownBoundAgents(DartclawConfig config) {
  final declared = {for (final definition in config.agent.definitions) definition.id};
  for (final channelType in channelConfigTypes) {
    final (configKey, dmRows, groupRows) = switch (resolveChannelConfig<Object>(config, channelType)) {
      GoogleChatConfig(:final dmAllowlist, :final groupAllowlist) => ('google_chat', dmAllowlist, groupAllowlist),
      SignalConfig(:final dmAllowlist, :final groupAllowlist) => ('signal', dmAllowlist, groupAllowlist),
      WhatsAppConfig(:final dmAllowlist, :final groupAllowlist) => ('whatsapp', dmAllowlist, groupAllowlist),
      final other => throw StateError('Unexpected channel config ${other.runtimeType}'),
    };
    for (final (list, rows) in [('dm_allowlist', dmRows), ('group_allowlist', groupRows)]) {
      for (final GroupEntry(:id, :agent) in rows) {
        if (agent == null || declared.contains(agent)) continue;
        final known = declared.isEmpty ? 'none' : (declared.toList()..sort()).join(', ');
        throw FormatException(
          'channels.$configKey.$list: row "$id" binds agent "$agent", which agent.agents does not declare. '
          'Declared agents: $known.',
        );
      }
    }
  }
}
