/// Signal channel integration for DartClaw via signal-cli subprocess.
library;

import 'package:dartclaw_core/dartclaw_core.dart';

import 'src/signal_config.dart';

export 'src/signal_channel.dart' show SignalChannel;
export 'src/signal_cli_manager.dart' show SignalCliManager;
export 'src/signal_config.dart' show SignalConfig;
export 'src/signal_dm_access.dart' show SignalGroupAccessMode, SignalMentionGating;
export 'src/signal_sender_map.dart' show SignalSenderMap;

bool _registerSignalConfigParser() {
  DartclawConfig.registerChannelConfigParser(ChannelType.signal, (yaml, warns) => SignalConfig.fromYaml(yaml, warns));
  return true;
}

final bool _signalConfigParserRegistered = _registerSignalConfigParser();

/// Forces the library to stay initialized for parser registration.
void ensureDartclawSignalRegistered() {
  if (!_signalConfigParserRegistered) {
    throw StateError('dartclaw_signal failed to register its channel config parser.');
  }
}
