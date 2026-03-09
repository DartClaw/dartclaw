import 'dart:async';
import 'dart:convert';

import 'package:logging/logging.dart';

/// Manages SSE broadcast to all connected clients.
///
/// Clients subscribe by calling [subscribe], which returns a
/// [StreamController<List<int>>] suitable for a shelf response body.
/// The server broadcasts events to all subscribers via [broadcast].
///
/// This is a global broadcast channel, separate from per-turn SSE in
/// `stream_handler.dart`.
class SseBroadcast {
  static final _log = Logger('SseBroadcast');
  final List<StreamController<List<int>>> _clients = [];

  /// Registers a new SSE client. Returns the controller whose stream
  /// should be used as the shelf response body.
  StreamController<List<int>> subscribe() {
    final controller = StreamController<List<int>>();
    _clients.add(controller);
    controller.onCancel = () {
      _clients.remove(controller);
    };
    return controller;
  }

  /// Broadcasts an SSE event to all connected clients.
  void broadcast(String event, Map<String, dynamic> data) {
    final encoded = jsonEncode(data);
    final frame = 'event: $event\ndata: $encoded\n\n';
    final bytes = utf8.encode(frame);

    final stale = <StreamController<List<int>>>[];
    for (final client in _clients) {
      if (client.isClosed) {
        stale.add(client);
        continue;
      }
      try {
        client.add(bytes);
      } catch (e) {
        _log.fine('Failed to send SSE broadcast to client: $e');
        stale.add(client);
      }
    }
    // Clean up disconnected clients.
    for (final s in stale) {
      _clients.remove(s);
    }
  }

  /// Number of currently connected clients.
  int get clientCount => _clients.length;

  /// Closes all client connections.
  Future<void> dispose() async {
    for (final c in List.of(_clients)) {
      await c.close();
    }
    _clients.clear();
  }
}
