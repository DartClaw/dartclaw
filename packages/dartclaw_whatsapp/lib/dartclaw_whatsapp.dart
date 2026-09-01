/// WhatsApp channel integration for DartClaw via GOWA sidecar.
library;

export 'package:dartclaw_core/dartclaw_core.dart'
    show
        Channel,
        ChannelManager,
        ChannelMessage,
        ChannelResponse,
        DelayFactory,
        DmAccessController,
        DmAccessMode,
        HealthProbe,
        MentionGating,
        ProcessFactory;

export 'src/gowa_manager.dart' show GowaLoginQr, GowaManager, GowaStatus;
export 'src/response_formatter.dart' show formatResponse;
export 'src/whatsapp_channel.dart' show WhatsAppChannel, jidToPhone;
export 'src/whatsapp_config.dart' show WhatsAppConfig;
