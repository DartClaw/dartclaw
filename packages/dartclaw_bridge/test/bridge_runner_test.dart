import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:async/async.dart';
import 'package:dartclaw_bridge/dartclaw_bridge.dart';
import 'package:test/test.dart';

void main() {
  group('BridgeRunner handshake', () {
    test('announces version and surface, then binds and reports readiness', () async {
      final pipe = await _HostPipe.start(BridgeSurface.mcp);
      addTearDown(pipe.dispose);

      expect(pipe.handshake.metadata['version'], bridgeProtocolVersion);
      expect(pipe.handshake.metadata['surface'], 'mcp');
      expect(pipe.runner.boundPort, greaterThan(0));
      expect(pipe.ready.metadata['port'], pipe.runner.boundPort);
    });

    test('fails the surface closed when the host acknowledges a different protocol version', () async {
      final toBridge = StreamController<List<int>>();
      final fromBridge = StreamController<List<int>>();
      final runner = BridgeRunner(
        surface: BridgeSurface.provider,
        hostInput: toBridge.stream,
        hostOutput: IOSink(fromBridge.sink),
        port: 0,
      );
      final frames = _frameQueue(fromBridge.stream);
      final started = runner.start();

      await frames.next;
      toBridge.add(
        encodeBridgeFrame(
          const BridgeFrame(type: BridgeFrameType.handshakeAck, metadata: {'version': bridgeProtocolVersion + 1}),
        ),
      );

      await expectLater(started, throwsA(isA<BridgeProtocolException>()));
      expect(runner.boundPort, 0, reason: 'no listener may exist after a refused handshake');
      await runner.close();
      await toBridge.close();
    });
  });

  group('BridgeRunner request forwarding', () {
    test('forwards method, path, and body, then streams the host response back', () async {
      final pipe = await _HostPipe.start(BridgeSurface.provider);
      addTearDown(pipe.dispose);

      final responseFuture = pipe.post('/v1/messages?beta=true', '{"model":"test"}');

      final start = await pipe.frames.next;
      expect(start.type, BridgeFrameType.requestStart);
      expect(start.metadata['method'], 'POST');
      expect(start.metadata['path'], '/v1/messages?beta=true');

      final body = StringBuffer();
      var frame = await pipe.frames.next;
      while (frame.type == BridgeFrameType.requestChunk) {
        body.write(utf8.decode(frame.body));
        frame = await pipe.frames.next;
      }
      expect(frame.type, BridgeFrameType.requestEnd);
      expect(body.toString(), '{"model":"test"}');

      pipe.send(
        BridgeFrame(
          type: BridgeFrameType.responseStart,
          requestId: start.requestId,
          metadata: {
            'status': 200,
            'headers': {
              'content-type': ['application/json'],
            },
          },
        ),
      );
      pipe.send(
        BridgeFrame(type: BridgeFrameType.responseChunk, requestId: start.requestId, body: utf8.encode('{"ok":')),
      );
      pipe.send(BridgeFrame(type: BridgeFrameType.responseChunk, requestId: start.requestId, body: utf8.encode('1}')));
      pipe.send(BridgeFrame(type: BridgeFrameType.responseEnd, requestId: start.requestId));

      final response = await responseFuture;
      expect(response.statusCode, 200);
      expect(response.body, '{"ok":1}');
      expect(response.headers['content-type'], contains('application/json'));
    });

    test('keeps concurrent responses separated by request ID', () async {
      final pipe = await _HostPipe.start(BridgeSurface.provider);
      addTearDown(pipe.dispose);

      final first = pipe.post('/one', 'a');
      final firstStart = await pipe.nextRequestStart();
      final second = pipe.post('/two', 'b');
      final secondStart = await pipe.nextRequestStart();

      expect(firstStart.requestId, isNot(secondStart.requestId));

      // Answer out of order and interleave the chunks: the runner must route
      // each byte to its own client.
      pipe.send(BridgeFrame(type: BridgeFrameType.responseStart, requestId: secondStart.requestId));
      pipe.send(BridgeFrame(type: BridgeFrameType.responseStart, requestId: firstStart.requestId));
      pipe.send(
        BridgeFrame(type: BridgeFrameType.responseChunk, requestId: secondStart.requestId, body: utf8.encode('SEC')),
      );
      pipe.send(
        BridgeFrame(type: BridgeFrameType.responseChunk, requestId: firstStart.requestId, body: utf8.encode('FIR')),
      );
      pipe.send(
        BridgeFrame(type: BridgeFrameType.responseChunk, requestId: secondStart.requestId, body: utf8.encode('OND')),
      );
      pipe.send(
        BridgeFrame(type: BridgeFrameType.responseChunk, requestId: firstStart.requestId, body: utf8.encode('ST')),
      );
      pipe.send(BridgeFrame(type: BridgeFrameType.responseEnd, requestId: secondStart.requestId));
      pipe.send(BridgeFrame(type: BridgeFrameType.responseEnd, requestId: firstStart.requestId));

      expect((await first).body, 'FIRST');
      expect((await second).body, 'SECOND');
    });

    test('a host failure for one request leaves another untouched', () async {
      final pipe = await _HostPipe.start(BridgeSurface.provider);
      addTearDown(pipe.dispose);

      final denied = pipe.post('/denied', 'x');
      final deniedStart = await pipe.nextRequestStart();
      final allowed = pipe.post('/allowed', 'y');
      final allowedStart = await pipe.nextRequestStart();

      pipe.send(
        BridgeFrame(
          type: BridgeFrameType.failure,
          requestId: deniedStart.requestId,
          metadata: {'status': 403, 'message': 'tool not authorized'},
        ),
      );
      pipe.send(BridgeFrame(type: BridgeFrameType.responseStart, requestId: allowedStart.requestId));
      pipe.send(
        BridgeFrame(type: BridgeFrameType.responseChunk, requestId: allowedStart.requestId, body: utf8.encode('ok')),
      );
      pipe.send(BridgeFrame(type: BridgeFrameType.responseEnd, requestId: allowedStart.requestId));

      final deniedResponse = await denied;
      expect(deniedResponse.statusCode, 403);
      expect(deniedResponse.body, contains('tool not authorized'));
      expect((await allowed).body, 'ok');
    });

    test('rejects a request body beyond the cap and cancels it host-side', () async {
      final pipe = await _HostPipe.start(
        BridgeSurface.provider,
        limits: const BridgeLimits(maxRequestBytes: 16, maxBodyChunkBytes: 8),
      );
      addTearDown(pipe.dispose);

      final response = pipe.post('/big', 'x' * 64);

      var frame = await pipe.frames.next;
      while (frame.type != BridgeFrameType.cancel) {
        frame = await pipe.frames.next;
      }
      expect(frame.metadata['reason'], contains('exceeds'));
      expect((await response).statusCode, HttpStatus.requestEntityTooLarge);
    });

    test('splits a large body into capped chunks without losing bytes', () async {
      final pipe = await _HostPipe.start(BridgeSurface.provider, limits: const BridgeLimits(maxBodyChunkBytes: 64));
      addTearDown(pipe.dispose);

      final payload = List.generate(500, (index) => String.fromCharCode(97 + index % 26)).join();
      final response = pipe.post('/chunked', payload);

      final start = await pipe.nextRequestStart();
      final received = BytesBuilder();
      var frame = await pipe.frames.next;
      while (frame.type == BridgeFrameType.requestChunk) {
        expect(frame.body.length, lessThanOrEqualTo(64));
        received.add(frame.body);
        frame = await pipe.frames.next;
      }
      expect(frame.type, BridgeFrameType.requestEnd);
      expect(utf8.decode(received.takeBytes()), payload);

      pipe.send(BridgeFrame(type: BridgeFrameType.responseStart, requestId: start.requestId));
      pipe.send(BridgeFrame(type: BridgeFrameType.responseEnd, requestId: start.requestId));
      expect((await response).statusCode, 200);
    });

    test('refuses connections past the in-flight and queue caps', () async {
      final pipe = await _HostPipe.start(
        BridgeSurface.provider,
        limits: const BridgeLimits(maxInFlightRequests: 1, maxQueuedRequests: 1),
      );
      addTearDown(pipe.dispose);

      final first = pipe.post('/one', 'a');
      final firstStart = await pipe.nextRequestStart();
      final queued = pipe.post('/two', 'b');
      // The third connection has nowhere to wait and must be refused outright.
      final refused = await pipe.post('/three', 'c');

      expect(refused.statusCode, HttpStatus.serviceUnavailable);
      expect(refused.body, contains('in-flight limit'));

      pipe.send(BridgeFrame(type: BridgeFrameType.responseStart, requestId: firstStart.requestId));
      pipe.send(BridgeFrame(type: BridgeFrameType.responseEnd, requestId: firstStart.requestId));
      expect((await first).statusCode, 200);

      final queuedStart = await pipe.nextRequestStart();
      pipe.send(BridgeFrame(type: BridgeFrameType.responseStart, requestId: queuedStart.requestId));
      pipe.send(BridgeFrame(type: BridgeFrameType.responseEnd, requestId: queuedStart.requestId));
      expect((await queued).statusCode, 200);
    });

    test('cancels the matching in-flight request when its client disconnects', () async {
      final pipe = await _HostPipe.start(BridgeSurface.provider);
      addTearDown(pipe.dispose);

      final socket = await Socket.connect(InternetAddress.loopbackIPv4, pipe.runner.boundPort);
      socket.write('POST /v1/messages HTTP/1.1\r\nhost: localhost\r\ncontent-length: 1\r\n\r\nx');
      await socket.flush();

      final start = await pipe.nextRequestStart();
      pipe.send(BridgeFrame(type: BridgeFrameType.responseStart, requestId: start.requestId));
      await socket.close();
      socket.destroy();

      // The runner learns the peer is gone from a failed write, and the OS may
      // not have delivered the reset yet — keep streaming until it notices.
      final pump = Timer.periodic(const Duration(milliseconds: 50), (_) {
        pipe.send(
          BridgeFrame(
            type: BridgeFrameType.responseChunk,
            requestId: start.requestId,
            body: List.filled(64 * 1024, 65),
          ),
        );
      });
      addTearDown(pump.cancel);

      var frame = await pipe.frames.next;
      while (frame.type != BridgeFrameType.cancel) {
        frame = await pipe.frames.next;
      }
      pump.cancel();
      expect(frame.requestId, start.requestId);
      expect(frame.metadata['reason'], 'client disconnected');
    });
  });
}

