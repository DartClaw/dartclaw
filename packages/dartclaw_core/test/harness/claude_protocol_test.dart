import 'dart:async';
import 'dart:convert';

import 'package:dartclaw_core/src/harness/claude_protocol.dart';
import 'package:dartclaw_core/src/worker/worker_state.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' show CapturingFakeProcess;
import 'package:test/test.dart';

import 'harness_test_support.dart';

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

void _expectBackgroundTasks(ClaudeMessage? message, List<({String id, String? type})> tasks) {
  expect(message, isA<BackgroundTasksChanged>());
  expect((message as BackgroundTasksChanged).tasks, tasks);
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
          name: 'background tasks changed lists agent and shell tasks with their types',
          json: {
            'type': 'system',
            'subtype': 'background_tasks_changed',
            'tasks': [
              {'task_id': 'acaa9356', 'task_type': 'local_agent', 'description': 'probe'},
              {'task_id': 'bcdhml0ux', 'task_type': 'local_bash', 'description': 'sleep'},
            ],
          },
          expectMessage: (message) => _expectBackgroundTasks(message, [
            (id: 'acaa9356', type: 'local_agent'),
            (id: 'bcdhml0ux', type: 'local_bash'),
          ]),
        ),
        (
          name: 'background tasks changed with every task finished',
          json: {'type': 'system', 'subtype': 'background_tasks_changed', 'tasks': <Object>[]},
          expectMessage: (message) => _expectBackgroundTasks(message, const []),
        ),
        (
          name: 'background tasks changed drops entries without a task id and tolerates a missing type',
          json: {
            'type': 'system',
            'subtype': 'background_tasks_changed',
            'tasks': [
              {'task_type': 'local_agent'},
              {'task_id': 'typeless'},
              'not-a-map',
            ],
          },
          expectMessage: (message) => _expectBackgroundTasks(message, [(id: 'typeless', type: null)]),
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

    // Both message types carry tool blocks: the CLI puts the request on the
    // `assistant` message and the result on a synthetic `user` one, so a reader
    // that skips `user` never sees a tool finish.
    group('tool blocks', () {
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
          name: 'block-list tool_result content',
          content: [
            {
              'type': 'tool_result',
              'tool_use_id': 'tu_blocks',
              'content': [
                {'type': 'text', 'text': 'line one'},
                {'type': 'text', 'text': 'line two'},
              ],
            },
          ],
          expectMessage: (message) => _expectToolResult(message, toolId: 'tu_blocks', output: 'line one\nline two'),
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

      for (final messageType in const ['assistant', 'user']) {
        for (final testCase in cases) {
          test('$messageType ${testCase.name}', () {
            testCase.expectMessage(
              parseJsonlLine(
                _j({
                  'type': messageType,
                  'message': {'content': testCase.content},
                }),
              ),
            );
          });
        }

        test('$messageType missing message returns null', () {
          expect(parseJsonlLine(_j({'type': messageType})), isNull);
        });
      }
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
            expect(message, isA<TerminalResult>());
            final result = message as TerminalResult;
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
            expect(message, isA<TerminalResult>());
            final result = message as TerminalResult;
            expect(result.stopReason, isNull);
            expect(result.costUsd, isNull);
            expect(result.durationMs, isNull);
          },
        ),
        (
          name: 'integer cost',
          json: {'type': 'result', 'total_cost_usd': 1},
          expectMessage: (message) {
            expect(message, isA<TerminalResult>());
            expect((message as TerminalResult).costUsd, 1.0);
          },
        ),
        (
          name: 'final assistant text',
          json: {'type': 'result', 'stop_reason': 'end_turn', 'result': 'Fredag 4/9. Kvällsrutinen …'},
          expectMessage: (message) {
            expect((message as TerminalResult).finalText, 'Fredag 4/9. Kvällsrutinen …');
          },
        ),
        (
          name: 'empty result text is no final text',
          json: {'type': 'result', 'stop_reason': 'end_turn', 'result': ''},
          expectMessage: (message) {
            expect((message as TerminalResult).finalText, isNull);
          },
        ),
        (
          name: 'error line keeps its detail out of the final text',
          json: {'type': 'result', 'is_error': true, 'result': 'Failed to authenticate'},
          expectMessage: (message) {
            final result = message as TerminalResult;
            expect(result.stopReason, 'error');
            expect(result.finalText, isNull);
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

  group('model catalogue', () {
    Map<String, dynamic> line(String raw) => jsonDecode(raw) as Map<String, dynamic>;

    test('the account rows become entries by their own names, and applied.model resolves Default', () {
      final catalogue = claudeModelCatalogue(initialize: line(_claudeInitialize), settings: line(_claudeSettingsOpus));

      // The `default` row is the account default, not a model a reader picks.
      expect(catalogue.entries.map((entry) => (entry.id, entry.label)), [
        ('opus[1m]', 'Opus (1M context)'),
        ('claude-fable-5-1[1m]', 'Fable'),
        ('sonnet', 'Sonnet'),
        ('haiku', 'Haiku'),
      ]);
      expect(catalogue.entryFor('sonnet')!.efforts, ['low', 'medium', 'high', 'xhigh', 'max']);
      // Haiku reports no effort fields: it supports none, so Effort must lock.
      expect(catalogue.entryFor('haiku')!.efforts, isEmpty);
      expect(catalogue.defaultId, 'opus[1m]');
      expect(catalogue.defaultEntry!.label, 'Opus (1M context)');
    });

    test('an applied model no row resolves to leaves Default unresolved rather than guessed', () {
      final catalogue = claudeModelCatalogue(
        initialize: line(_claudeInitialize),
        settings: line(
          r'{"type":"control_response","response":{"subtype":"success","request_id":"req_settings_1","response":{"applied":{"model":"claude-sonnet-4-5","effort":"xhigh"},"effective":{},"sources":{}}}}',
        ),
      );

      expect(catalogue.entries, hasLength(4));
      expect(catalogue.defaultId, isNull);
    });

    // Observed wire (claude 2.1.278, `--model claude-fable-5-1[1m]`): the CLI
    // reports `applied.model` without the `[1m]` suffix, which is Fable's
    // `resolvedModel`, so Default resolves to the Fable row.
    test('an applied model equal to a row resolvedModel resolves Default to that row', () {
      final catalogue = claudeModelCatalogue(
        initialize: line(_claudeInitialize),
        settings: line(
          r'{"type":"control_response","response":{"subtype":"success","request_id":"req_settings_1","response":{"applied":{"model":"claude-fable-5-1","effort":"high","advisor":null,"ultracode":false},"effective":{},"sources":{}}}}',
        ),
      );

      expect(catalogue.defaultId, 'claude-fable-5-1[1m]');
      expect(catalogue.defaultEntry!.label, 'Fable');
    });

    // Guard for a configured id the CLI echoes back verbatim: an `applied.model`
    // equal to a row's `value` (not its `resolvedModel`) still resolves Default.
    test('an applied model echoed verbatim as a row value resolves Default to that row', () {
      final catalogue = claudeModelCatalogue(
        initialize: line(_claudeInitialize),
        settings: line(
          r'{"type":"control_response","response":{"subtype":"success","request_id":"req_settings_1","response":{"applied":{"model":"claude-fable-5-1[1m]","effort":"xhigh","advisor":null,"ultracode":false},"effective":{},"sources":{}}}}',
        ),
      );

      expect(catalogue.defaultId, 'claude-fable-5-1[1m]');
      expect(catalogue.defaultEntry!.label, 'Fable');
    });

    test('a disabled row is visible to the CLI but not offered', () {
      final catalogue = claudeModelCatalogue(
        initialize: line(
          r'{"type":"control_response","response":{"subtype":"success","request_id":"req_init_1","response":{"models":[{"value":"sonnet","resolvedModel":"claude-sonnet-5","displayName":"Sonnet","description":"Sonnet 5 · Efficient for routine tasks","supportsEffort":true,"supportedEffortLevels":["low","high"]},{"value":"opus[1m]","resolvedModel":"claude-opus-5[1m]","displayName":"Opus (1M context)","description":"Opus 5 with 1M context","disabled":true}]}}}',
        ),
        settings: line(_claudeSettingsOpus),
      );

      expect(catalogue.entries.map((entry) => entry.id), ['sonnet']);
      // Default resolves to the disabled row, which is not selectable here.
      expect(catalogue.defaultId, isNull);
    });

    test('a row without displayName fails the whole catalogue instead of yielding a partial one', () {
      expect(
        () => claudeModelCatalogue(
          initialize: line(
            r'{"type":"control_response","response":{"subtype":"success","request_id":"req_init_1","response":{"models":[{"value":"sonnet","resolvedModel":"claude-sonnet-5","displayName":"Sonnet"},{"value":"haiku","resolvedModel":"claude-haiku-4-5-20251001","description":"Haiku 4.5 · Fastest for quick answers"}]}}}',
          ),
          settings: line(_claudeSettingsOpus),
        ),
        throwsFormatException,
      );
    });

    test('a settings answer without applied.model fails discovery', () {
      expect(
        () => claudeModelCatalogue(
          initialize: line(_claudeInitialize),
          settings: line(
            r'{"type":"control_response","response":{"subtype":"success","request_id":"req_settings_1","response":{"effective":{},"sources":{}}}}',
          ),
        ),
        throwsFormatException,
      );
    });

    test('discovery sends only initialize and get_settings, then stops the process', () async {
      final process = makeCapturingClaudeProcess();
      final harness = buildClaudeHarness(
        processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) async {
          scheduleMicrotask(() => process.emitStdout(_claudeInitialize));
          unawaited(_answerGetSettings(process));
          return process;
        },
      );
      addTearDown(harness.dispose);

      final catalogue = await harness.discoverModelCatalogue();

      expect(catalogue.defaultId, 'opus[1m]');
      final requests = process.capturedStdinJson;
      expect(requests.map((message) => message['type']), everyElement('control_request'));
      expect(requests.map((message) => (message['request'] as Map)['subtype']), ['initialize', 'get_settings']);
      expect(harness.state, WorkerState.stopped);
      expect(process.killCalled, isTrue);
    });
  });
}

/// Polls the fake's stdin until `get_settings` is written, then answers it.
Future<void> _answerGetSettings(CapturingFakeProcess process) async {
  for (var i = 0; i < 200; i++) {
    final request = process.capturedStdinJson
        .where((message) => (message['request'] as Map?)?['subtype'] == 'get_settings')
        .firstOrNull;
    if (request != null) {
      process.emitStdout(_claudeSettingsOpus.replaceFirst('req_settings_1', request['request_id'] as String));
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

/// The `initialize` control_response claude 2.1.278 sends, trimmed to its
/// `models` rows (other response keys omitted).
const _claudeInitialize =
    r'{"type":"control_response","response":{"subtype":"success","request_id":"req_init_1","response":{"models":['
    r'{"value":"default","resolvedModel":"claude-opus-5[1m]","displayName":"Default (recommended)","description":"Opus 5 with 1M context · Best for everyday, complex tasks","supportsEffort":true,"supportedEffortLevels":["low","medium","high","xhigh","max"],"supportsAdaptiveThinking":true,"supportsFastMode":true,"supportsAutoMode":true},'
    r'{"value":"opus[1m]","resolvedModel":"claude-opus-5[1m]","displayName":"Opus (1M context)","description":"Opus 5 with 1M context · Best for everyday, complex tasks","supportsEffort":true,"supportedEffortLevels":["low","medium","high","xhigh","max"],"supportsAdaptiveThinking":true,"supportsFastMode":true,"supportsAutoMode":true},'
    r'{"value":"claude-fable-5-1[1m]","resolvedModel":"claude-fable-5-1","displayName":"Fable","description":"Fable 5.1 · Most capable for your hardest and longest-running tasks","supportsEffort":true,"supportedEffortLevels":["low","medium","high","xhigh","max"],"supportsAdaptiveThinking":true,"supportsAutoMode":true},'
    r'{"value":"sonnet","resolvedModel":"claude-sonnet-5","displayName":"Sonnet","description":"Sonnet 5 · Efficient for routine tasks","supportsEffort":true,"supportedEffortLevels":["low","medium","high","xhigh","max"],"supportsAdaptiveThinking":true,"supportsAutoMode":true},'
    r'{"value":"haiku","resolvedModel":"claude-haiku-4-5-20251001","displayName":"Haiku","description":"Haiku 4.5 · Fastest for quick answers"}'
    r']}}}';

/// The `get_settings` control_response for a process spawned without `--model`.
const _claudeSettingsOpus =
    r'{"type":"control_response","response":{"subtype":"success","request_id":"req_settings_1","response":{"applied":{"model":"claude-opus-5[1m]","effort":"xhigh","advisor":null,"ultracode":false},"effective":{},"sources":{}}}}';
