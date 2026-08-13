import 'dart:async';
import 'dart:io';

import 'bridge_codec.dart';
import 'bridge_protocol.dart';

/// The in-container half of one bridge pipe.
///
/// Listens on a container-loopback port and forwards bounded HTTP/1.1 traffic
/// to the host as frames. The runner never decides where a request goes: the
/// host binds destination, credentials, and policy to the pipe itself, so the
/// only thing crossing this boundary is the request shape.
final class BridgeRunner {
  new({
    required this.surface,
    required Stream<List<int>> hostInput,
    required IOSink hostOutput,
    this.limits = BridgeLimits.defaults,
    this.port = 0,
    InternetAddress? address,
  }) : _hostInput = hostInput,
       _hostOutput = hostOutput,
       _address = address ?? InternetAddress.loopbackIPv4,
       _reader = BridgeFrameReader(limits: limits);

  final BridgeSurface surface;
  final BridgeLimits limits;
  final int port;

  final Stream<List<int>> _hostInput;
  final IOSink _hostOutput;
  final InternetAddress _address;
  final BridgeFrameReader _reader;

  final Map<int, _PendingResponse> _pending = {};
  final List<Completer<void>> _slotWaiters = [];
  final Completer<void> _handshakeAck = Completer<void>();
  final Completer<void> _done = Completer<void>();

  StreamSubscription<List<int>>? _hostSubscription;
  HttpServer? _server;
  int _nextRequestId = 1;
  bool _closing = false;

  /// The port the loopback listener accepted on. Valid after [start].
  int get boundPort => _server?.port ?? 0;

  /// Completes when the pipe is fully torn down.
  Future<void> get done => _done.future;

  /// Performs the handshake, binds the loopback listener, and announces
  /// readiness to the host.
  ///
  /// Throws when the host rejects the handshake — a surface that cannot prove
  /// its protocol must not accept container traffic.
  Future<void> start() async {
    _hostSubscription = _hostInput.listen(
      _onHostBytes,
      onError: (Object error) => _failPipe('host pipe error: $error'),
      onDone: () => _failPipe('host closed the pipe'),
      cancelOnError: true,
    );

    await _write(
      BridgeFrame(
        type: BridgeFrameType.handshake,
        metadata: {'version': bridgeProtocolVersion, 'surface': surface.name},
      ),
    );
    await _handshakeAck.future;

    final server = await HttpServer.bind(_address, port);
    server.idleTimeout = limits.idleTimeout;
    _server = server;
    server.listen(
      (request) => unawaited(_onHttpRequest(request)),
      onError: (Object error) => _failPipe('loopback listener error: $error'),
    );

    await _write(BridgeFrame(type: BridgeFrameType.ready, metadata: {'port': server.port}));
  }

  Future<void> close() async {
    if (_closing) return _done.future;
    _closing = true;
    _releaseSlotWaiters();
    await _server?.close(force: true);
    _server = null;
    for (final pending in _pending.values.toList()) {
      pending.fail(HttpStatus.serviceUnavailable, 'bridge closed');
    }
    _pending.clear();
    await _hostSubscription?.cancel();
    _hostSubscription = null;
    if (!_done.isCompleted) _done.complete();
  }

  // ---------------------------------------------------------------------------
  // Host pipe
  // ---------------------------------------------------------------------------

  void _onHostBytes(List<int> chunk) {
    final List<BridgeFrame> frames;
    try {
      frames = _reader.addChunk(chunk);
    } on BridgeProtocolException catch (error) {
      _failPipe(error.message);
      return;
    }
    for (final frame in frames) {
      _onHostFrame(frame);
    }
  }

