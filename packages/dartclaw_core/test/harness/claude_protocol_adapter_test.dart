import 'dart:convert';

import 'package:dartclaw_core/src/harness/claude_protocol_adapter.dart';
import 'package:dartclaw_core/src/harness/protocol_message.dart';
import 'package:test/test.dart';

String _j(Map<String, dynamic> value) => jsonEncode(value);

void main() {
  group('ClaudeProtocolAdapter.parseLine', () {
    test('parses system init', () {
      final adapter = ClaudeProtocolAdapter();
      final msg = adapter.parseLine(
        _j({
          'type': 'system',
          'subtype': 'init',
          'session_id': 'sess-abc',
          'tools': [
            {'name': 'bash'},
          ],
          'context_window': 1000,
        }),
      );

      expect(msg, isA<SystemInit>());
      final init = msg! as SystemInit;
      expect(init.sessionId, 'sess-abc');
      expect(init.toolCount, 1);
      expect(init.contextWindow, 1000);
    });

    test('parses content_block_delta text delta', () {
      final adapter = ClaudeProtocolAdapter();
      final msg = adapter.parseLine(
        _j({
          'type': 'stream_event',
          'event': {
            'type': 'content_block_delta',
            'delta': {'type': 'text_delta', 'text': 'Hello'},
          },
        }),
      );

      expect(msg, isA<TextDelta>());
      expect((msg! as TextDelta).text, 'Hello');
    });

    test('parses assistant tool_use', () {
      final adapter = ClaudeProtocolAdapter();
      final msg = adapter.parseLine(
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

      expect(msg, isA<ToolUse>());
      final toolUse = msg! as ToolUse;
      expect(toolUse.name, 'bash');
      expect(toolUse.id, 'tu_123');
      expect(toolUse.input, {'command': 'ls'});
    });

    test('parses assistant tool_result', () {
      final adapter = ClaudeProtocolAdapter();
      final msg = adapter.parseLine(
        _j({
          'type': 'assistant',
          'message': {
            'content': [
              {'type': 'tool_result', 'tool_use_id': 'tu_123', 'content': 'file contents here', 'is_error': false},
            ],
          },
        }),
      );

      expect(msg, isA<ToolResult>());
      final toolResult = msg! as ToolResult;
      expect(toolResult.toolId, 'tu_123');
      expect(toolResult.output, 'file contents here');
      expect(toolResult.isError, isFalse);
    });

    test('parses control_request', () {
      final adapter = ClaudeProtocolAdapter();
      final msg = adapter.parseLine(
        _j({
          'type': 'control_request',
          'request_id': 'req-42',
          'request': {'subtype': 'can_use_tool', 'tool_name': 'bash'},
        }),
      );

      expect(msg, isA<ControlRequest>());
      final controlRequest = msg! as ControlRequest;
      expect(controlRequest.requestId, 'req-42');
      expect(controlRequest.subtype, 'can_use_tool');
      expect(controlRequest.data['tool_name'], 'bash');
    });

    test('parses result', () {
      final adapter = ClaudeProtocolAdapter();
      final msg = adapter.parseLine(
        _j({'type': 'result', 'stop_reason': 'end_turn', 'total_cost_usd': 0.0042, 'duration_ms': 1500}),
      );

      expect(msg, isA<TurnComplete>());
      final result = msg! as TurnComplete;
      expect(result.stopReason, 'end_turn');
      expect(result.costUsd, closeTo(0.0042, 1e-6));
      expect(result.durationMs, 1500);
      expect(result.cacheReadTokens, isNull);
      expect(result.cacheWriteTokens, isNull);
    });

    test('parses result with cache tokens normalised to cacheReadTokens and cacheWriteTokens', () {
      final adapter = ClaudeProtocolAdapter();
      final msg = adapter.parseLine(
        _j({
          'type': 'result',
          'stop_reason': 'end_turn',
          'usage': {'cache_read_input_tokens': 100, 'cache_creation_input_tokens': 50},
        }),
      );

      expect(msg, isA<TurnComplete>());
      final result = msg! as TurnComplete;
      expect(result.cacheReadTokens, 100);
      expect(result.cacheWriteTokens, 50);
    });

    test('parses result without cache fields — both default to null', () {
      final adapter = ClaudeProtocolAdapter();
      final msg = adapter.parseLine(
        _j({'type': 'result', 'stop_reason': 'end_turn'}),
      );

      expect(msg, isA<TurnComplete>());
      final result = msg! as TurnComplete;
      expect(result.cacheReadTokens, isNull);
      expect(result.cacheWriteTokens, isNull);
    });

    test('empty line returns null', () {
      final adapter = ClaudeProtocolAdapter();
      expect(adapter.parseLine(''), isNull);
    });

    test('malformed JSON returns null', () {
      final adapter = ClaudeProtocolAdapter();
      expect(adapter.parseLine('{not json'), isNull);
    });

    test('unknown type returns null', () {
      final adapter = ClaudeProtocolAdapter();
      expect(adapter.parseLine(_j({'type': 'banana'})), isNull);
    });
  });

  group('ClaudeProtocolAdapter.buildTurnRequest', () {
    test('builds base payload', () {
      final adapter = ClaudeProtocolAdapter();
      expect(adapter.buildTurnRequest(message: 'Hello'), {
        'type': 'user',
        'message': {'role': 'user', 'content': 'Hello'},
      });
    });

    test('includes system_prompt', () {
      final adapter = ClaudeProtocolAdapter();
      expect(adapter.buildTurnRequest(message: 'Hello', systemPrompt: 'Be concise'), {
        'type': 'user',
        'message': {'role': 'user', 'content': 'Hello'},
        'system_prompt': 'Be concise',
      });
    });

    test('omits system_prompt when null', () {
      final adapter = ClaudeProtocolAdapter();
      final payload = adapter.buildTurnRequest(message: 'Hello', systemPrompt: null);
      expect(payload.containsKey('system_prompt'), isFalse);
    });

    test('includes resume when true', () {
      final adapter = ClaudeProtocolAdapter();
      expect(adapter.buildTurnRequest(message: 'Hello', resume: true), {
        'type': 'user',
        'message': {'role': 'user', 'content': 'Hello'},
        'resume': true,
      });
    });
  });

  group('ClaudeProtocolAdapter.buildApprovalResponse', () {
    test('allow with toolUseId', () {
      final adapter = ClaudeProtocolAdapter();
      expect(adapter.buildApprovalResponse('req-1', allow: true, toolUseId: 'tu_123'), {
        'type': 'control_response',
        'response': {
          'subtype': 'success',
          'request_id': 'req-1',
          'response': {'behavior': 'allow', 'toolUseID': 'tu_123'},
        },
      });
    });

    test('deny', () {
      final adapter = ClaudeProtocolAdapter();
      final payload = adapter.buildApprovalResponse('req-2', allow: false);
      expect(payload, {
        'type': 'control_response',
        'response': {
          'subtype': 'success',
          'request_id': 'req-2',
          'response': {'behavior': 'deny'},
        },
      });
      expect((payload['response'] as Map<String, dynamic>)['response'], isNot(contains('toolUseID')));
    });
  });

  group('ClaudeProtocolAdapter.buildHookResponse', () {
    test('allow', () {
      final adapter = ClaudeProtocolAdapter();
      expect(adapter.buildHookResponse('req-3', allow: true), {
        'type': 'control_response',
        'response': {
          'subtype': 'success',
          'request_id': 'req-3',
          'response': {
            'continue': true,
            'hookSpecificOutput': {'hookEventName': 'PreToolUse', 'permissionDecision': 'allow'},
          },
        },
      });
    });

    test('deny', () {
      final adapter = ClaudeProtocolAdapter();
      expect(adapter.buildHookResponse('req-4', allow: false), {
        'type': 'control_response',
        'response': {
          'subtype': 'success',
          'request_id': 'req-4',
          'response': {
            'continue': true,
            'hookSpecificOutput': {'hookEventName': 'PreToolUse', 'permissionDecision': 'deny'},
          },
        },
      });
    });
  });

  test('mapToolName returns null', () {
    final adapter = ClaudeProtocolAdapter();
    expect(adapter.mapToolName('bash'), isNull);
  });

  group('CompactBoundary', () {
    test('parses compact_boundary with trigger and preTokens', () {
      final adapter = ClaudeProtocolAdapter();
      final msg = adapter.parseLine(
        _j({'type': 'system', 'subtype': 'compact_boundary', 'trigger': 'auto', 'pre_tokens': 55000}),
      );

      expect(msg, isA<CompactBoundary>());
      final cb = msg! as CompactBoundary;
      expect(cb.trigger, 'auto');
      expect(cb.preTokens, 55000);
    });

    test('parses compact_boundary without pre_tokens', () {
      final adapter = ClaudeProtocolAdapter();
      final msg = adapter.parseLine(
        _j({'type': 'system', 'subtype': 'compact_boundary', 'trigger': 'manual'}),
      );

      expect(msg, isA<CompactBoundary>());
      expect((msg! as CompactBoundary).preTokens, isNull);
    });
  });
}
