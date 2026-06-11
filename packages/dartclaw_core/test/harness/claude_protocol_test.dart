import 'dart:convert';

import 'package:dartclaw_core/src/harness/claude_protocol.dart';
import 'package:test/test.dart';

String _j(Map<String, dynamic> m) => jsonEncode(m);

typedef _MessageExpectation = void Function(ClaudeMessage? message);

void _expectSystemInit(ClaudeMessage? message, {String? sessionId, required int toolCount, int? contextWindow}) {
  expect(message, isA<SystemInit>());
  final init = message as SystemInit;
  expect(init.sessionId, sessionId);
  expect(init.toolCount, toolCount);
  expect(init.contextWindow, contextWindow);
}

void _expectCompactBoundary(ClaudeMessage? message, {required String trigger, int? preTokens}) {
  expect(message, isA<CompactBoundary>());
  final boundary = message as CompactBoundary;
  expect(boundary.trigger, trigger);
  expect(boundary.preTokens, preTokens);
}

void _expectToolUse(
  ClaudeMessage? message, {
  required String name,
  required String id,
  Map<String, dynamic> input = const {},
}) {
  expect(message, isA<ToolUseBlock>());
  final toolUse = message as ToolUseBlock;
  expect(toolUse.name, name);
  expect(toolUse.id, id);
  expect(toolUse.input, input);
}

void _expectToolResult(ClaudeMessage? message, {required String toolId, required String output, bool isError = false}) {
  expect(message, isA<ToolResultBlock>());
  final result = message as ToolResultBlock;
  expect(result.toolId, toolId);
  expect(result.output, output);
  expect(result.isError, isError);
}

void _expectControlRequest(
  ClaudeMessage? message, {
  required String requestId,
  required String subtype,
  Map<String, dynamic> data = const {},
}) {
  expect(message, isA<ControlRequest>());
  final request = message as ControlRequest;
  expect(request.requestId, requestId);
  expect(request.subtype, subtype);
  expect(request.data, data.isEmpty ? isEmpty : data);
}

