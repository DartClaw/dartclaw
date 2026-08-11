import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:dartclaw_bridge/dartclaw_bridge.dart';
import 'package:test/test.dart';

void main() {
  group('encodeBridgeFrame', () {
    test('round-trips type, request ID, metadata and body', () {
      final frame = BridgeFrame(
        type: BridgeFrameType.requestStart,
        requestId: 4242,
        metadata: {'method': 'POST', 'path': '/v1/messages'},
        body: const [1, 2, 3],
      );

      final decoded = BridgeFrameReader().addChunk(encodeBridgeFrame(frame));

      expect(decoded, hasLength(1));
      expect(decoded.single.type, BridgeFrameType.requestStart);
      expect(decoded.single.requestId, 4242);
      expect(decoded.single.metadata, {'method': 'POST', 'path': '/v1/messages'});
      expect(decoded.single.body, [1, 2, 3]);
    });

    test('rejects metadata beyond the configured cap rather than emitting it', () {
      const limits = BridgeLimits(maxMetadataBytes: 32);
      final frame = BridgeFrame(type: BridgeFrameType.requestStart, metadata: {'path': 'x' * 64});

      expect(
        () => encodeBridgeFrame(frame, limits: limits),
        throwsA(isA<BridgeProtocolException>().having((e) => e.message, 'message', contains('metadata exceeds'))),
      );
    });

    test('rejects a body chunk beyond the configured cap', () {
      const limits = BridgeLimits(maxBodyChunkBytes: 8);
      final frame = BridgeFrame(type: BridgeFrameType.responseChunk, body: List.filled(9, 0));

      expect(() => encodeBridgeFrame(frame, limits: limits), throwsA(isA<BridgeProtocolException>()));
    });
  });

  group('BridgeFrameReader', () {
    test('reconstructs a body byte-exactly across single-byte reads', () {
      final random = Random(20260811);
      final body = Uint8List.fromList(List.generate(9000, (_) => random.nextInt(256)));
      final bytes = encodeBridgeFrame(BridgeFrame(type: BridgeFrameType.responseChunk, requestId: 7, body: body));
      final reader = BridgeFrameReader();

      final frames = <BridgeFrame>[];
      for (final byte in bytes) {
        frames.addAll(reader.addChunk([byte]));
      }

      expect(frames, hasLength(1));
      expect(frames.single.body, body);
    });

    test('decodes several frames delivered in one chunk', () {
      final builder = BytesBuilder()
        ..add(encodeBridgeFrame(const BridgeFrame(type: BridgeFrameType.requestStart, requestId: 1)))
        ..add(encodeBridgeFrame(const BridgeFrame(type: BridgeFrameType.requestEnd, requestId: 1)))
        ..add(encodeBridgeFrame(const BridgeFrame(type: BridgeFrameType.requestStart, requestId: 2)));

      final frames = BridgeFrameReader().addChunk(builder.takeBytes());

      expect(frames.map((frame) => frame.requestId), [1, 1, 2]);
      expect(frames.map((frame) => frame.type), [
        BridgeFrameType.requestStart,
        BridgeFrameType.requestEnd,
        BridgeFrameType.requestStart,
      ]);
    });

    test('interleaved concurrent request IDs stay separable', () {
      final builder = BytesBuilder()
        ..add(encodeBridgeFrame(const BridgeFrame(type: BridgeFrameType.responseChunk, requestId: 1, body: [10])))
        ..add(encodeBridgeFrame(const BridgeFrame(type: BridgeFrameType.responseChunk, requestId: 2, body: [20])))
        ..add(encodeBridgeFrame(const BridgeFrame(type: BridgeFrameType.responseChunk, requestId: 1, body: [11])));

      final frames = BridgeFrameReader().addChunk(builder.takeBytes());

      expect(frames.where((f) => f.requestId == 1).expand((f) => f.body), [10, 11]);
      expect(frames.where((f) => f.requestId == 2).expand((f) => f.body), [20]);
    });

    test('rejects a declared payload length beyond the cap before buffering it', () {
      const limits = BridgeLimits(maxMetadataBytes: 16, maxBodyChunkBytes: 16);
      final oversized = Uint8List(8);
      ByteData.view(oversized.buffer).setUint32(0, limits.maxPayloadBytes + 1);

      expect(
        () => BridgeFrameReader(limits: limits).addChunk(oversized),
        throwsA(isA<BridgeProtocolException>().having((e) => e.message, 'message', contains('exceeds'))),
      );
    });

    test('rejects a payload length shorter than the frame header', () {
      final truncated = Uint8List(8);
      ByteData.view(truncated.buffer).setUint32(0, 2);

      expect(() => BridgeFrameReader().addChunk(truncated), throwsA(isA<BridgeProtocolException>()));
    });

    test('rejects an unknown frame type code', () {
      final frame = encodeBridgeFrame(const BridgeFrame(type: BridgeFrameType.ready));
      frame[4] = 0x7f;

      expect(
        () => BridgeFrameReader().addChunk(frame),
        throwsA(isA<BridgeProtocolException>().having((e) => e.message, 'message', contains('unknown frame type'))),
      );
    });

    test('rejects a metadata length that overruns the frame', () {
      final frame = encodeBridgeFrame(const BridgeFrame(type: BridgeFrameType.ready, metadata: {'a': 1}));
      ByteData.view(frame.buffer).setUint16(9, 0xff);

      expect(
        () => BridgeFrameReader().addChunk(frame),
        throwsA(isA<BridgeProtocolException>().having((e) => e.message, 'message', contains('overruns'))),
      );
    });

    test('rejects metadata that is not a JSON object', () {
      final metadata = utf8.encode('[1,2,3]');
      final payload = Uint8List(frameLengthPrefixBytes + frameHeaderBytes + metadata.length);
      final view = ByteData.view(payload.buffer)
        ..setUint32(0, frameHeaderBytes + metadata.length)
        ..setUint32(5, 0)
        ..setUint16(9, metadata.length);
      payload[4] = BridgeFrameType.ready.code;
      payload.setRange(11, payload.length, metadata);
      expect(view.getUint32(0), frameHeaderBytes + metadata.length);

      expect(
        () => BridgeFrameReader().addChunk(payload),
        throwsA(isA<BridgeProtocolException>().having((e) => e.message, 'message', contains('JSON object'))),
      );
    });

    test('rejects malformed JSON metadata', () {
      final metadata = utf8.encode('{not json');
      final payload = Uint8List(frameLengthPrefixBytes + frameHeaderBytes + metadata.length);
      ByteData.view(payload.buffer)
        ..setUint32(0, frameHeaderBytes + metadata.length)
        ..setUint32(5, 0)
        ..setUint16(9, metadata.length);
      payload[4] = BridgeFrameType.ready.code;
      payload.setRange(11, payload.length, metadata);

      expect(() => BridgeFrameReader().addChunk(payload), throwsA(isA<BridgeProtocolException>()));
    });
  });
}