  void _onHostFrame(BridgeFrame frame) {
    switch (frame.type) {
      case BridgeFrameType.handshakeAck:
        if (frame.metadata['version'] != bridgeProtocolVersion) {
          _failPipe('host protocol version ${frame.metadata['version']} != $bridgeProtocolVersion');
          return;
        }
        if (!_handshakeAck.isCompleted) _handshakeAck.complete();
      case BridgeFrameType.responseStart:
      case BridgeFrameType.responseChunk:
      case BridgeFrameType.responseEnd:
      case BridgeFrameType.cancel:
        _pending[frame.requestId]?.onHostFrame(frame);
      case BridgeFrameType.failure:
        if (frame.requestId == 0) {
          _failPipe(stringOrDefault(frame.metadata['message'], 'host failed the pipe'));
          return;
        }
        _pending[frame.requestId]?.fail(
          intOrDefault(frame.metadata['status'], HttpStatus.badGateway),
          stringOrDefault(frame.metadata['message'], 'host rejected the request'),
        );
      case BridgeFrameType.handshake:
      case BridgeFrameType.ready:
      case BridgeFrameType.requestStart:
      case BridgeFrameType.requestChunk:
      case BridgeFrameType.requestEnd:
        _failPipe('unexpected ${frame.type.name} frame from host');
    }
  }

  void _failPipe(String reason) {
    if (!_handshakeAck.isCompleted) {
      _handshakeAck.completeError(BridgeProtocolException(reason));
    }
    for (final pending in _pending.values.toList()) {
      pending.fail(HttpStatus.badGateway, reason);
    }
    _pending.clear();
    unawaited(close());
  }

  Future<void> _write(BridgeFrame frame) async {
    if (_closing) return;
    _hostOutput.add(encodeBridgeFrame(frame, limits: limits));
    // Flushing per frame makes the OS pipe the backpressure boundary; without
    // it the sink would buffer an unbounded amount of container traffic.
    await _hostOutput.flush();
  }

  // ---------------------------------------------------------------------------
  // Loopback HTTP
  // ---------------------------------------------------------------------------

  Future<void> _onHttpRequest(HttpRequest request) async {
    if (_pending.length >= limits.maxInFlightRequests) {
      if (_slotWaiters.length >= limits.maxQueuedRequests) {
        await _reject(request, HttpStatus.serviceUnavailable, 'bridge in-flight limit reached');
        return;
      }
      final waiter = Completer<void>();
      _slotWaiters.add(waiter);
      await waiter.future;
      if (_closing) {
        await _reject(request, HttpStatus.serviceUnavailable, 'bridge closed');
        return;
      }
    }

    final requestId = _nextRequestId++;
    final pending = _PendingResponse(request, limits, () => _detach(requestId));
    _pending[requestId] = pending;

    unawaited(
      pending.clientGone.then((gone) async {
        if (!gone || !_pending.containsKey(requestId)) return;
        await _write(
          BridgeFrame(type: BridgeFrameType.cancel, requestId: requestId, metadata: {'reason': 'client disconnected'}),
        );
        pending.abandon();
      }),
    );

    try {
      await _write(
        BridgeFrame(
          type: BridgeFrameType.requestStart,
          requestId: requestId,
          metadata: {
            'method': request.method,
            'path': request.uri.hasQuery ? '${request.uri.path}?${request.uri.query}' : request.uri.path,
            'headers': _collectHeaders(request.headers),
          },
        ),
      );
      await _forwardBody(requestId, request);
      await _write(BridgeFrame(type: BridgeFrameType.requestEnd, requestId: requestId));
    } on BridgeProtocolException catch (error) {
      await _cancel(requestId, error.message);
      pending.fail(HttpStatus.requestEntityTooLarge, error.message);
      return;
    } on _RequestRejected catch (error) {
      await _cancel(requestId, error.message);
      pending.fail(error.status, error.message);
      return;
    }

    await pending.settled;
  }

  Future<void> _forwardBody(int requestId, HttpRequest request) async {
    var total = 0;
    await for (final chunk in request) {
      total += chunk.length;
      if (total > limits.maxRequestBytes) {
        throw _RequestRejected(
          HttpStatus.requestEntityTooLarge,
          'request body exceeds ${limits.maxRequestBytes} bytes',
        );
      }
      for (var offset = 0; offset < chunk.length; offset += limits.maxBodyChunkBytes) {
        final end = offset + limits.maxBodyChunkBytes > chunk.length ? chunk.length : offset + limits.maxBodyChunkBytes;
        await _write(
          BridgeFrame(type: BridgeFrameType.requestChunk, requestId: requestId, body: chunk.sublist(offset, end)),
        );
      }
    }
  }

  Future<void> _cancel(int requestId, String reason) =>
      _write(BridgeFrame(type: BridgeFrameType.cancel, requestId: requestId, metadata: {'reason': reason}));

