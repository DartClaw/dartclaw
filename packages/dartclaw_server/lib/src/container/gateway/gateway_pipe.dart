import 'dart:async';

import 'package:dartclaw_bridge/dartclaw_bridge.dart';
import 'package:logging/logging.dart';

import 'gateway_models.dart';

/// The host half of one bridge pipe.
///
/// The pipe *is* the authorization: surface, principal, and handler are fixed
/// here at construction, so no frame can select a different service,
/// destination, or credential. A revoked pipe stays revoked — there is no
/// re-attach path for an authority that has been released.
final class GatewayPipe {
  new({
    required this.surface,
    required this.principal,
    required BridgeChannel channel,
    required GatewaySurfaceHandler handler,
    this.limits = BridgeLimits.defaults,
    void Function(GatewayPrincipal principal, String reason)? onDenied,
  }) : _channel = channel,
       _handler = handler,
       _onDenied = onDenied,
       _reader = BridgeFrameReader(limits: limits) {
    if (handler.surface != surface) {
      throw ArgumentError('Handler serves ${handler.surface.name}, not ${surface.name}');
    }
    // Readiness is optional to await (a caller may only care that the pipe
    // exists), so absorb the revocation error here rather than letting it
    // surface as an unhandled async error. Callers that do await still see it.
    _ready.future.ignore();
    _subscription = _channel.incoming.listen(
      _onBytes,
      onError: (Object error) => _failPipe('bridge pipe error: $error'),
      onDone: () {
        _incomingDone = true;
        _failPipe('bridge closed the pipe');
      },
    );
  }

  static final _log = Logger('GatewayPipe');

  final BridgeSurface surface;
  final GatewayPrincipal principal;
  final BridgeLimits limits;

  final BridgeChannel _channel;
  final GatewaySurfaceHandler _handler;
  final void Function(GatewayPrincipal principal, String reason)? _onDenied;
  final BridgeFrameReader _reader;

  final Map<int, _InFlightRequest> _inFlight = {};
  final Completer<void> _ready = Completer<void>();

  late final StreamSubscription<List<int>> _subscription;
  Future<void> _writeChain = Future<void>.value();
  bool _handshakeComplete = false;
  bool _incomingDone = false;
  bool _revoked = false;
  int _pausedConsumers = 0;

  /// Completes when the bridge has handshaked and its loopback listener is
  /// accepting. Admission waits on this — a container turn must never start on
  /// a partially-established surface.
  Future<void> get ready => _ready.future;

  bool get isRevoked => _revoked;

  int get inFlightCount => _inFlight.length;

  /// Permanently closes the pipe. Safe to call repeatedly and at any point in
  /// the lifecycle, including before the handshake.
  Future<void> revoke() async {
    if (_revoked) return;
    _revoked = true;
    _failAllInFlight('authority released');
    if (!_ready.isCompleted) {
      _ready.completeError(StateError('Bridge pipe revoked before it became ready'));
    }
    // Never awaited: revocation can be triggered from the stream's own done
    // handler, where awaiting the cancellation deadlocks against the close
    // that caused it. The pipe already ignores everything once revoked.
    if (!_incomingDone) unawaited(_subscription.cancel());
    await _channel.close();
  }

  // ---------------------------------------------------------------------------
  // Frame intake
  // ---------------------------------------------------------------------------

  void _onBytes(List<int> chunk) {
    if (_revoked) return;
    final List<BridgeFrame> frames;
    try {
      frames = _reader.addChunk(chunk);
    } on BridgeProtocolException catch (error) {
      _failPipe(error.message);
      return;
    }
    for (final frame in frames) {
      _onFrame(frame);
    }
  }

  void _onFrame(BridgeFrame frame) {
    if (_revoked) return;
    if (!_handshakeComplete && frame.type != BridgeFrameType.handshake) {
      _failPipe('expected handshake, got ${frame.type.name}');
      return;
    }
    switch (frame.type) {
      case BridgeFrameType.handshake:
        _onHandshake(frame);
      case BridgeFrameType.ready:
        if (!_ready.isCompleted) _ready.complete();
      case BridgeFrameType.requestStart:
        _onRequestStart(frame);
      case BridgeFrameType.requestChunk:
        _inFlight[frame.requestId]?.addBody(frame.body);
      case BridgeFrameType.requestEnd:
        _inFlight[frame.requestId]?.endBody();
      case BridgeFrameType.cancel:
        _inFlight[frame.requestId]?.cancel('bridge cancelled the request');
      case BridgeFrameType.failure:
        _failPipe(stringOrDefault(frame.metadata['message'], 'bridge failed the pipe'));
      case BridgeFrameType.handshakeAck:
      case BridgeFrameType.responseStart:
      case BridgeFrameType.responseChunk:
      case BridgeFrameType.responseEnd:
        _failPipe('unexpected ${frame.type.name} frame from bridge');
    }
  }

