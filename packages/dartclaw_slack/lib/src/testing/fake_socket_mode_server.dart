import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// A Socket Mode server on a loopback port, scripted from a test.
///
/// Accepts WebSocket connections, greets each with `hello`, records the
/// envelope IDs the client acknowledges, and sends envelopes, drops and
/// `disconnect` frames on demand.
class FakeSocketModeServer {
  HttpServer? _server;
  WebSocket? _socket;
  int _nextEnvelope = 0;
  final List<Completer<void>> _connectionWaiters = [];

  /// Envelope IDs the client acknowledged, in arrival order.
  final List<String> acknowledgements = [];

  /// The acknowledgement frames as the client sent them, to show what each one carries.
  final List<Map<String, dynamic>> acknowledgementFrames = [];

  /// Whether each new connection is greeted with `hello`.
  bool sendHello = true;

  /// Refuse upgrades with HTTP 503 while set.
  bool refuseConnections = false;

  /// How many WebSocket connections were accepted.
  int connectionCount = 0;

  /// How many connection attempts arrived, accepted or refused.
  int attemptCount = 0;

  /// The URL a client connects to. Valid after [start].
  Uri get url => Uri.parse('ws://127.0.0.1:${_server!.port}/link');

  /// Starts listening on an ephemeral loopback port.
  Future<void> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    unawaited(_serve(server));
  }

  /// Stops listening and closes the current connection.
  Future<void> stop() async {
    await _socket?.close();
    await _server?.close(force: true);
  }

  /// Completes once [count] connections have been accepted in total.
  Future<void> waitForConnections(int count) async {
    while (connectionCount < count) {
      final waiter = Completer<void>();
      _connectionWaiters.add(waiter);
      await waiter.future.timeout(const Duration(seconds: 5));
    }
  }

  /// Completes once the client has acknowledged [count] envelopes in total.
  Future<void> waitForAcknowledgements(int count) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (acknowledgements.length < count) {
      if (DateTime.now().isAfter(deadline)) throw TimeoutException('Expected $count acknowledgements');
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  /// Sends an `events_api` envelope wrapping [payload]; returns its envelope ID.
  String sendEvent(Map<String, dynamic> payload) => _send('events_api', payload);

  /// Sends a `slash_commands` envelope; returns its envelope ID.
  String sendSlashCommand(Map<String, dynamic> payload) => _send('slash_commands', payload);

  /// Sends an `interactive` envelope; returns its envelope ID.
  String sendInteractive(Map<String, dynamic> payload) => _send('interactive', payload);

  /// Sends a `disconnect` frame, as Slack does before it recycles a connection.
  void sendDisconnect(String reason) => _socket?.add(jsonEncode({'type': 'disconnect', 'reason': reason}));

  /// Closes the current connection without a `disconnect` frame.
  Future<void> dropConnection() async => _socket?.close(WebSocketStatus.goingAway);

  String _send(String type, Map<String, dynamic> payload) {
    final id = 'envelope-${_nextEnvelope++}';
    _socket!.add(jsonEncode({'type': type, 'envelope_id': id, 'accepts_response_payload': false, 'payload': payload}));
    return id;
  }

  Future<void> _serve(HttpServer server) async {
    await for (final request in server) {
      attemptCount++;
      if (refuseConnections || !WebSocketTransformer.isUpgradeRequest(request)) {
        request.response.statusCode = HttpStatus.serviceUnavailable;
        await request.response.close();
        continue;
      }
      final socket = await WebSocketTransformer.upgrade(request);
      _socket = socket;
      connectionCount++;
      if (sendHello) socket.add(jsonEncode({'type': 'hello', 'num_connections': 1}));
      for (final waiter in _connectionWaiters.toList()) {
        if (!waiter.isCompleted) waiter.complete();
      }
      _connectionWaiters.clear();
      socket.listen((frame) {
        if (frame is! String) return;
        final decoded = jsonDecode(frame);
        if (decoded is Map && decoded['envelope_id'] is String) {
          acknowledgements.add(decoded['envelope_id'] as String);
          acknowledgementFrames.add(Map<String, dynamic>.from(decoded));
        }
      }, onError: (Object _) {});
    }
  }
}