void main() {
  group('parseJsonlLine', () {
    group('ignored input', () {
      final cases = [
        (name: 'empty string', line: ''),
        (name: 'malformed JSON', line: '{not json'),
        (name: 'unknown type', line: _j({'type': 'banana'})),
        (name: 'missing type', line: _j({'foo': 'bar'})),
        (name: 'JSON array', line: '[1,2,3]'),
      ];

      for (final testCase in cases) {
        test('${testCase.name} returns null', () {
          expect(parseJsonlLine(testCase.line), isNull);
        });
      }
    });

    group('system messages', () {
      final cases = <({String name, Map<String, dynamic> json, _MessageExpectation expectMessage})>[
        (
          name: 'init with session_id and tools',
          json: {
            'type': 'system',
            'subtype': 'init',
            'session_id': 'sess-abc',
            'tools': [
              {'name': 'bash'},
              {'name': 'read'},
            ],
            'context_window': 200000,
          },
          expectMessage: (message) =>
              _expectSystemInit(message, sessionId: 'sess-abc', toolCount: 2, contextWindow: 200000),
        ),
        (
          name: 'minimal init',
          json: {'type': 'system', 'subtype': 'init'},
          expectMessage: (message) => _expectSystemInit(message, toolCount: 0),
        ),
        (
          name: 'compact boundary with trigger and pre_tokens',
          json: {'type': 'system', 'subtype': 'compact_boundary', 'trigger': 'auto', 'pre_tokens': 142857},
          expectMessage: (message) => _expectCompactBoundary(message, trigger: 'auto', preTokens: 142857),
        ),
        (
          name: 'minimal compact boundary',
          json: {'type': 'system', 'subtype': 'compact_boundary'},
          expectMessage: (message) => _expectCompactBoundary(message, trigger: 'auto'),
        ),
        (
          name: 'irrelevant system subtype',
          json: {'type': 'system', 'subtype': 'heartbeat'},
          expectMessage: (message) => expect(message, isNull),
        ),
      ];

      for (final testCase in cases) {
        test(testCase.name, () {
          testCase.expectMessage(parseJsonlLine(_j(testCase.json)));
        });
      }
    });

    group('stream text delta', () {
      final nullCases = [
        {
          'type': 'stream_event',
          'event': {'type': 'message_start'},
        },
        {
          'type': 'stream_event',
          'event': {
            'type': 'content_block_delta',
            'delta': {'type': 'input_json_delta', 'partial_json': '{}'},
          },
        },
        {
          'type': 'stream_event',
          'event': {
            'type': 'content_block_delta',
            'delta': {'type': 'text_delta', 'text': ''},
          },
        },
        {'type': 'stream_event'},
      ];

      test('parses content_block_delta text_delta', () {
        final message = parseJsonlLine(
          _j({
            'type': 'stream_event',
            'event': {
              'type': 'content_block_delta',
              'delta': {'type': 'text_delta', 'text': 'Hello'},
            },
          }),
        );

        expect(message, isA<StreamTextDelta>());
        expect((message as StreamTextDelta).text, 'Hello');
      });

      for (final json in nullCases) {
        test('ignores ${json['event'] ?? 'missing event'}', () {
          expect(parseJsonlLine(_j(json)), isNull);
        });
      }
    });

    group('assistant blocks', () {
      final cases = <({String name, List<Map<String, dynamic>> content, _MessageExpectation expectMessage})>[
        (
          name: 'tool_use',
          content: [
            {
              'type': 'tool_use',
              'name': 'bash',
              'id': 'tu_123',
              'input': {'command': 'ls'},
            },
          ],
          expectMessage: (message) => _expectToolUse(message, name: 'bash', id: 'tu_123', input: {'command': 'ls'}),
        ),
        (
          name: 'first tool_use',
          content: [
            {'type': 'text', 'text': 'Let me run that.'},
            {
              'type': 'tool_use',
              'name': 'read',
              'id': 'tu_first',
              'input': {'path': '/tmp'},
            },
            {'type': 'tool_use', 'name': 'write', 'id': 'tu_second', 'input': {}},
          ],
          expectMessage: (message) {
            expect(message, isA<ToolUseBlock>());
            expect((message as ToolUseBlock).id, 'tu_first');
          },
        ),
        (
          name: 'defaulted tool_use',
          content: [
            {'type': 'tool_use'},
          ],
          expectMessage: (message) => _expectToolUse(message, name: 'unknown', id: ''),
        ),
        (
          name: 'tool_result',
          content: [
            {'type': 'tool_result', 'tool_use_id': 'tu_123', 'content': 'file contents here', 'is_error': false},
          ],
          expectMessage: (message) => _expectToolResult(message, toolId: 'tu_123', output: 'file contents here'),
        ),
        (
          name: 'errored tool_result',
          content: [
            {'type': 'tool_result', 'tool_use_id': 'tu_err', 'content': 'permission denied', 'is_error': true},
          ],
          expectMessage: (message) =>
              _expectToolResult(message, toolId: 'tu_err', output: 'permission denied', isError: true),
        ),
        (
          name: 'defaulted tool_result',
          content: [
            {'type': 'tool_result'},
          ],
          expectMessage: (message) => _expectToolResult(message, toolId: '', output: ''),
        ),
        (
          name: 'text-only content',
          content: [
            {'type': 'text', 'text': 'Hello world'},
          ],
          expectMessage: (message) => expect(message, isNull),
        ),
        (name: 'empty content', content: [], expectMessage: (message) => expect(message, isNull)),
      ];

      for (final testCase in cases) {
        test(testCase.name, () {
          testCase.expectMessage(
            parseJsonlLine(
              _j({
                'type': 'assistant',
                'message': {'content': testCase.content},
              }),
            ),
          );
        });
      }

      test('missing message returns null', () {
        expect(parseJsonlLine(_j({'type': 'assistant'})), isNull);
      });
    });

    group('control requests', () {
      final cases = <({String name, Map<String, dynamic> json, _MessageExpectation expectMessage})>[
        (
          name: 'with subtype',
          json: {
            'type': 'control_request',
            'request_id': 'req-42',
            'request': {'subtype': 'can_use_tool', 'tool_name': 'bash'},
          },
          expectMessage: (message) => _expectControlRequest(
            message,
            requestId: 'req-42',
            subtype: 'can_use_tool',
            data: {'subtype': 'can_use_tool', 'tool_name': 'bash'},
          ),
        ),
        (
          name: 'missing request_id',
          json: {
            'type': 'control_request',
            'request': {'subtype': 'hook_callback'},
          },
          expectMessage: (message) => _expectControlRequest(
            message,
            requestId: '',
            subtype: 'hook_callback',
            data: {'subtype': 'hook_callback'},
          ),
        ),
        (
          name: 'missing request object',
          json: {'type': 'control_request', 'request_id': 'req-99'},
          expectMessage: (message) => _expectControlRequest(message, requestId: 'req-99', subtype: 'unknown'),
        ),
      ];

      for (final testCase in cases) {
        test(testCase.name, () {
          testCase.expectMessage(parseJsonlLine(_j(testCase.json)));
        });
      }
    });

    group('turn results', () {
      final cases = <({String name, Map<String, dynamic> json, _MessageExpectation expectMessage})>[
        (
          name: 'all fields',
          json: {
            'type': 'result',
            'stop_reason': 'end_turn',
            'total_cost_usd': 0.0042,
            'duration_ms': 1500,
            'usage': {'input_tokens': 10, 'output_tokens': 20, 'cache_read_input_tokens': 3},
          },
          expectMessage: (message) {
            expect(message, isA<TurnResult>());
            final result = message as TurnResult;
            expect(result.stopReason, 'end_turn');
            expect(result.costUsd, closeTo(0.0042, 1e-6));
            expect(result.durationMs, 1500);
            expect(result.inputTokens, 10);
            expect(result.outputTokens, 20);
            expect(result.cacheReadInputTokens, 3);
          },
        ),
        (
          name: 'minimal result',
          json: {'type': 'result'},
          expectMessage: (message) {
            expect(message, isA<TurnResult>());
            final result = message as TurnResult;
            expect(result.stopReason, isNull);
            expect(result.costUsd, isNull);
            expect(result.durationMs, isNull);
          },
        ),
        (
          name: 'integer cost',
          json: {'type': 'result', 'total_cost_usd': 1},
          expectMessage: (message) {
            expect(message, isA<TurnResult>());
            expect((message as TurnResult).costUsd, 1.0);
          },
        ),
      ];

      for (final testCase in cases) {
        test(testCase.name, () {
          testCase.expectMessage(parseJsonlLine(_j(testCase.json)));
        });
      }
    });
  });
}
