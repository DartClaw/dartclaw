import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';

import 'slack_envelope.dart';
import 'slack_web_api_client.dart' show SlackApiException;

const _initialBackoff = Duration(seconds: 1);
const _maxBackoff = Duration(seconds: 60);
const _warnAfterFailures = 3;

/// Whether the Socket Mode connection is up.
enum SocketModeState {
  /// Not running, or waiting out a backoff before the next attempt.
  disconnected,

  /// Opening a connection.
  connecting,

  /// Connected and past Slack's `hello`.
  connected,
}

/// Opens the WebSocket for a Socket Mode URL. Replaceable in tests.
typedef SocketModeConnector = Future<WebSocket> Function(Uri url);

Future<WebSocket> _connectWebSocket(Uri url) async {
  final socket = await WebSocket.connect(url.toString());
  // A half-open connection is never reported as closed otherwise.
  socket.pingInterval = const Duration(seconds: 30);
  return socket;
}

/// Maintains one Socket Mode connection: opens it, acknowledges every envelope
/// by ID, hands it to a [SlackEnvelopeDispatch], and reconnects on its own.
///
/// Slack does not replay an envelope after a disconnect, so each envelope is
/// acknowledged before anything is done with it; processing then runs one
/// envelope at a time in arrival order, so a slow handler delays no
/// acknowledgement.
class SocketModeClient {
  static final _log = Logger('SocketModeClient');

  final Future<Uri> Function() _openUrl;
  final SlackEnvelopeDispatch _dispatch;
  final SocketModeConnector _connect;
  final Future<void> Function(Duration)? _delay;
  final DateTime Function() _now;

  SocketModeState _state = SocketModeState.disconnected;
  DateTime? _lastConnectedAt;
  bool _running = false;
  WebSocket? _socket;
  Future<void>? _loop;
  Future<void> _processing = Future.value();
  final Completer<void> _stopSignal = Completer<void>();
  Timer? _sleepTimer;

  /// Creates a client. [openUrl] returns a fresh connection URL for each attempt
  /// (`apps.connections.open`); the URL is never logged.
  new({
    required Future<Uri> Function() openUrl,
    required SlackEnvelopeDispatch dispatch,
    SocketModeConnector? connector,
    Future<void> Function(Duration)? delay,
    DateTime Function()? now,
  }) : _openUrl = openUrl,
       _dispatch = dispatch,
       _connect = connector ?? _connectWebSocket,
       _delay = delay,
       _now = now ?? DateTime.now;

  /// Whether the connection is up.
  SocketModeState get state => _state;

  /// When the connection last reached Slack's `hello`, or `null` if it never has.
  DateTime? get lastConnectedAt => _lastConnectedAt;

  /// Starts connecting in the background and returns at once.
  void start() {
    if (_running) return;
    _running = true;
    _loop = _run();
  }

  /// Closes the connection and stops reconnecting. Envelopes already received
  /// finish processing first.
  Future<void> stop() async {
    _running = false;
    if (!_stopSignal.isCompleted) _stopSignal.complete();
    _sleepTimer?.cancel();
    await _socket?.close();
    await _loop;
    await _processing;
    _state = SocketModeState.disconnected;
  }

  Future<void> _run() async {
    var failures = 0;
    var backoff = _initialBackoff;
    while (_running) {
      _state = SocketModeState.connecting;
      var refreshRequested = false;
      var reachedHello = false;
      try {
        final socket = await _connect(await _openUrl());
        _socket = socket;
        if (!_running) {
          await socket.close();
          break;
        }
        await for (final frame in socket) {
          final outcome = _handleFrame(socket, frame);
          if (outcome == _FrameOutcome.hello) {
            reachedHello = true;
            failures = 0;
            backoff = _initialBackoff;
          } else if (outcome == _FrameOutcome.refreshRequested) {
            refreshRequested = true;
            await socket.close();
          }
        }
      } catch (error) {
        // A Slack error's own text is safe; any other error can quote the URL, whose ticket authorises a connection.
        _log.fine(
          'Socket Mode connection attempt failed (${error is SlackApiException ? error.message : error.runtimeType})',
        );
      } finally {
        _socket = null;
        _state = SocketModeState.disconnected;
      }
      if (!_running) break;

      if (refreshRequested) continue;
      if (reachedHello) {
        _log.info('Socket Mode connection dropped; reconnecting in ${backoff.inSeconds}s');
      } else {
        failures++;
        if (failures >= _warnAfterFailures) {
          _log.warning('Socket Mode connection failed $failures times in a row; retrying in ${backoff.inSeconds}s');
        }
      }
      await _wait(backoff);
      backoff = backoff * 2 > _maxBackoff ? _maxBackoff : backoff * 2;
    }
  }

  _FrameOutcome _handleFrame(WebSocket socket, Object? frame) {
    if (frame is! String) return _FrameOutcome.none;
    final Object? decoded;
    try {
      decoded = jsonDecode(frame);
    } on FormatException {
      _log.fine('Ignoring a non-JSON Socket Mode frame');
      return _FrameOutcome.none;
    }
    if (decoded is! Map<String, dynamic>) return _FrameOutcome.none;

    final type = decoded['type'];
    if (type == 'hello') {
      _state = SocketModeState.connected;
      _lastConnectedAt = _now();
      _log.info('Socket Mode connected');
      return _FrameOutcome.hello;
    }
    if (type == 'disconnect') {
      final reason = decoded['reason'];
      _log.info('Slack asked Socket Mode to disconnect (${reason is String ? reason : 'no reason'})');
      return reason == 'refresh_requested' ? _FrameOutcome.refreshRequested : _FrameOutcome.none;
    }

    final envelopeId = decoded['envelope_id'];
    if (envelopeId is! String) {
      _log.fine('Ignoring a Socket Mode frame of type "$type"');
      return _FrameOutcome.none;
    }
    socket.add(jsonEncode({'envelope_id': envelopeId}));
    final payload = decoded['payload'];
    final envelope = SlackEnvelope(
      kind: _kindOf(type, payload),
      payload: payload is Map ? Map<String, dynamic>.from(payload) : const {},
    );
    _processing = _processing.then((_) => _dispatch.dispatch(envelope));
    return _FrameOutcome.none;
  }

  static SlackEnvelopeKind _kindOf(Object? socketType, Object? payload) => switch (socketType) {
    'events_api' => SlackEnvelopeKind.event,
    'slash_commands' => SlackEnvelopeKind.slashCommand,
    'interactive' => switch (payload is Map ? payload['type'] : null) {
      'block_actions' => SlackEnvelopeKind.blockAction,
      'view_submission' => SlackEnvelopeKind.viewSubmission,
      _ => SlackEnvelopeKind.unknown,
    },
    _ => SlackEnvelopeKind.unknown,
  };

  Future<void> _wait(Duration duration) {
    final delay = _delay;
    if (delay != null) return Future.any([delay(duration), _stopSignal.future]);
    final done = Completer<void>();
    _sleepTimer = Timer(duration, done.complete);
    return Future.any([done.future, _stopSignal.future]);
  }
}

enum _FrameOutcome { none, hello, refreshRequested }
