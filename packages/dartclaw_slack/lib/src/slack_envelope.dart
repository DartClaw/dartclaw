import 'dart:async';

import 'package:logging/logging.dart';

/// What a Slack envelope carries, whichever transport delivered it.
enum SlackEnvelopeKind {
  /// An Events API event callback (`event_callback`).
  event,

  /// A slash-command invocation.
  slashCommand,

  /// A `block_actions` interaction.
  blockAction,

  /// A `view_submission` interaction.
  viewSubmission,

  /// Anything else; acknowledged and logged at debug.
  unknown,
}

/// One unit of inbound Slack traffic, transport-neutral: a [kind] and the
/// decoded Slack [payload].
class SlackEnvelope {
  /// What [payload] holds.
  final SlackEnvelopeKind kind;

  /// The Slack payload: the event callback, the slash-command fields or the interaction.
  final Map<String, dynamic> payload;

  /// Creates an envelope value.
  const new({required this.kind, required this.payload});
}

/// Handler for one [SlackEnvelopeKind].
typedef SlackEnvelopeHandler = FutureOr<void> Function(SlackEnvelope envelope);

/// The one entry point every Slack envelope passes through.
///
/// Knows no transport: Socket Mode and the Events API both build a
/// [SlackEnvelope] and call [dispatch]. Features register a handler per kind;
/// an envelope with no handler is logged at debug and dropped.
class SlackEnvelopeDispatch {
  static final _log = Logger('SlackEnvelopeDispatch');

  final Map<SlackEnvelopeKind, SlackEnvelopeHandler> _handlers = {};

  /// Registers the handler for [kind], replacing any earlier one.
  void register(SlackEnvelopeKind kind, SlackEnvelopeHandler handler) => _handlers[kind] = handler;

  /// Runs the handler registered for [envelope]'s kind. Never throws: a handler
  /// failure is logged and the envelope is dropped.
  Future<void> dispatch(SlackEnvelope envelope) async {
    final handler = _handlers[envelope.kind];
    if (handler == null) {
      _log.fine('No handler for Slack envelope kind ${envelope.kind.name}; dropping it');
      return;
    }
    try {
      await handler(envelope);
    } catch (error, stackTrace) {
      _log.warning('Slack ${envelope.kind.name} handler failed', error, stackTrace);
    }
  }
}
