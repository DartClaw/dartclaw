import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'dart:async';
import 'dart:convert';

import 'package:dartclaw_bridge/dartclaw_bridge.dart';
import 'package:dartclaw_core/dartclaw_core.dart' show McpTool, McpToolAccess, ToolResult;
import 'package:dartclaw_runtime/dartclaw_runtime.dart';

/// An in-memory stand-in for one `docker exec -i` bridge process.
///
/// Drives a real [GatewayPipe] without Docker: the test writes the frames a
/// bridge would write and reads the frames the host sends back.
final class FakeBridgeChannel implements BridgeChannel {
  new({BridgeLimits limits = BridgeLimits.defaults}) : _limits = limits;

  final BridgeLimits _limits;
  final StreamController<List<int>> _toHost = StreamController<List<int>>();
  final StreamController<BridgeFrame> _fromHost = StreamController<BridgeFrame>.broadcast();
  final Completer<void> _closed = Completer<void>();
  late final BridgeFrameReader _reader = BridgeFrameReader(limits: _limits);
  late final StreamQueueLite<BridgeFrame> received = StreamQueueLite<BridgeFrame>(_fromHost.stream);

  var _closeCount = 0;

  /// How many times the pipe was torn down; release must be idempotent.
  int get closeCount => _closeCount;

  bool get isClosed => _closed.isCompleted;

  @override
  Stream<List<int>> get incoming => _toHost.stream;

  @override
  Future<void> send(List<int> bytes) async {
    for (final frame in _reader.addChunk(bytes)) {
      _fromHost.add(frame);
    }
  }

  @override
  Future<void> close() async {
    _closeCount++;
    if (_closed.isCompleted) return;
    _closed.complete();
    // Not awaited: a single-subscription controller that was never listened to
    // never completes its close future, and a pipe that failed before the
    // handshake legitimately leaves one behind.
    unawaited(_toHost.close());
    unawaited(_fromHost.close());
  }

  /// Writes a frame as the in-container bridge would.
  void emit(BridgeFrame frame) {
    if (_toHost.isClosed) return;
    _toHost.add(encodeBridgeFrame(frame, limits: _limits));
  }

  /// Writes raw bytes, for malformed-frame probes.
  void emitRaw(List<int> bytes) {
    if (_toHost.isClosed) return;
    _toHost.add(bytes);
  }

  /// Completes the handshake and reports the listener as ready.
  Future<void> handshake(BridgeSurface surface) async {
    emit(
      BridgeFrame(
        type: BridgeFrameType.handshake,
        metadata: {'version': bridgeProtocolVersion, 'surface': surface.name},
      ),
    );
    final ack = await received.next;
    if (ack.type != BridgeFrameType.handshakeAck) {
      throw StateError('Expected handshakeAck, got ${ack.type.name}');
    }
    emit(BridgeFrame(type: BridgeFrameType.ready, metadata: {'port': 8080}));
  }

  /// Sends one complete request and collects the host's answer.
  Future<GatewayExchange> request(
    int requestId, {
    String method = 'POST',
    String path = '/v1/messages',
    Map<String, List<String>> headers = const {},
    String body = '',
  }) async {
    emit(
      BridgeFrame(
        type: BridgeFrameType.requestStart,
        requestId: requestId,
        metadata: {'method': method, 'path': path, 'headers': headers},
      ),
    );
    if (body.isNotEmpty) {
      emit(BridgeFrame(type: BridgeFrameType.requestChunk, requestId: requestId, body: utf8.encode(body)));
    }
    emit(BridgeFrame(type: BridgeFrameType.requestEnd, requestId: requestId));
    return collect(requestId);
  }

  /// Reads frames until [requestId] terminates.
  Future<GatewayExchange> collect(int requestId) async {
    var status = 0;
    String? failure;
    final body = StringBuffer();
    Map<String, Object?> headers = const {};
    while (true) {
      final frame = await received.next;
      if (frame.requestId != requestId) continue;
      switch (frame.type) {
        case BridgeFrameType.responseStart:
          status = intOrDefault(frame.metadata['status'], 0);
          final raw = frame.metadata['headers'];
          if (raw is Map) headers = raw.cast<String, Object?>();
        case BridgeFrameType.responseChunk:
          body.write(utf8.decode(frame.body));
        case BridgeFrameType.responseEnd:
          return GatewayExchange(status: status, body: body.toString(), headers: headers, failure: failure);
        case BridgeFrameType.failure:
          status = intOrDefault(frame.metadata['status'], 0);
          failure = stringOrDefault(frame.metadata['message'], '');
          return GatewayExchange(status: status, body: body.toString(), headers: headers, failure: failure);
        default:
          continue;
      }
    }
  }
}

/// One completed host answer.
final class GatewayExchange {
  const new({required this.status, required this.body, required this.headers, this.failure});

  final int status;
  final String body;
  final Map<String, Object?> headers;

  /// Set when the host refused the request instead of answering it.
  final String? failure;

  bool get isDenied => failure != null;
}

/// A minimal pull queue over a broadcast stream.
///
/// `package:async`'s StreamQueue cannot be reused across the broadcast
/// subscriptions these tests need; this keeps every frame buffered instead.
final class StreamQueueLite<T> {
  new(Stream<T> source) {
    source.listen(
      (event) {
        if (_waiters.isNotEmpty) {
          _waiters.removeAt(0).complete(event);
          return;
        }
        _buffer.add(event);
      },
      onDone: () {
        for (final waiter in _waiters) {
          waiter.completeError(StateError('bridge stream closed'));
        }
        _waiters.clear();
      },
    );
  }

  final List<T> _buffer = [];
  final List<Completer<T>> _waiters = [];

  Future<T> get next {
    if (_buffer.isNotEmpty) return Future.value(_buffer.removeAt(0));
    final waiter = Completer<T>();
    _waiters.add(waiter);
    return waiter.future;
  }
}

GatewayPrincipal principal({
  String sessionId = 'session-a',
  String providerId = 'claude',
  String profile = 'workspace',
  String? logicalAgentId,
  String? taskId,
}) => GatewayPrincipal(
  sessionId: sessionId,
  providerId: providerId,
  policy: ExecutionPolicy.container(profile),
  sourceSessionId: sessionId,
  logicalAgentId: logicalAgentId,
  taskId: taskId,
);

/// An MCP tool that records the fact the host implementation actually ran.
///
/// Shared by the unit and real-Docker gateway suites: both need to prove that
/// an authorized call reaches the implementation and a denied one does not.
final class RecordingMcpTool implements McpTool {
  new(this.name, this._called);

  @override
  final String name;

  final List<String> _called;

  @override
  String get description => 'test tool $name';

  @override
  Map<String, dynamic> get inputSchema => const {'type': 'object', 'properties': <String, Object?>{}};

  @override
  McpToolAccess get access => McpToolAccess.write;

  @override
  Future<ToolResult> call(Map<String, dynamic> args) async {
    _called.add(name);
    return ToolResult.text('ok');
  }
}
