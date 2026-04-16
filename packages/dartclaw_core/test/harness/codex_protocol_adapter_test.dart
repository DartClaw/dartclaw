import 'dart:convert';

import 'package:dartclaw_core/src/harness/canonical_tool.dart';
import 'package:dartclaw_core/src/harness/codex_protocol_adapter.dart';
import 'package:dartclaw_core/src/harness/protocol_message.dart';
import 'package:test/test.dart';

Map<String, dynamic> _j(Map<String, dynamic> value) => jsonDecode(jsonEncode(value)) as Map<String, dynamic>;

void main() {
  group('CodexProtocolAdapter.parseLine', () {
    test('parses item/agentMessage/delta into TextDelta', () {
      final adapter = CodexProtocolAdapter();

      final msg = adapter.parseLine(
        jsonEncode({
          'method': 'item/agentMessage/delta',
          'params': {'delta': 'Hello world'},
        }),
      );

      expect(msg, isA<TextDelta>());
      expect((msg! as TextDelta).text, 'Hello world');
    });

    test('parses item/started command_execution into ToolUse with shell mapping', () {
      final adapter = CodexProtocolAdapter();

      final msg = adapter.parseLine(
        jsonEncode({
          'method': 'item/started',
          'params': {
            'item': {'type': 'command_execution', 'id': 'tool-1', 'command': 'ls -la'},
          },
        }),
      );

      expect(msg, isA<ToolUse>());
      final toolUse = msg! as ToolUse;
      expect(toolUse.name, 'shell');
      expect(toolUse.id, 'tool-1');
      expect(toolUse.input, {'command': 'ls -la'});
    });

    test('parses item/started file_change create into ToolUse with file_write mapping', () {
      final adapter = CodexProtocolAdapter();

      final msg = adapter.parseLine(
        jsonEncode({
          'method': 'item/started',
          'params': {
            'item': {'type': 'file_change', 'kind': 'create', 'id': 'file-1', 'path': '/tmp/new.txt'},
          },
        }),
      );

      expect(msg, isA<ToolUse>());
      final toolUse = msg! as ToolUse;
      expect(toolUse.name, 'file_write');
      expect(toolUse.id, 'file-1');
      expect(toolUse.input, {'path': '/tmp/new.txt', 'kind': 'create'});
    });

    test('parses item/started file_change update into ToolUse with file_edit mapping', () {
      final adapter = CodexProtocolAdapter();

      final msg = adapter.parseLine(
        jsonEncode({
          'method': 'item/started',
          'params': {
            'item': {'type': 'file_change', 'kind': 'update', 'id': 'file-2', 'path': '/tmp/existing.txt'},
          },
        }),
      );

      expect(msg, isA<ToolUse>());
      final toolUse = msg! as ToolUse;
      expect(toolUse.name, 'file_edit');
      expect(toolUse.id, 'file-2');
      expect(toolUse.input, {'path': '/tmp/existing.txt', 'kind': 'update'});
    });

    test('parses item/started file_change with unknown kind into conservative file_write ToolUse', () {
      final adapter = CodexProtocolAdapter();

      final msg = adapter.parseLine(
        jsonEncode({
          'method': 'item/started',
          'params': {
            'item': {'type': 'file_change', 'kind': 'rename', 'id': 'file-unknown-kind', 'path': '/tmp/renamed.txt'},
          },
        }),
      );

      expect(msg, isA<ToolUse>());
      final toolUse = msg! as ToolUse;
      expect(toolUse.name, 'file_write');
      expect(toolUse.id, 'file-unknown-kind');
      expect(toolUse.input, {'path': '/tmp/renamed.txt', 'kind': 'rename'});
    });

    test('parses item/started mcp_tool_call into ToolUse with mcp_call mapping', () {
      final adapter = CodexProtocolAdapter();

      final msg = adapter.parseLine(
        jsonEncode({
          'method': 'item/started',
          'params': {
            'item': {
              'type': 'mcp_tool_call',
              'id': 'mcp-1',
              'server': 'filesystem',
              'tool': 'read_file',
              'arguments': {'path': '/tmp/data.json'},
            },
          },
        }),
      );

      expect(msg, isA<ToolUse>());
      final toolUse = msg! as ToolUse;
      expect(toolUse.name, 'mcp_call');
      expect(toolUse.id, 'mcp-1');
      expect(toolUse.input, {
        'server': 'filesystem',
        'tool': 'read_file',
        'arguments': {'path': '/tmp/data.json'},
      });
    });

    test('parses item/started web_search into ToolUse with web_fetch mapping', () {
      final adapter = CodexProtocolAdapter();

      final msg = adapter.parseLine(
        jsonEncode({
          'method': 'item/started',
          'params': {
            'item': {
              'type': 'web_search',
              'id': 'web-1',
              'query': 'dartclaw',
              'filters': ['recent'],
            },
          },
        }),
      );

      expect(msg, isA<ToolUse>());
      final toolUse = msg! as ToolUse;
      expect(toolUse.name, 'web_fetch');
      expect(toolUse.id, 'web-1');
      expect(toolUse.input, {
        'query': 'dartclaw',
        'filters': ['recent'],
      });
    });

    test('parses item/completed command_execution into ToolResult', () {
      final adapter = CodexProtocolAdapter();

      final msg = adapter.parseLine(
        jsonEncode({
          'method': 'item/completed',
          'params': {
            'item': {'type': 'command_execution', 'id': 'tool-3', 'aggregated_output': 'done\n', 'exit_code': 0},
          },
        }),
      );

      expect(msg, isA<ToolResult>());
      final toolResult = msg! as ToolResult;
      expect(toolResult.toolId, 'tool-3');
      expect(toolResult.output, 'done\n');
      expect(toolResult.isError, isFalse);
    });

    test('parses item/completed agent_message into TextDelta', () {
      final adapter = CodexProtocolAdapter();

      final msg = adapter.parseLine(
        jsonEncode({
          'method': 'item/completed',
          'params': {
            'item': {'type': 'agent_message', 'delta': 'final answer'},
          },
        }),
      );

      expect(msg, isA<TextDelta>());
      expect((msg! as TextDelta).text, 'final answer');
    });

    test('parses item/completed web_search into ToolResult', () {
      final adapter = CodexProtocolAdapter();

      final msg = adapter.parseLine(
        jsonEncode({
          'method': 'item/completed',
          'params': {
            'item': {
              'type': 'web_search',
              'id': 'web-2',
              'result': {'title': 'DartClaw'},
            },
          },
        }),
      );

      expect(msg, isA<ToolResult>());
      final toolResult = msg! as ToolResult;
      expect(toolResult.toolId, 'web-2');
      expect(toolResult.output, '{"title":"DartClaw"}');
      expect(toolResult.isError, isFalse);
    });

    test('parses item/completed unknown item type into prefixed ToolResult', () {
      final adapter = CodexProtocolAdapter();

      final msg = adapter.parseLine(
        jsonEncode({
          'method': 'item/completed',
          'params': {
            'item': {'type': 'reasoning', 'id': 'item-unknown', 'summary': 'thinking through the request'},
          },
        }),
      );

      expect(msg, isA<ToolResult>());
      final toolResult = msg! as ToolResult;
      expect(toolResult.toolId, 'item-unknown');
      expect(toolResult.output, 'codex:reasoning {"summary":"thinking through the request"}');
      expect(toolResult.isError, isFalse);
    });

    test('parses item/completed with non-zero exit code as error ToolResult', () {
      final adapter = CodexProtocolAdapter();

      final msg = adapter.parseLine(
        jsonEncode({
          'method': 'item/completed',
          'params': {
            'item': {'type': 'command_execution', 'id': 'tool-4', 'aggregated_output': 'failed\n', 'exit_code': 2},
          },
        }),
      );

      expect(msg, isA<ToolResult>());
      final toolResult = msg! as ToolResult;
      expect(toolResult.toolId, 'tool-4');
      expect(toolResult.output, 'failed\n');
      expect(toolResult.isError, isTrue);
    });

    test('parses turn/completed into TurnComplete with token counts', () {
      final adapter = CodexProtocolAdapter();

      final msg = adapter.parseLine(
        jsonEncode({
          'method': 'turn/completed',
          'params': {
            'usage': {'input_tokens': 12, 'output_tokens': 34},
          },
        }),
      );

      expect(msg, isA<TurnComplete>());
      final complete = msg! as TurnComplete;
      expect(complete.stopReason, 'completed');
      expect(complete.inputTokens, 12);
      expect(complete.outputTokens, 34);
      expect(complete.cacheReadTokens, isNull);
      expect(complete.cacheWriteTokens, 0);
      expect(complete.costUsd, isNull);
    });

    test('parses turn/completed with cached_input_tokens -> cacheReadTokens', () {
      final adapter = CodexProtocolAdapter();

      final msg = adapter.parseLine(
        jsonEncode({
          'method': 'turn/completed',
          'params': {
            'usage': {'input_tokens': 12, 'output_tokens': 34, 'cached_input_tokens': 7},
          },
        }),
      );

      expect(msg, isA<TurnComplete>());
      final complete = msg! as TurnComplete;
      expect(complete.inputTokens, 12);
      expect(complete.outputTokens, 34);
      expect(complete.cacheReadTokens, 7);
      expect(complete.cacheWriteTokens, 0);
    });

    test('parses turn/failed into TurnComplete with error stop reason', () {
      final adapter = CodexProtocolAdapter();

      final msg = adapter.parseLine(
        jsonEncode({
          'method': 'turn/failed',
          'params': {
            'error': {'message': 'boom'},
          },
        }),
      );

      expect(msg, isA<TurnComplete>());
      final complete = msg! as TurnComplete;
      expect(complete.stopReason, 'error');
      expect(complete.costUsd, isNull);
    });

    test('parses initialize response into SystemInit', () {
      final adapter = CodexProtocolAdapter();

      final msg = adapter.parseLine(
        jsonEncode({
          'id': 1,
          'result': {
            'session_id': 'sess-123',
            'capabilities': {'context_window': 8192},
            'tools': [
              {'name': 'shell'},
            ],
          },
        }),
      );

      expect(msg, isA<SystemInit>());
      final init = msg! as SystemInit;
      expect(init.sessionId, 'sess-123');
      expect(init.toolCount, 1);
      expect(init.contextWindow, 8192);
    });

    // Codex v0.118.0 wraps initialize responses in a ClientResponse envelope:
    // result.response.{session_id, capabilities, tools} (PR #15921).
    test('parses v0.118.0 ClientResponse-wrapped initialize response into SystemInit', () {
      final adapter = CodexProtocolAdapter();

      final msg = adapter.parseLine(
        jsonEncode({
          'id': 1,
          'result': {
            'response': {
              'session_id': 'sess-v118',
              'capabilities': {'context_window': 16384},
              'tools': [
                {'name': 'shell'},
                {'name': 'file_change'},
              ],
            },
          },
        }),
      );

      expect(msg, isA<SystemInit>());
      final init = msg! as SystemInit;
      expect(init.sessionId, 'sess-v118');
      expect(init.toolCount, 2);
      expect(init.contextWindow, 16384);
    });

    test('legacy flat-shape and v0.118.0 ClientResponse shape produce identical SystemInit fields', () {
      final adapter = CodexProtocolAdapter();

      final legacyMsg = adapter.parseLine(
        jsonEncode({
          'id': 1,
          'result': {
            'session_id': 'sess-same',
            'capabilities': {'context_window': 8192},
            'tools': [
              {'name': 'shell'},
            ],
          },
        }),
      );

      final v118Msg = adapter.parseLine(
        jsonEncode({
          'id': 1,
          'result': {
            'response': {
              'session_id': 'sess-same',
              'capabilities': {'context_window': 8192},
              'tools': [
                {'name': 'shell'},
              ],
            },
          },
        }),
      );

      expect(legacyMsg, isA<SystemInit>());
      expect(v118Msg, isA<SystemInit>());
      final legacy = legacyMsg! as SystemInit;
      final v118 = v118Msg! as SystemInit;
      expect(v118.sessionId, legacy.sessionId);
      expect(v118.toolCount, legacy.toolCount);
      expect(v118.contextWindow, legacy.contextWindow);
    });

    test('v0.118.0 ClientResponse with missing fields returns null gracefully', () {
      final adapter = CodexProtocolAdapter();

      expect(
        adapter.parseLine(
          jsonEncode({
            'id': 1,
            'result': {'response': {}},
          }),
        ),
        isNull,
      );
    });

    test('returns null for result responses that only contain thread_id', () {
      final adapter = CodexProtocolAdapter();

      expect(
        adapter.parseLine(
          jsonEncode({
            'id': 1,
            'result': {'thread_id': 'thread-1'},
          }),
        ),
        isNull,
      );
    });

    test('parses approval request into ControlRequest', () {
      final adapter = CodexProtocolAdapter();

      final msg = adapter.parseLine(
        jsonEncode({
          'id': 42,
          'method': 'control/approval',
          'params': {'tool_name': 'shell', 'tool_use_id': 'tool-42'},
        }),
      );

      expect(msg, isA<ControlRequest>());
      final request = msg! as ControlRequest;
      expect(request.requestId, '42');
      expect(request.subtype, 'approval');
      expect(request.data['tool_name'], 'shell');
      expect(request.data['tool_use_id'], 'tool-42');
    });

    test('parses approval/request into ControlRequest', () {
      final adapter = CodexProtocolAdapter();

      final msg = adapter.parseLine(
        jsonEncode({
          'jsonrpc': '2.0',
          'id': 'req-77',
          'method': 'approval/request',
          'params': {
            'tool_name': 'command_execution',
            'tool_input': {'command': 'git status'},
          },
        }),
      );

      expect(msg, isA<ControlRequest>());
      final request = msg! as ControlRequest;
      expect(request.requestId, 'req-77');
      expect(request.subtype, 'approval');
      expect(request.data['tool_name'], 'command_execution');
      expect(request.data['tool_input'], {'command': 'git status'});
    });

    test('returns null for turn/started', () {
      final adapter = CodexProtocolAdapter();
      expect(adapter.parseLine(jsonEncode({'method': 'turn/started', 'params': {}})), isNull);
    });

    test('returns null for empty line', () {
      final adapter = CodexProtocolAdapter();
      expect(adapter.parseLine(''), isNull);
    });

    test('returns null for malformed JSON', () {
      final adapter = CodexProtocolAdapter();
      expect(adapter.parseLine('{not json'), isNull);
    });

    group('contextCompaction', () {
      test('parses item/started contextCompaction into CompactionStarted', () {
        final adapter = CodexProtocolAdapter();

        final msg = adapter.parseLine(
          jsonEncode({
            'method': 'item/started',
            'params': {
              'item': {'type': 'contextCompaction', 'id': 'compact-1'},
            },
          }),
        );

        expect(msg, isA<CompactionStarted>());
        expect((msg! as CompactionStarted).id, 'compact-1');
      });

      test('parses item/started contextCompaction without id', () {
        final adapter = CodexProtocolAdapter();

        final msg = adapter.parseLine(
          jsonEncode({
            'method': 'item/started',
            'params': {
              'item': {'type': 'contextCompaction'},
            },
          }),
        );

        expect(msg, isA<CompactionStarted>());
        expect((msg! as CompactionStarted).id, isNull);
      });

      test('parses item/completed contextCompaction into CompactionCompleted', () {
        final adapter = CodexProtocolAdapter();

        final msg = adapter.parseLine(
          jsonEncode({
            'method': 'item/completed',
            'params': {
              'item': {'type': 'contextCompaction', 'id': 'compact-1'},
            },
          }),
        );

        expect(msg, isA<CompactionCompleted>());
        expect((msg! as CompactionCompleted).id, 'compact-1');
      });

      test('parses item/completed contextCompaction without id', () {
        final adapter = CodexProtocolAdapter();

        final msg = adapter.parseLine(
          jsonEncode({
            'method': 'item/completed',
            'params': {
              'item': {'type': 'contextCompaction'},
            },
          }),
        );

        expect(msg, isA<CompactionCompleted>());
        expect((msg! as CompactionCompleted).id, isNull);
      });

      test('contextCompaction is not a ToolUse or ToolResult', () {
        final adapter = CodexProtocolAdapter();

        final started = adapter.parseLine(
          jsonEncode({
            'method': 'item/started',
            'params': {
              'item': {'type': 'contextCompaction', 'id': 'c-1'},
            },
          }),
        );
        final completed = adapter.parseLine(
          jsonEncode({
            'method': 'item/completed',
            'params': {
              'item': {'type': 'contextCompaction', 'id': 'c-1'},
            },
          }),
        );

        expect(started, isNot(isA<ToolUse>()));
        expect(started, isNot(isA<ToolResult>()));
        expect(completed, isNot(isA<ToolUse>()));
        expect(completed, isNot(isA<ToolResult>()));
      });

      test('contextCompaction with extra unknown fields is still recognized (forward compat)', () {
        final adapter = CodexProtocolAdapter();

        final msg = adapter.parseLine(
          jsonEncode({
            'method': 'item/started',
            'params': {
              'item': {'type': 'contextCompaction', 'id': 'c-2', 'future_field': 'ignored'},
            },
          }),
        );

        expect(msg, isA<CompactionStarted>());
      });

      test('unknown item types still produce codex:-prefixed ToolUse (regression guard)', () {
        final adapter = CodexProtocolAdapter();

        final msg = adapter.parseLine(
          jsonEncode({
            'method': 'item/started',
            'params': {
              'item': {'type': 'future_unknown_type', 'id': 'x-1'},
            },
          }),
        );

        expect(msg, isA<ToolUse>());
        expect((msg! as ToolUse).name, startsWith('codex:'));
      });

      test('unknown item/completed types still produce codex:-prefixed ToolResult (regression guard)', () {
        final adapter = CodexProtocolAdapter();

        final msg = adapter.parseLine(
          jsonEncode({
            'method': 'item/completed',
            'params': {
              'item': {'type': 'future_unknown_type', 'id': 'x-2'},
            },
          }),
        );

        expect(msg, isA<ToolResult>());
        expect((msg! as ToolResult).output, contains('codex:future_unknown_type'));
      });
    });

    group('thread/compactedNotification', () {
      test('returns null for thread/compactedNotification (explicit no-op)', () {
        final adapter = CodexProtocolAdapter();

        final msg = adapter.parseLine(
          jsonEncode({
            'method': 'thread/compactedNotification',
            'params': {'thread_id': 'thread-1'},
          }),
        );

        expect(msg, isNull);
      });

      test('thread/compactedNotification does not produce ToolUse or ToolResult', () {
        final adapter = CodexProtocolAdapter();

        final msg = adapter.parseLine(jsonEncode({'method': 'thread/compactedNotification', 'params': {}}));

        expect(msg, isNot(isA<ToolUse>()));
        expect(msg, isNot(isA<ToolResult>()));
      });
    });
  });

  group('CodexProtocolAdapter.buildTurnRequest', () {
    test('builds turn/start payload with user content', () {
      final adapter = CodexProtocolAdapter();
      expect(
        adapter.buildTurnRequest(message: 'Hello'),
        _j({
          'method': 'turn/start',
          'params': {
            'input': [
              {'type': 'text', 'text': 'Hello'},
            ],
          },
        }),
      );
    });

    test('includes threadId and resume flags while ignoring systemPrompt', () {
      final adapter = CodexProtocolAdapter();
      final payload = adapter.buildTurnRequest(
        message: 'Hello',
        systemPrompt: 'Be concise',
        threadId: 'thread-123',
        resume: true,
      );

      expect(payload['method'], 'turn/start');
      expect(payload['params'], isA<Map<String, dynamic>>());
      expect((payload['params'] as Map<String, dynamic>)['input'], [
        {'type': 'text', 'text': 'Hello'},
      ]);
      expect(payload['params']?['threadId'], 'thread-123');
      expect(payload['params']?['system_prompt'], isNull);
      expect(payload['params']?['resume'], isTrue);
    });

    test('includes previousResponseItems and dynamic settings', () {
      final dynamic adapter = CodexProtocolAdapter();
      final payload =
          adapter.buildTurnRequest(
                message: 'Hello',
                threadId: 'thread-123',
                history: [
                  {'role': 'human', 'content': 'Earlier question'},
                  {'role': 'assistant', 'content': 'Earlier answer'},
                ],
                settings: {
                  'model': 'gpt-5',
                  'cwd': '/tmp/workspace',
                  'sandbox': 'workspaceWrite',
                  'approval_policy': 'on-request',
                },
              )
              as Map<String, dynamic>;

      final params = payload['params'] as Map<String, dynamic>;
      expect(params['threadId'], 'thread-123');
      expect(params['input'], [
        {'type': 'text', 'text': 'Hello'},
      ]);
      expect(params['previousResponseItems'], [
        {
          'type': 'message',
          'role': 'user',
          'content': [
            {'type': 'input_text', 'text': 'Earlier question'},
          ],
        },
        {
          'type': 'message',
          'role': 'assistant',
          'content': [
            {'type': 'output_text', 'text': 'Earlier answer'},
          ],
        },
      ]);
      expect(params['model'], 'gpt-5');
      expect(params['cwd'], '/tmp/workspace');
      expect(params['sandboxPolicy'], {'type': 'workspaceWrite'});
      expect(params['approvalPolicy'], 'on-request');
    });
  });

  group('CodexProtocolAdapter.buildApprovalResponse', () {
    test('builds approved response', () {
      final adapter = CodexProtocolAdapter();
      expect(adapter.buildApprovalResponse('req-1', allow: true), {
        'jsonrpc': '2.0',
        'id': 'req-1',
        'result': {'approved': true},
      });
    });

    test('builds denied response', () {
      final adapter = CodexProtocolAdapter();
      expect(adapter.buildApprovalResponse('req-2', allow: false), {
        'jsonrpc': '2.0',
        'id': 'req-2',
        'result': {'approved': false},
      });
    });

    test('builds denied response with reason', () {
      final adapter = CodexProtocolAdapter();
      expect(adapter.buildApprovalResponse('req-3', allow: false, reason: 'Blocked by FileGuard'), {
        'jsonrpc': '2.0',
        'id': 'req-3',
        'result': {'approved': false, 'reason': 'Blocked by FileGuard'},
      });
    });
  });

  group('CodexProtocolAdapter initialization helpers', () {
    test('builds initialize request with default params', () {
      final adapter = CodexProtocolAdapter();

      expect(adapter.buildInitializeRequest(id: 1), {
        'id': 1,
        'method': 'initialize',
        'params': {
          'clientInfo': {'name': 'dartclaw', 'version': '0.9.0'},
        },
      });
    });

    test('builds initialized notification with custom params', () {
      final adapter = CodexProtocolAdapter();

      expect(adapter.buildInitializedNotification(params: {'session_id': 'sess-123'}), {
        'method': 'initialized',
        'params': {'session_id': 'sess-123'},
      });
    });

    test('builds thread/start request', () {
      final adapter = CodexProtocolAdapter();

      expect(adapter.buildThreadStartRequest(id: 'thread-1', params: {'session_id': 'sess-123'}), {
        'id': 'thread-1',
        'method': 'thread/start',
        'params': {'session_id': 'sess-123'},
      });
    });
  });

  group('CodexProtocolAdapter.mapToolName', () {
    test('maps command_execution to shell', () {
      final adapter = CodexProtocolAdapter();
      expect(adapter.mapToolName('command_execution'), CanonicalTool.shell);
    });

    test('maps file_change create to file_write', () {
      final adapter = CodexProtocolAdapter();
      expect(adapter.mapToolName('file_change', kind: 'create'), CanonicalTool.fileWrite);
    });

    test('maps file_change update to file_edit', () {
      final adapter = CodexProtocolAdapter();
      expect(adapter.mapToolName('file_change', kind: 'update'), CanonicalTool.fileEdit);
    });

    test('maps file_change unknown kind to file_write for fail-closed guard evaluation', () {
      final adapter = CodexProtocolAdapter();
      expect(adapter.mapToolName('file_change', kind: 'rename'), CanonicalTool.fileWrite);
    });

    test('maps mcp_tool_call to mcp_call', () {
      final adapter = CodexProtocolAdapter();
      expect(adapter.mapToolName('mcp_tool_call'), CanonicalTool.mcpCall);
    });

    test('maps web_search to web_fetch', () {
      final adapter = CodexProtocolAdapter();
      expect(adapter.mapToolName('web_search'), CanonicalTool.webFetch);
    });

    test('returns null for unknown and edge-case tool names', () {
      final adapter = CodexProtocolAdapter();
      expect(adapter.mapToolName('unknown_tool'), isNull);
      expect(adapter.mapToolName('reasoning'), isNull);
      expect(adapter.mapToolName('todo_list'), isNull);
      expect(adapter.mapToolName('error'), isNull);
    });
  });
}
