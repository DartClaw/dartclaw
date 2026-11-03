import 'slack_events_handler.dart';
import 'socket_mode_client.dart';

/// Bridges the Slack transport's state into the `/health` response.
///
/// The map holds the mode, timestamps, a failure count and a reason code, and
/// nothing else: `/health` is unauthenticated, so no secret, ID or message
/// content may reach it.
class SlackHealthReporter {
  final SocketModeClient? _socket;
  final SlackEventsHandler? _events;

  /// Creates a reporter over the running transport: [socket] in socket mode,
  /// [events] in events mode.
  new({SocketModeClient? socket, SlackEventsHandler? events})
    : assert((socket == null) != (events == null), 'exactly one transport'),
      _socket = socket,
      _events = events;

  /// A JSON-serializable status map with ISO-8601 UTC timestamps; absent keys mean "never".
  Map<String, dynamic> get status {
    final socket = _socket;
    if (socket != null) {
      return {
        'mode': 'socket',
        'connection': socket.state.name,
        if (socket.lastConnectedAt case final connectedAt?) 'last_connected_at': _iso(connectedAt),
        'consecutive_failures': socket.consecutiveFailures,
      };
    }
    final events = _events;
    return {
      'mode': 'events',
      if (events?.lastVerifiedAt case final verifiedAt?) 'last_verified_at': _iso(verifiedAt),
      if (events?.lastRejection case final rejection?) 'last_failure_reason': rejection.reason,
      if (events?.lastRejectionAt case final failedAt?) 'last_failure_at': _iso(failedAt),
    };
  }

  static String _iso(DateTime time) => time.toUtc().toIso8601String();
}
