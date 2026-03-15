/// WhatsApp channel integration for DartClaw via GOWA sidecar.
library;

import 'package:dartclaw_core/dartclaw_core.dart';

import 'src/whatsapp_config.dart';

export 'src/gowa_manager.dart' show GowaLoginQr, GowaManager, GowaStatus;
export 'src/media_extractor.dart' show MediaExtraction, extractMediaDirectives;
export 'src/response_formatter.dart' show formatResponse;
export 'src/whatsapp_channel.dart' show WhatsAppChannel;
export 'src/whatsapp_config.dart' show WhatsAppConfig;

bool _registerWhatsAppConfigParser() {
  DartclawConfig.registerChannelConfigParser(
    ChannelType.whatsapp,
    (yaml, warns) => WhatsAppConfig.fromYaml(yaml, warns),
  );
  return true;
}

final bool _whatsAppConfigParserRegistered = _registerWhatsAppConfigParser();

/// Forces the library to stay initialized for parser registration.
void ensureDartclawWhatsappRegistered() {
  if (!_whatsAppConfigParserRegistered) {
    throw StateError('dartclaw_whatsapp failed to register its channel config parser.');
  }
}