  void _detach(int requestId) {
    if (_pending.remove(requestId) == null) return;
    if (_slotWaiters.isEmpty) return;
    _slotWaiters.removeAt(0).complete();
  }

  void _releaseSlotWaiters() {
    for (final waiter in _slotWaiters) {
      if (!waiter.isCompleted) waiter.complete();
    }
    _slotWaiters.clear();
  }

  Future<void> _reject(HttpRequest request, int status, String message) async {
    try {
      request.response.statusCode = status;
      request.response.headers.contentType = ContentType.text;
      request.response.write(message);
      await request.response.close();
    } catch (_) {
      // The client is already gone; nothing further to report.
    }
  }

  Map<String, List<String>> _collectHeaders(HttpHeaders headers) {
    final collected = <String, List<String>>{};
    headers.forEach((name, values) => collected[name] = values);
    return collected;
  }
}

/// One in-flight loopback request awaiting host frames.
final class _PendingResponse {
  new(this._request, this._limits, this._detach) {
    _request.response.bufferOutput = false;
    // A dropped client resolves `done` early rather than with an error, so
    // "resolved before we settled" is the disconnect signal.
    unawaited(
      _request.response.done.then(
        (_) => _completeClientGone(!_settled.isCompleted),
        onError: (Object _) => _completeClientGone(!_settled.isCompleted),
      ),
    );
  }

  final HttpRequest _request;
  final BridgeLimits _limits;
  final void Function() _detach;
  final Completer<void> _settled = Completer<void>();
  final Completer<bool> _clientGone = Completer<bool>();

  var _started = false;
  var _responseBytes = 0;

  Future<void> get settled => _settled.future;

  /// Completes `true` when the client dropped before the response finished.
  Future<bool> get clientGone => _clientGone.future;

  void onHostFrame(BridgeFrame frame) {
    switch (frame.type) {
      case BridgeFrameType.responseStart:
        _started = true;
        _request.response.statusCode = intOrDefault(frame.metadata['status'], HttpStatus.ok);
        _applyHeaders(frame.metadata['headers']);
      case BridgeFrameType.responseChunk:
        if (frame.body.isEmpty) return;
        _responseBytes += frame.body.length;
        if (_responseBytes > _limits.maxResponseBytes) {
          fail(HttpStatus.badGateway, 'response exceeds ${_limits.maxResponseBytes} bytes');
          return;
        }
        _request.response.add(frame.body);
      case BridgeFrameType.responseEnd:
        _finish();
      case BridgeFrameType.cancel:
        fail(HttpStatus.badGateway, stringOrDefault(frame.metadata['reason'], 'host cancelled the request'));
      default:
        fail(HttpStatus.badGateway, 'unexpected ${frame.type.name} frame');
    }
  }

  void fail(int status, String message) {
    if (_settled.isCompleted) return;
    if (!_started) {
      _request.response.statusCode = status;
      _request.response.headers.contentType = ContentType.text;
      _request.response.write(message);
    }
    _finish();
  }

  /// Ends the exchange without writing anything further — the client is gone.
  void abandon() => _finish();

  void _applyHeaders(Object? headers) {
    if (headers is! Map) return;
    for (final entry in headers.entries) {
      final name = entry.key.toString();
      if (_isHopByHop(name)) continue;
      final value = entry.value;
      if (value is List) {
        for (final item in value) {
          _request.response.headers.add(name, item.toString());
        }
      } else if (value != null) {
        _request.response.headers.add(name, value.toString());
      }
    }
  }

  void _completeClientGone(bool gone) {
    if (!_clientGone.isCompleted) _clientGone.complete(gone);
  }

  void _finish() {
    if (_settled.isCompleted) return;
    _settled.complete();
    _detach();
    unawaited(_request.response.close().catchError((Object _) {}));
  }

  static bool _isHopByHop(String name) => const {
    'connection',
    'keep-alive',
    'proxy-authenticate',
    'proxy-authorization',
    'te',
    'trailer',
    'transfer-encoding',
    'upgrade',
    'content-length',
  }.contains(name.toLowerCase());
}

final class _RequestRejected implements Exception {
  const new(this.status, this.message);

  final int status;
  final String message;
}
