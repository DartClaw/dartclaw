import 'dart:convert';

import 'package:test/test.dart';

import 'package:dartclaw_core/src/harness/claude_protocol.dart';

/// Helper — encode a map to a JSON string (single JSONL line).
String _j(Map<String, dynamic> m) => jsonEncode(m);

void main() {
  group('parseJsonlLine', () {
    // -----------------------------------------------------------------
    // Edge cases / error paths
    // -----------------------------------------------------------------

    group('edge cases', () {
      test('empty string returns null', () {
        expect(parseJsonlLine(''), isNull);
      });

      test('malformed JSON returns null', () {
        expect(parseJsonlLine('{not json'), isNull);
      });

      test('valid JSON with unknown type returns null', () {
        expect(parseJsonlLine(_j({'type': 'banana'})), isNull);
      });

      test('valid JSON with no type key returns null', () {
        expect(parseJsonlLine(_j({'foo': 'bar'})), isNull);
      });

      test('JSON array (not object) returns null', () {
        expect(parseJsonlLine('[1,2,3]'), isNull);
      });
    });

    // -----------------------------------------------------------------
    // SystemInit (type: system, subtype: init)
    // -----------------------------------------------------------------

    group('SystemInit', () {
      test('parses init with session_id and tools', () {
        final msg = parseJsonlLine(
          _j({
            'type': 'system',
            'subtype': 'init',
            'session_id': 'sess-abc',
            'tools': [
              {'name': 'bash'},
              {'name': 'read'},
            ],
          }),
        );

        expect(msg, isA<SystemInit>());
        final init = msg as SystemInit;
        expect(init.sessionId, 'sess-abc');
        expect(init.toolCount, 2);
      });

      test('missing session_id yields null sessionId', () {
        final msg = parseJsonlLine(_j({'type': 'system', 'subtype': 'init', 'tools': []}));

        expect(msg, isA<SystemInit>());
        expect((msg as SystemInit).sessionId, isNull);
      });

      test('missing tools list yields toolCount 0', () {
        final msg = parseJsonlLine(_j({'type': 'system', 'subtype': 'init'}));

        expect(msg, isA<SystemInit>());
        expect((msg as SystemInit).toolCount, 0);
      });

      test('non-init subtype returns null', () {
        final msg = parseJsonlLine(_j({'type': 'system', 'subtype': 'heartbeat'}));
        expect(msg, isNull);
      });
    });

    // -----------------------------------------------------------------
    // StreamTextDelta (type: stream_event, content_block_delta/text_delta)
    // -----------------------------------------------------------------

    group('StreamTextDelta', () {
      test('parses text_delta from content_block_delta', () {
        final msg = parseJsonlLine(
          _j({
            'type': 'stream_event',
            'event': {
              'type': 'content_block_delta',
              'delta': {'type': 'text_delta', 'text': 'Hello'},
            },
          }),
        );

        expect(msg, isA<StreamTextDelta>());
        expect((msg as StreamTextDelta).text, 'Hello');
      });

      test('non-content_block_delta event returns null', () {
        final msg = parseJsonlLine(
          _j({
            'type': 'stream_event',
            'event': {'type': 'message_start'},
          }),
        );
        expect(msg, isNull);
      });

      test('non-text_delta delta type returns null', () {
        final msg = parseJsonlLine(
          _j({
            'type': 'stream_event',
            'event': {
              'type': 'content_block_delta',
              'delta': {'type': 'input_json_delta', 'partial_json': '{}'},
            },
          }),
        );
        expect(msg, isNull);
      });

      test('empty text returns null', () {
        final msg = parseJsonlLine(
          _j({
            'type': 'stream_event',
            'event': {
              'type': 'content_block_delta',
              'delta': {'type': 'text_delta', 'text': ''},
            },
          }),
        );
        expect(msg, isNull);
      });

      test('missing event key returns null', () {
        final msg = parseJsonlLine(_j({'type': 'stream_event'}));
        expect(msg, isNull);
      });
    });

    // -----------------------------------------------------------------
    // ToolUseBlock (type: assistant, content block type: tool_use)
    // -----------------------------------------------------------------

    group('ToolUseBlock', () {
      test('parses tool_use block from assistant message', () {
        final msg = parseJsonlLine(
          _j({
            'type': 'assistant',
            'message': {
              'content': [
                {
                  'type': 'tool_use',
                  'name': 'bash',
                  'id': 'tu_123',
                  'input': {'command': 'ls'},
                },
              ],
            },
          }),
        );

        expect(msg, isA<ToolUseBlock>());
        final tu = msg as ToolUseBlock;
        expect(tu.name, 'bash');
        expect(tu.id, 'tu_123');
        expect(tu.input, {'command': 'ls'});
      });

      test('returns first tool_use when multiple blocks present', () {
        final msg = parseJsonlLine(
          _j({
            'type': 'assistant',
            'message': {
              'content': [
                {'type': 'text', 'text': 'Let me run that.'},
                {
                  'type': 'tool_use',
                  'name': 'read',
                  'id': 'tu_first',
                  'input': {'path': '/tmp'},
                },
                {'type': 'tool_use', 'name': 'write', 'id': 'tu_second', 'input': {}},
              ],
            },
          }),
        );

        expect(msg, isA<ToolUseBlock>());
        expect((msg as ToolUseBlock).id, 'tu_first');
      });

      test('missing name/id default gracefully', () {
        final msg = parseJsonlLine(
          _j({
            'type': 'assistant',
            'message': {
              'content': [
                {'type': 'tool_use'},
              ],
            },
          }),
        );

        expect(msg, isA<ToolUseBlock>());
        final tu = msg as ToolUseBlock;
        expect(tu.name, 'unknown');
        expect(tu.id, '');
        expect(tu.input, isEmpty);
      });
    });

    // -----------------------------------------------------------------
    // ToolResultBlock (type: assistant, content block type: tool_result)
    // -----------------------------------------------------------------

    group('ToolResultBlock', () {
      test('parses tool_result block', () {
        final msg = parseJsonlLine(
          _j({
            'type': 'assistant',
            'message': {
              'content': [
                {'type': 'tool_result', 'tool_use_id': 'tu_123', 'content': 'file contents here', 'is_error': false},
              ],
            },
          }),
        );

        expect(msg, isA<ToolResultBlock>());
        final tr = msg as ToolResultBlock;
        expect(tr.toolId, 'tu_123');
        expect(tr.output, 'file contents here');
        expect(tr.isError, isFalse);
      });

      test('is_error true is preserved', () {
        final msg = parseJsonlLine(
          _j({
            'type': 'assistant',
            'message': {
              'content': [
                {'type': 'tool_result', 'tool_use_id': 'tu_err', 'content': 'permission denied', 'is_error': true},
              ],
            },
          }),
        );

        expect(msg, isA<ToolResultBlock>());
        expect((msg as ToolResultBlock).isError, isTrue);
      });

      test('missing fields default gracefully', () {
        final msg = parseJsonlLine(
          _j({
            'type': 'assistant',
            'message': {
              'content': [
                {'type': 'tool_result'},
              ],
            },
          }),
        );

        expect(msg, isA<ToolResultBlock>());
        final tr = msg as ToolResultBlock;
        expect(tr.toolId, '');
        expect(tr.output, '');
        expect(tr.isError, isFalse);
      });
    });

    // -----------------------------------------------------------------
    // assistant message — text-only content returns null (no double-count)
    // -----------------------------------------------------------------

    group('assistant (text-only)', () {
      test('text-only content blocks return null', () {
        final msg = parseJsonlLine(
          _j({
            'type': 'assistant',
            'message': {
              'content': [
                {'type': 'text', 'text': 'Hello world'},
              ],
            },
          }),
        );
        expect(msg, isNull);
      });

      test('missing message key returns null', () {
        final msg = parseJsonlLine(_j({'type': 'assistant'}));
        expect(msg, isNull);
      });

      test('empty content array returns null', () {
        final msg = parseJsonlLine(
          _j({
            'type': 'assistant',
            'message': {'content': []},
          }),
        );
        expect(msg, isNull);
      });
    });

    // -----------------------------------------------------------------
    // ControlRequest (type: control_request)
    // -----------------------------------------------------------------

    group('ControlRequest', () {
      test('parses control request with subtype', () {
        final msg = parseJsonlLine(
          _j({
            'type': 'control_request',
            'request_id': 'req-42',
            'request': {'subtype': 'can_use_tool', 'tool_name': 'bash'},
          }),
        );

        expect(msg, isA<ControlRequest>());
        final cr = msg as ControlRequest;
        expect(cr.requestId, 'req-42');
        expect(cr.subtype, 'can_use_tool');
        expect(cr.data['tool_name'], 'bash');
      });

      test('missing request_id defaults to empty string', () {
        final msg = parseJsonlLine(
          _j({
            'type': 'control_request',
            'request': {'subtype': 'hook_callback'},
          }),
        );

        expect(msg, isA<ControlRequest>());
        expect((msg as ControlRequest).requestId, '');
      });

      test('missing request object defaults gracefully', () {
        final msg = parseJsonlLine(_j({'type': 'control_request', 'request_id': 'req-99'}));

        expect(msg, isA<ControlRequest>());
        final cr = msg as ControlRequest;
        expect(cr.subtype, 'unknown');
        expect(cr.data, isEmpty);
      });
    });

    // -----------------------------------------------------------------
    // TurnResult (type: result)
    // -----------------------------------------------------------------

    group('TurnResult', () {
      test('parses result with all fields', () {
        final msg = parseJsonlLine(
          _j({'type': 'result', 'stop_reason': 'end_turn', 'total_cost_usd': 0.0042, 'duration_ms': 1500}),
        );

        expect(msg, isA<TurnResult>());
        final tr = msg as TurnResult;
        expect(tr.stopReason, 'end_turn');
        expect(tr.costUsd, closeTo(0.0042, 1e-6));
        expect(tr.durationMs, 1500);
      });

      test('all fields optional — minimal result', () {
        final msg = parseJsonlLine(_j({'type': 'result'}));

        expect(msg, isA<TurnResult>());
        final tr = msg as TurnResult;
        expect(tr.stopReason, isNull);
        expect(tr.costUsd, isNull);
        expect(tr.durationMs, isNull);
      });

      test('integer cost is converted to double', () {
        final msg = parseJsonlLine(_j({'type': 'result', 'total_cost_usd': 1}));

        expect(msg, isA<TurnResult>());
        expect((msg as TurnResult).costUsd, 1.0);
      });
    });

    // -----------------------------------------------------------------
    // CompactBoundary (type: system, subtype: compact_boundary)
    // -----------------------------------------------------------------

    group('CompactBoundary', () {
      test('parses compact_boundary with trigger and pre_tokens', () {
        final msg = parseJsonlLine(
          _j({'type': 'system', 'subtype': 'compact_boundary', 'trigger': 'auto', 'pre_tokens': 142857}),
        );

        expect(msg, isA<CompactBoundary>());
        final cb = msg as CompactBoundary;
        expect(cb.trigger, 'auto');
        expect(cb.preTokens, 142857);
      });

      test('parses compact_boundary without pre_tokens (null)', () {
        final msg = parseJsonlLine(_j({'type': 'system', 'subtype': 'compact_boundary', 'trigger': 'manual'}));

        expect(msg, isA<CompactBoundary>());
        final cb = msg as CompactBoundary;
        expect(cb.trigger, 'manual');
        expect(cb.preTokens, isNull);
      });

      test('compact_boundary with missing trigger defaults to "auto"', () {
        final msg = parseJsonlLine(_j({'type': 'system', 'subtype': 'compact_boundary'}));

        expect(msg, isA<CompactBoundary>());
        expect((msg as CompactBoundary).trigger, 'auto');
      });

      test('system subtype other than init and compact_boundary returns null', () {
        final msg = parseJsonlLine(_j({'type': 'system', 'subtype': 'unknown_subtype'}));
        expect(msg, isNull);
      });
    });
  });
}