  void _onHandshake(BridgeFrame frame) {
    final version = frame.metadata['version'];
    if (version != bridgeProtocolVersion) {
      _failPipe('bridge protocol version $version != $bridgeProtocolVersion');
      return;
    }
    // The surface is fixed host-side; the handshake only confirms the bridge
    // agrees. A mismatch means a misdelivered process, never a negotiation.
    if (frame.metadata['surface'] != surface.name) {
      _failPipe('bridge claims surface ${frame.metadata['surface']}, expected ${surface.name}');
      return;
    }
    _handshakeComplete = true;
    _write(
      BridgeFrame(
        type: BridgeFrameType.handshakeAck,
        metadata: {'version': bridgeProtocolVersion, 'surface': surface.name},
      ),
    );
  }

  void _onRequestStart(BridgeFrame frame) {
    final requestId = frame.requestId;
    if (requestId == 0 || _inFlight.containsKey(requestId)) {
      _failPipe('invalid or reused request ID $requestId');
      return;
    }
    if (_inFlight.length >= limits.maxInFlightRequests) {
      _deny(requestId, 503, 'bridge in-flight limit reached');
      return;
    }

    final metadata = frame.metadata;
    final method = stringOrDefault(metadata['method'], '');
    final path = stringOrDefault(metadata['path'], '');
    if (method.isEmpty || path.isEmpty) {
      _deny(requestId, 400, 'request is missing a method or path');
      return;
    }

    final inFlight = _InFlightRequest(requestId, limits, () => _detach(requestId), _setConsumerPaused);
    _inFlight[requestId] = inFlight;
    unawaited(
      _dispatch(
        inFlight,
        GatewayRequest(
          principal: principal,
          method: method,
          path: path,
          headers: _readHeaders(metadata['headers']),
          body: inFlight.body,
        ),
      ),
    );
  }

  Future<void> _dispatch(_InFlightRequest inFlight, GatewayRequest request) async {
    try {
      final deadline = DateTime.now().add(limits.requestTimeout);
      final response = await _handler.handle(request).timeout(limits.requestTimeout);
      if (inFlight.isCancelled) return;
      await _write(
        BridgeFrame(
          type: BridgeFrameType.responseStart,
          requestId: inFlight.id,
          metadata: {'status': response.status, 'headers': response.headers},
        ),
      );
      var total = 0;
      // Bounds on volume alone would let a slow-drip or stalled upstream hold
      // an in-flight slot forever: cap idle gaps and the whole exchange.
      await for (final chunk in response.body.timeout(limits.idleTimeout)) {
        if (inFlight.isCancelled) return;
        if (DateTime.now().isAfter(deadline)) {
          throw const GatewayDenied(status: 504, reason: 'upstream response exceeded the request budget');
        }
        total += chunk.length;
        if (total > limits.maxResponseBytes) {
          throw GatewayDenied(status: 502, reason: 'upstream response exceeds ${limits.maxResponseBytes} bytes');
        }
        for (var offset = 0; offset < chunk.length; offset += limits.maxBodyChunkBytes) {
          final end = offset + limits.maxBodyChunkBytes > chunk.length
              ? chunk.length
              : offset + limits.maxBodyChunkBytes;
          await _write(
            BridgeFrame(type: BridgeFrameType.responseChunk, requestId: inFlight.id, body: chunk.sublist(offset, end)),
          );
        }
      }
      if (inFlight.isCancelled) return;
      await _write(BridgeFrame(type: BridgeFrameType.responseEnd, requestId: inFlight.id));
    } on GatewayDenied catch (denied) {
      _deny(inFlight.id, denied.status, denied.reason);
    } on TimeoutException {
      _deny(inFlight.id, 504, 'host request timed out');
    } catch (error, stackTrace) {
      // Bodies and upstream detail never reach the container: an error string
      // can carry request content or a credential fragment.
      _log.warning('Gateway ${surface.name} request failed for ${principal.describe()}', error, stackTrace);
      _deny(inFlight.id, 502, 'host request failed');
    } finally {
      inFlight.complete();
    }
  }