/// Drives a real [BridgeRunner] over in-memory pipes, standing in for the host.
final class _HostPipe {
  new _(this.runner, this._toBridge, this._fromBridge, this.frames, this.handshake, this.ready);

  final BridgeRunner runner;
  final StreamController<List<int>> _toBridge;
  final StreamController<List<int>> _fromBridge;
  final StreamQueue<BridgeFrame> frames;
  final BridgeFrame handshake;
  final BridgeFrame ready;
  final HttpClient _client = HttpClient();

  static Future<_HostPipe> start(BridgeSurface surface, {BridgeLimits limits = BridgeLimits.defaults}) async {
    final toBridge = StreamController<List<int>>();
    final fromBridge = StreamController<List<int>>();
    final runner = BridgeRunner(
      surface: surface,
      hostInput: toBridge.stream,
      hostOutput: IOSink(fromBridge.sink),
      limits: limits,
      port: 0,
    );
    final frames = _frameQueue(fromBridge.stream, limits: limits);
    final started = runner.start();

    final handshake = await frames.next;
    toBridge.add(
      encodeBridgeFrame(
        BridgeFrame(
          type: BridgeFrameType.handshakeAck,
          metadata: {'version': bridgeProtocolVersion, 'surface': surface.name},
        ),
        limits: limits,
      ),
    );
    await started;
    final ready = await frames.next;
    return _HostPipe._(runner, toBridge, fromBridge, frames, handshake, ready);
  }

