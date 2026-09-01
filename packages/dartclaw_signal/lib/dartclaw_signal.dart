/// Signal channel integration for DartClaw via signal-cli subprocess.
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

export 'src/signal_channel.dart' show SignalChannel;
export 'src/signal_cli_manager.dart' show SignalCliManager, SignalRegistrationState;
export 'src/signal_config.dart' show SignalConfig;
export 'src/signal_sender_map.dart'
    show SignalSenderMap, canonicalSignalIdentifier, isValidSignalE164, isValidSignalUuid;