  void _deny(int requestId, int status, String reason) {
    _onDenied?.call(principal, '${surface.name}: $reason');
    _log.info('Gateway denied ${surface.name} request for ${principal.describe()}: $reason');
    unawaited(
      _write(
        BridgeFrame(
          type: BridgeFrameType.failure,
          requestId: requestId,
          metadata: {'status': status, 'message': reason},
        ),
      ),
    );
  }

  void _failPipe(String reason) {
    if (_revoked) return;
    _log.warning('Gateway ${surface.name} pipe failed for ${principal.describe()}: $reason');
    _onDenied?.call(principal, '${surface.name}: $reason');
    unawaited(revoke());
  }

  void _detach(int requestId) {
    final removed = _inFlight.remove(requestId);
    if (removed != null && removed.isConsumerPaused) _setConsumerPaused(false);
  }

  /// Propagates one request's consumer backpressure to the whole pipe.
  ///
  /// A pipe multiplexes requests over one stdio stream, so there is nothing
  /// finer to pause than the stream itself. The bridge flushes per frame, so
  /// pausing here pushes back through the OS pipe rather than buffering on the
  /// host. Requests whose handler never listens are bounded by
  /// [BridgeLimits.maxRequestBytes] instead, since an absent consumer never
  /// signals a pause.
  void _setConsumerPaused(bool paused) {
    _pausedConsumers += paused ? 1 : -1;
    if (_pausedConsumers < 0) _pausedConsumers = 0;
    if (_pausedConsumers > 0 && !_subscription.isPaused) {
      _subscription.pause();
    } else if (_pausedConsumers == 0 && _subscription.isPaused) {
      _subscription.resume();
    }
  }

  void _failAllInFlight(String reason) {
    for (final request in _inFlight.values.toList()) {
      request.cancel(reason);
    }
    _inFlight.clear();
  }

  /// Serializes writes so concurrent responses never interleave mid-frame.
  Future<void> _write(BridgeFrame frame) {
    if (_revoked) return Future<void>.value();
    return _writeChain = _writeChain
        .then((_) async {
          if (_revoked) return;
          await _channel.send(encodeBridgeFrame(frame, limits: limits));
        })
        .catchError((Object error) {
          _log.fine('Gateway pipe write failed: $error');
        });
  }

  Map<String, List<String>> _readHeaders(Object? raw) {
    if (raw is! Map) return const {};
    final headers = <String, List<String>>{};
    for (final entry in raw.entries) {
      final name = entry.key.toString().toLowerCase();
      final value = entry.value;
      headers[name] = value is List
          ? [for (final item in value) item.toString()]
          : [if (value != null) value.toString()];
    }
    return headers;
  }
}

/// One request the host is currently answering.
final class _InFlightRequest {
  new(this.id, this._limits, this._detach, this._onConsumerPaused) {
    _body = StreamController<List<int>>(
      onPause: () => _setPaused(true),
      onResume: () => _setPaused(false),
      onCancel: () {
        _bodyClosed = true;
        _setPaused(false);
      },
    );
  }

  final int id;
  final BridgeLimits _limits;
  final void Function() _detach;
  final void Function(bool paused) _onConsumerPaused;

  late final StreamController<List<int>> _body;
  var _bodyBytes = 0;
  var _bodyClosed = false;
  var _cancelled = false;
  var _consumerPaused = false;

  Stream<List<int>> get body => _body.stream;

  bool get isCancelled => _cancelled;

  bool get isConsumerPaused => _consumerPaused;

  void _setPaused(bool paused) {
    if (_consumerPaused == paused) return;
    _consumerPaused = paused;
    _onConsumerPaused(paused);
  }

  void addBody(List<int> chunk) {
    if (_bodyClosed || _cancelled) return;
    _bodyBytes += chunk.length;
    if (_bodyBytes > _limits.maxRequestBytes) {
      _bodyClosed = true;
      _body.addError(GatewayDenied(status: 413, reason: 'request body exceeds ${_limits.maxRequestBytes} bytes'));
      unawaited(_body.close());
      return;
    }
    _body.add(chunk);
  }

  void endBody() {
    if (_bodyClosed) return;
    _bodyClosed = true;
    unawaited(_body.close());
  }

  void cancel(String reason) {
    if (_cancelled) return;
    _cancelled = true;
    if (!_bodyClosed) {
      _bodyClosed = true;
      _body.addError(GatewayDenied(status: 499, reason: reason));
      unawaited(_body.close());
    }
    complete();
  }

  void complete() {
    _setPaused(false);
    endBody();
    _detach();
  }
}