  void send(BridgeFrame frame) => _toBridge.add(encodeBridgeFrame(frame, limits: runner.limits));

  Future<BridgeFrame> nextRequestStart() async {
    var frame = await frames.next;
    while (frame.type != BridgeFrameType.requestStart) {
      frame = await frames.next;
    }
    return frame;
  }

  Future<_HttpResult> post(String path, String body) async {
    final request = await _client.post(InternetAddress.loopbackIPv4.address, runner.boundPort, path);
    request.headers.contentType = ContentType.json;
    request.write(body);
    final response = await request.close();
    final text = await response.transform(utf8.decoder).join();
    return _HttpResult(response.statusCode, text, {
      for (final name in ['content-type']) name: response.headers.value(name) ?? '',
    });
  }

  Future<void> dispose() async {
    _client.close(force: true);
    await runner.close();
    await _toBridge.close();
    await _fromBridge.close();
  }
}

final class _HttpResult {
  const new(this.statusCode, this.body, this.headers);

  final int statusCode;
  final String body;
  final Map<String, String> headers;
}

/// Decodes the bridge's output eagerly.
///
/// The subscription on [bytes] is never paused: `IOSink.flush()` only completes
/// once the consumer accepts the data, so a lazily-drained queue would deadlock
/// the runner's per-frame flush.
StreamQueue<BridgeFrame> _frameQueue(Stream<List<int>> bytes, {BridgeLimits limits = BridgeLimits.defaults}) {
  final reader = BridgeFrameReader(limits: limits);
  final frames = StreamController<BridgeFrame>();
  bytes.listen((chunk) => reader.addChunk(chunk).forEach(frames.add), onError: frames.addError, onDone: frames.close);
  return StreamQueue<BridgeFrame>(frames.stream);
}
