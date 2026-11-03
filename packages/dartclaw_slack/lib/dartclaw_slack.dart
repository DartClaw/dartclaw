/// Slack channel adapter for DartClaw over Socket Mode or the Events API.
library;

export 'package:dartclaw_core/dartclaw_core.dart' show Channel, ChannelManager, ChannelMessage, ChannelResponse;

export 'src/slack_bot_scopes.dart' show slackExpectedBotScopes;
export 'src/slack_channel.dart' show SlackChannel;
export 'src/slack_config.dart' show SlackConfig, slackUserIdPattern;
export 'src/slack_envelope.dart'
    show
        SlackAnsweringHandler,
        SlackEnvelope,
        SlackEnvelopeDispatch,
        SlackEnvelopeHandler,
        SlackEnvelopeKind,
        slackAnswerDeadline;
export 'src/slack_events_handler.dart' show SlackEventsHandler, SlackEventsResponse, SlackRequestRejection;
export 'src/slack_feedback_strategy.dart' show SlackFeedbackStrategy;
export 'src/slack_health_reporter.dart' show SlackHealthReporter;
export 'src/slack_web_api_client.dart'
    show
        SlackApiException,
        SlackAuthInfo,
        SlackWebApiClient,
        slackApiBase,
        slackFileScopeMissing,
        slackFileTooLarge,
        slackFileUnavailable;
export 'src/socket_mode_client.dart' show SocketModeClient, SocketModeConnector, SocketModeState;
