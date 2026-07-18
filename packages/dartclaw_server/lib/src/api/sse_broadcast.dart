import 'dart:async';
import 'dart:convert';

import 'package:logging/logging.dart';
import 'package:shelf/shelf.dart';

/// Headers for an SSE (`text/event-stream`) response.
///
/// Excludes `X-Accel-Buffering` for callers that explicitly permit proxy
/// buffering.
const Map<String, String> eventStreamHeaders = {
  'Content-Type': 'text/event-stream',
  'Cache-Control': 'no-cache',
  'Connection': 'keep-alive',
};

/// [eventStreamHeaders] plus `X-Accel-Buffering: no` to disable proxy/nginx
/// response buffering so events flush immediately.
const Map<String, String> eventStreamHeadersNoBuffer = {
  'Content-Type': 'text/event-stream',
  'Cache-Control': 'no-cache',
  'Connection': 'keep-alive',
  'X-Accel-Buffering': 'no',
};

Response sseResponse(Stream<List<int>> body, {Map<String, String> headers = eventStreamHeadersNoBuffer}) =>
    Response.ok(body, headers: headers, context: const {'shelf.io.buffer_output': false});

/// Encodes a `data: <data>\n\n` SSE frame to UTF-8 bytes.
///
/// [data] is the already-serialized data payload (e.g. a JSON string); it is
/// emitted verbatim on the `data:` line.
List<int> sseDataFrame(String data) => utf8.encode('data: $data\n\n');

/// Encodes an `event: <event>\ndata: <data>\n\n` SSE frame to UTF-8 bytes.
///
/// [data] is the already-serialized data payload, emitted verbatim.
List<int> sseEventFrame(String event, String data) => utf8.encode('event: $event\ndata: $data\n\n');

/// JSON-encodes [data] and adds it as a `data:` SSE frame to [controller],
/// unless the controller is already closed. Swallows the add error if the
/// client disconnects between the closed-check and [StreamController.add].
void sendSseData(StreamController<List<int>> controller, Map<String, dynamic> data) {
  if (controller.isClosed) return;
  try {
    controller.add(sseDataFrame(jsonEncode(data)));
  } catch (_) {
    // Client disconnected — cleaned up by onCancel.
  }
}

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
    final bytes = sseEventFrame(event, jsonEncode(data));

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
