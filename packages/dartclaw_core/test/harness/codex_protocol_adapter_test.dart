import 'dart:convert';

import 'package:dartclaw_core/src/harness/codex_protocol_adapter.dart';
import 'package:dartclaw_core/src/harness/protocol_message.dart';
import 'package:test/test.dart';

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

    test('parses item/started web_search into ToolUse with web_search mapping', () {
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
      expect(toolUse.name, 'web_search');
      expect(toolUse.id, 'web-1');
      expect(toolUse.input, {
        'query': 'dartclaw',
        'filters': ['recent'],
      });
    });

    test('parses current camelCase tool item types', () {
      final adapter = CodexProtocolAdapter();

      final command = adapter.parseLine(
        jsonEncode({
          'method': 'item/started',
          'params': {
            'item': {'type': 'commandExecution', 'id': 'command-current', 'command': 'git status'},
          },
        }),
      );
      final file = adapter.parseLine(
        jsonEncode({
          'method': 'item/started',
          'params': {
            'item': {
              'type': 'fileChange',
              'id': 'file-current',
              'changes': [
                {
                  'kind': {'type': 'update'},
                  'path': '/tmp/existing.txt',
                },
              ],
            },
          },
        }),
      );
      final mcp = adapter.parseLine(
        jsonEncode({
          'method': 'item/started',
          'params': {
            'item': {
              'type': 'mcpToolCall',
              'id': 'mcp-current',
              'server': 'dartclaw',
              'tool': 'memory_apply',
              'arguments': {'content': 'fact'},
            },
          },
        }),
      );
      final web = adapter.parseLine(
        jsonEncode({
          'method': 'item/started',
          'params': {
            'item': {'type': 'webSearch', 'id': 'web-current', 'query': 'dartclaw'},
          },
        }),
      );

      expect(command, isA<ToolUse>().having((message) => message.name, 'name', 'shell'));
      expect(file, isA<ToolUse>().having((message) => message.name, 'name', 'file_edit'));
      expect(mcp, isA<ToolUse>().having((message) => message.name, 'name', 'mcp_call'));
      expect(web, isA<ToolUse>().having((message) => message.name, 'name', 'web_search'));
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

    test('parses item/completed reasoning into provider progress', () {
      final adapter = CodexProtocolAdapter();

      final msg = adapter.parseLine(
        jsonEncode({
          'method': 'item/completed',
          'params': {
            'item': {'type': 'reasoning', 'id': 'item-unknown', 'summary': 'thinking through the request'},
          },
        }),
      );

      expect(msg, isA<ProgressMessage>());
      final progress = msg! as ProgressMessage;
      expect(progress.kind, 'codex_reasoning');
      expect(progress.text, 'thinking through the request');
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

    test('parses current camelCase command result fields', () {
      final adapter = CodexProtocolAdapter();

      final msg = adapter.parseLine(
        jsonEncode({
          'method': 'item/completed',
          'params': {
            'item': {
              'type': 'commandExecution',
              'id': 'command-current',
              'aggregatedOutput': 'failed\n',
              'exitCode': 2,
            },
          },
        }),
      );

      expect(msg, isA<ToolResult>());
      final result = msg! as ToolResult;
      expect(result.output, 'failed\n');
      expect(result.isError, isTrue);
    });

    test('does not report current message items as unknown tools', () {
      final adapter = CodexProtocolAdapter();

      for (final type in ['userMessage', 'agentMessage']) {
        expect(
          adapter.parseLine(
            jsonEncode({
              'method': 'item/started',
              'params': {
                'item': {'type': type, 'id': '$type-started'},
              },
            }),
          ),
          isNull,
        );
        expect(
          adapter.parseLine(
            jsonEncode({
              'method': 'item/completed',
              'params': {
                'item': {'type': type, 'id': '$type-completed', 'text': 'message'},
              },
            }),
          ),
          isNull,
        );
      }
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
      // OpenAI reports input_tokens as total (incl. cached); we normalize to the
      // Anthropic convention where inputTokens is fresh-only: 12 - 7 = 5.
      expect(complete.inputTokens, 5);
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

    test('parses current command execution approval request', () {
      final adapter = CodexProtocolAdapter();

      final msg = adapter.parseLine(
        jsonEncode({
          'id': 'req-command',
          'method': 'item/commandExecution/requestApproval',
          'params': {
            'itemId': 'command-1',
            'command': 'git status',
            'cwd': '/tmp/workspace',
            'reason': 'Inspect the checkout',
          },
        }),
      );

      expect(msg, isA<ControlRequest>());
      final request = msg! as ControlRequest;
      expect(request.data['tool_name'], 'command_execution');
      expect(request.data['tool_use_id'], 'command-1');
      expect(request.data['tool_input'], {
        'command': 'git status',
        'cwd': '/tmp/workspace',
        'reason': 'Inspect the checkout',
      });
    });

    test('parses current file change approval with the started item context', () {
      final adapter = CodexProtocolAdapter();
      adapter.parseLine(
        jsonEncode({
          'method': 'item/started',
          'params': {
            'item': {
              'type': 'fileChange',
              'id': 'file-1',
              'changes': [
                {'kind': 'update', 'path': '/tmp/existing.txt'},
              ],
            },
          },
        }),
      );

      final msg = adapter.parseLine(
        jsonEncode({
          'id': 'req-file',
          'method': 'item/fileChange/requestApproval',
          'params': {'itemId': 'file-1', 'reason': 'Update the fixture'},
        }),
      );

      expect(msg, isA<ControlRequest>());
      final request = msg! as ControlRequest;
      expect(request.data['tool_name'], 'file_change');
      expect(request.data['tool_use_id'], 'file-1');
      expect(request.data['tool_input'], {
        'id': 'file-1',
        'changes': [
          {'kind': 'update', 'path': '/tmp/existing.txt'},
        ],
        'reason': 'Update the fixture',
      });
    });

    test('parses current MCP tool approval elicitation', () {
      final adapter = CodexProtocolAdapter();

      final msg = adapter.parseLine(
        jsonEncode({
          'id': 'req-mcp',
          'method': 'mcpServer/elicitation/request',
          'params': {
            'threadId': 'thread-1',
            'turnId': 'turn-1',
            'serverName': 'dartclaw',
            'mode': 'form',
            '_meta': {
              'codex_approval_kind': 'mcp_tool_call',
              'tool_name': 'memory_apply',
              'tool_params': {'content': 'fact'},
            },
            'message': 'Allow memory write?',
            'requestedSchema': {'type': 'object', 'properties': <String, dynamic>{}},
          },
        }),
      );

      expect(msg, isA<ControlRequest>());
      final request = msg! as ControlRequest;
      expect(request.data['tool_name'], 'mcp_tool_call');
      expect(request.data['tool_use_id'], 'req-mcp');
      expect(request.data['tool_input'], {
        'server': 'dartclaw',
        'tool': 'memory_apply',
        'arguments': {'content': 'fact'},
      });
    });

    test('uses the MCP approval request identity instead of cached started items', () {
      final adapter = CodexProtocolAdapter();
      adapter.parseLine(
        jsonEncode({
          'method': 'item/started',
          'params': {
            'item': {
              'type': 'mcpToolCall',
              'id': 'mcp-started',
              'server': 'dartclaw',
              'tool': 'memory_apply',
              'arguments': {'content': 'fact'},
            },
          },
        }),
      );

      final msg = adapter.parseLine(
        jsonEncode({
          'id': 8,
          'method': 'mcpServer/elicitation/request',
          'params': {
            'serverName': 'external-memory',
            'mode': 'form',
            '_meta': {
              'codex_approval_kind': 'mcp_tool_call',
              'tool_name': 'memory_apply',
              'tool_params': {'content': 'fact'},
            },
            'message': 'Allow?',
            'requestedSchema': {'type': 'object'},
          },
        }),
      );

      expect((msg! as ControlRequest).data['tool_input'], {
        'server': 'external-memory',
        'tool': 'memory_apply',
        'arguments': {'content': 'fact'},
      });
    });

    test('routes non-approval MCP elicitations for an immediate native response', () {
      final adapter = CodexProtocolAdapter();

      final message = adapter.parseLine(
        jsonEncode({
          'id': 'req-mcp-form',
          'method': 'mcpServer/elicitation/request',
          'params': {
            'serverName': 'forms',
            'mode': 'form',
            '_meta': {'source': 'form'},
            'message': 'Enter a value',
            'requestedSchema': {'type': 'object'},
          },
        }),
      );

      expect(
        message,
        isA<ControlRequest>()
            .having((request) => request.requestId, 'requestId', 'req-mcp-form')
            .having((request) => request.subtype, 'subtype', 'unsupported_elicitation'),
      );
    });

    test('returns null for turn/started', () {
      final adapter = CodexProtocolAdapter();
      expect(adapter.parseLine(jsonEncode({'method': 'turn/started', 'params': {}})), isNull);
    });

    test('ignores unknown notifications without blocking turn completion', () {
      final adapter = CodexProtocolAdapter();
      const methods = [
        'thread/started',
        'thread/status/changed',
        'thread/tokenUsage/updated',
        'account/rateLimits/updated',
      ];

      for (final method in methods) {
        expect(adapter.parseLine(jsonEncode({'method': method, 'params': {}})), isNull, reason: method);
      }
      expect(
        adapter.parseLine(
          jsonEncode({
            'method': 'turn/completed',
            'params': {'usage': {}},
          }),
        ),
        isA<TurnComplete>().having((message) => message.stopReason, 'stopReason', 'completed'),
      );
    });

    test('parses only the project-trust config warning as provider setup progress', () {
      final adapter = CodexProtocolAdapter();
      final warning = adapter.parseLine(
        jsonEncode({
          'method': 'configWarning',
          'params': {
            'summary': 'Project-local config, hooks, and exec policies are disabled until the project is trusted.',
            'details': r'C:\workspace\.codex',
          },
        }),
      );
      final unrelated = adapter.parseLine(
        jsonEncode({
          'method': 'configWarning',
          'params': {'summary': 'Unknown config key.'},
        }),
      );

      expect(
        warning,
        isA<ProgressMessage>()
            .having((message) => message.kind, 'kind', 'provider_setup_warning')
            .having((message) => message.text, 'text', contains('Project-local config'))
            .having((message) => message.text, 'text', contains(r'C:\workspace\.codex')),
      );
      expect(unrelated, isA<ProtocolDiagnostic>());
    });

    test('reports failed MCP startup while ignoring non-warning status noise', () {
      final adapter = CodexProtocolAdapter();
      final failed = adapter.parseLine(
        jsonEncode({
          'method': 'mcpServer/startupStatus/updated',
          'params': {'name': 'node_repl', 'status': 'failed', 'error': 'initialize response closed'},
        }),
      );

      expect(
        failed,
        isA<ProtocolDiagnostic>()
            .having((message) => message.method, 'method', 'mcpServer/startupStatus/updated')
            .having((message) => message.updateType, 'updateType', 'failed')
            .having((message) => message.message, 'message', contains('initialize response closed')),
      );
      for (final status in ['starting', 'ready', 'cancelled']) {
        expect(
          adapter.parseLine(
            jsonEncode({
              'method': 'mcpServer/startupStatus/updated',
              'params': {'name': 'node_repl', 'status': status, 'error': null},
            }),
          ),
          isNull,
          reason: status,
        );
      }
    });

    test('treats a completed notification with failed turn status as an error', () {
      final adapter = CodexProtocolAdapter();
      final message = adapter.parseLine(
        jsonEncode({
          'method': 'turn/completed',
          'params': {
            'turn': {
              'status': 'failed',
              'error': {'message': 'authentication required'},
            },
          },
        }),
      );

      expect(message, isA<TurnComplete>().having((message) => message.stopReason, 'stopReason', 'error'));
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

    test('builds current command approval decisions', () {
      final adapter = CodexProtocolAdapter();
      adapter.parseLine(
        jsonEncode({
          'id': 'req-current-allow',
          'method': 'item/commandExecution/requestApproval',
          'params': {'itemId': 'command-1'},
        }),
      );
      adapter.parseLine(
        jsonEncode({
          'id': 'req-current-deny',
          'method': 'item/commandExecution/requestApproval',
          'params': {'itemId': 'command-2'},
        }),
      );

      expect(adapter.buildApprovalResponse('req-current-allow', allow: true), {
        'jsonrpc': '2.0',
        'id': 'req-current-allow',
        'result': {'decision': 'accept'},
      });
      expect(adapter.buildApprovalResponse('req-current-deny', allow: false, reason: 'blocked'), {
        'jsonrpc': '2.0',
        'id': 'req-current-deny',
        'result': {'decision': 'decline'},
      });
    });

    test('preserves numeric request IDs in current approval responses', () {
      final adapter = CodexProtocolAdapter();
      adapter.parseLine(
        jsonEncode({
          'id': 7,
          'method': 'item/commandExecution/requestApproval',
          'params': {'itemId': 'command-7'},
        }),
      );

      expect(adapter.buildApprovalResponse('7', allow: true), {
        'jsonrpc': '2.0',
        'id': 7,
        'result': {'decision': 'accept'},
      });
    });

    test('keeps concurrent numeric and string request IDs distinct', () {
      final adapter = CodexProtocolAdapter();
      final numeric =
          adapter.parseLine(
                jsonEncode({
                  'id': 7,
                  'method': 'item/commandExecution/requestApproval',
                  'params': {'itemId': 'command-7'},
                }),
              )!
              as ControlRequest;
      final string =
          adapter.parseLine(
                jsonEncode({
                  'id': '7',
                  'method': 'mcpServer/elicitation/request',
                  'params': {
                    'serverName': 'dartclaw',
                    '_meta': {'codex_approval_kind': 'mcp_tool_call', 'tool_name': 'memory_apply'},
                  },
                }),
              )!
              as ControlRequest;

      expect(numeric.requestId, '7');
      expect(string.requestId, '7#1');
      expect(adapter.buildApprovalResponse(numeric.requestId, allow: false), {
        'jsonrpc': '2.0',
        'id': 7,
        'result': {'decision': 'decline'},
      });
      expect(adapter.buildApprovalResponse(string.requestId, allow: true), {
        'jsonrpc': '2.0',
        'id': '7',
        'result': {'action': 'accept', 'content': null, '_meta': null},
      });
    });

    test('builds an empty permission grant for unsupported permission requests', () {
      final adapter = CodexProtocolAdapter();
      final request = adapter.parseLine(
        jsonEncode({
          'id': 'permission-1',
          'method': 'item/permissions/requestApproval',
          'params': {
            'threadId': 'thread-1',
            'turnId': 'turn-1',
            'itemId': 'item-1',
            'startedAtMs': 1,
            'cwd': '/tmp',
            'permissions': <String, dynamic>{},
          },
        }),
      );

      expect(
        request,
        isA<ControlRequest>().having((request) => request.subtype, 'subtype', 'unsupported_permission_request'),
      );
      expect(adapter.buildApprovalResponse('permission-1', allow: false), {
        'jsonrpc': '2.0',
        'id': 'permission-1',
        'result': {'permissions': <String, dynamic>{}},
      });
    });

    test('builds current MCP elicitation approval actions', () {
      final adapter = CodexProtocolAdapter();
      for (final requestId in ['req-mcp-allow', 'req-mcp-deny']) {
        adapter.parseLine(
          jsonEncode({
            'id': requestId,
            'method': 'mcpServer/elicitation/request',
            'params': {
              'serverName': 'dartclaw',
              'mode': 'form',
              '_meta': {'codex_approval_kind': 'mcp_tool_call', 'tool_name': 'memory_apply'},
              'message': 'Allow?',
              'requestedSchema': {'type': 'object'},
            },
          }),
        );
      }

      expect(adapter.buildApprovalResponse('req-mcp-allow', allow: true), {
        'jsonrpc': '2.0',
        'id': 'req-mcp-allow',
        'result': {'action': 'accept', 'content': null, '_meta': null},
      });
      expect(adapter.buildApprovalResponse('req-mcp-deny', allow: false, reason: 'blocked'), {
        'jsonrpc': '2.0',
        'id': 'req-mcp-deny',
        'result': {'action': 'decline', 'content': null, '_meta': null},
      });
    });
  });
}
