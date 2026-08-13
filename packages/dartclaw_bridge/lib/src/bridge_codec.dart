import 'dart:convert';
import 'dart:typed_data';

import 'bridge_protocol.dart';

/// Serializes one frame.
///
/// Throws [BridgeProtocolException] when the frame exceeds [limits] — an
/// oversized frame is a bug on the sending side, not something the peer should
/// have to absorb.
Uint8List encodeBridgeFrame(BridgeFrame frame, {BridgeLimits limits = BridgeLimits.defaults}) {
  if (frame.requestId < 0 || frame.requestId > 0xffffffff) {
    throw BridgeProtocolException('request ID out of range: ${frame.requestId}');
  }
  final metadataBytes = frame.metadata.isEmpty ? const <int>[] : utf8.encode(jsonEncode(frame.metadata));
  // 0xffff is the uint16 metadata-length field's capacity; exceeding it would
  // wrap the field and decode as a corrupt frame rather than being rejected.
  if (metadataBytes.length > limits.maxMetadataBytes || metadataBytes.length > 0xffff) {
    throw BridgeProtocolException('metadata exceeds ${limits.maxMetadataBytes} bytes');
  }
  if (frame.body.length > limits.maxBodyChunkBytes) {
    throw BridgeProtocolException('body chunk exceeds ${limits.maxBodyChunkBytes} bytes');
  }

  final payloadLength = frameHeaderBytes + metadataBytes.length + frame.body.length;
  final out = Uint8List(frameLengthPrefixBytes + payloadLength);
  final view = ByteData.view(out.buffer);
  view.setUint32(0, payloadLength);
  out[4] = frame.type.code;
  view.setUint32(5, frame.requestId);
  view.setUint16(9, metadataBytes.length);
  out.setRange(11, 11 + metadataBytes.length, metadataBytes);
  out.setRange(11 + metadataBytes.length, out.length, frame.body);
  return out;
}

/// Incremental frame parser tolerant of arbitrary chunk boundaries.
///
/// Buffering is bounded by [BridgeLimits.maxPayloadBytes]: an over-long
/// declared length is rejected before any allocation, so a hostile peer cannot
/// grow the reader.
final class BridgeFrameReader {
  BridgeFrameReader({this.limits = BridgeLimits.defaults});

  final BridgeLimits limits;

  Uint8List _buffer = Uint8List(0);
  int _length = 0;

  /// Decodes every complete frame in [chunk] plus previously buffered bytes.
  List<BridgeFrame> addChunk(List<int> chunk) {
    _append(chunk);
    final frames = <BridgeFrame>[];
    var offset = 0;
    while (_length - offset >= frameLengthPrefixBytes) {
      final view = ByteData.view(_buffer.buffer, _buffer.offsetInBytes);
      final payloadLength = view.getUint32(offset);
      if (payloadLength < frameHeaderBytes) {
        throw BridgeProtocolException('frame payload length $payloadLength below header size');
      }
      if (payloadLength > limits.maxPayloadBytes) {
        throw BridgeProtocolException('frame payload length $payloadLength exceeds ${limits.maxPayloadBytes}');
      }
      if (_length - offset - frameLengthPrefixBytes < payloadLength) break;
      frames.add(_decodePayload(offset + frameLengthPrefixBytes, payloadLength));
      offset += frameLengthPrefixBytes + payloadLength;
    }
    _consume(offset);
    return frames;
  }

  BridgeFrame _decodePayload(int start, int payloadLength) {
    final view = ByteData.view(_buffer.buffer, _buffer.offsetInBytes);
    final typeCode = _buffer[start];
    final type = BridgeFrameType.fromCode(typeCode);
    if (type == null) {
      throw BridgeProtocolException('unknown frame type 0x${typeCode.toRadixString(16)}');
    }
    final requestId = view.getUint32(start + 1);
    final metadataLength = view.getUint16(start + 5);
    if (metadataLength > limits.maxMetadataBytes) {
      throw BridgeProtocolException('metadata length $metadataLength exceeds ${limits.maxMetadataBytes}');
    }
    if (frameHeaderBytes + metadataLength > payloadLength) {
      throw BridgeProtocolException('metadata length $metadataLength overruns frame');
    }
    final metadataStart = start + frameHeaderBytes;
    final bodyStart = metadataStart + metadataLength;
    final bodyEnd = start + payloadLength;
    if (bodyEnd - bodyStart > limits.maxBodyChunkBytes) {
      throw BridgeProtocolException('body chunk exceeds ${limits.maxBodyChunkBytes} bytes');
    }

    Map<String, Object?> metadata = const {};
    if (metadataLength > 0) {
      final Object? decoded;
      try {
        decoded = jsonDecode(utf8.decode(_buffer.sublist(metadataStart, bodyStart)));
      } on FormatException catch (error) {
        throw BridgeProtocolException('frame metadata is not valid JSON: ${error.message}');
      }
      if (decoded is! Map<String, Object?>) {
        throw BridgeProtocolException('frame metadata must be a JSON object');
      }
      metadata = decoded;
    }
    return BridgeFrame(
      type: type,
      requestId: requestId,
      metadata: metadata,
      body: bodyEnd == bodyStart ? const [] : _buffer.sublist(bodyStart, bodyEnd),
    );
  }

  void _append(List<int> chunk) {
    if (chunk.isEmpty) return;
    final required = _length + chunk.length;
    if (required > _buffer.length) {
      // The reader only ever holds one partial frame, so the ceiling is a full
      // payload plus its length prefix plus the chunk that completed it.
      final grown = Uint8List(required * 2);
      grown.setRange(0, _length, _buffer);
      _buffer = grown;
    }
    _buffer.setRange(_length, required, chunk);
    _length = required;
  }

  void _consume(int offset) {
    if (offset == 0) return;
    if (offset == _length) {
      _length = 0;
      return;
    }
    _buffer.setRange(0, _length - offset, _buffer, offset);
    _length -= offset;
  }
}
