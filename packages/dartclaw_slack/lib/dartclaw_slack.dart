/// Slack channel adapter for DartClaw over Socket Mode.
library;

export 'package:dartclaw_core/dartclaw_core.dart' show Channel, ChannelManager, ChannelMessage, ChannelResponse;

export 'src/slack_channel.dart' show SlackChannel;
export 'src/slack_config.dart' show SlackConfig;
export 'src/slack_envelope.dart' show SlackEnvelope, SlackEnvelopeDispatch, SlackEnvelopeHandler, SlackEnvelopeKind;
export 'src/slack_web_api_client.dart' show SlackApiException, SlackAuthInfo, SlackWebApiClient, slackApiBase;
export 'src/socket_mode_client.dart' show SocketModeClient, SocketModeConnector, SocketModeState;
