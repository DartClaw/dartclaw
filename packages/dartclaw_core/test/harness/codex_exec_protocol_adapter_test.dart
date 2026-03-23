import 'dart:convert';

import 'package:dartclaw_core/src/harness/codex_exec_protocol_adapter.dart';
import 'package:dartclaw_core/src/harness/protocol_message.dart';
import 'package:test/test.dart';

String _j(Map<String, dynamic> value) => jsonEncode(value);

void main() {
  group('CodexExecProtocolAdapter.parseLine', () {
    test('ignores thread.started', () {
      final adapter = CodexExecProtocolAdapter();

      expect(
        adapter.parseLine(
          _j({
            'type': 'thread.started',
            'thread': {'id': 'thread-1'},
          }),
        ),
        isNull,
      );
    });

    test('ignores turn.started', () {
      final adapter = CodexExecProtocolAdapter();

      expect(
        adapter.parseLine(
          _j({
            'type': 'turn.started',
            'turn': {'id': 'turn-1'},
          }),
        ),
        isNull,
      );
    });

    test('parses item.started command_execution into ToolUse', () {
      final adapter = CodexExecProtocolAdapter();

      final message = adapter.parseLine(
        _j({
          'type': 'item.started',
          'item': {'id': 'tool-1', 'type': 'command_execution', 'command': 'ls -la'},
        }),
      );

      expect(message, isA<ToolUse>());
      final toolUse = message! as ToolUse;
      expect(toolUse.id, 'tool-1');
      expect(toolUse.name, 'shell');
      expect(toolUse.input, {'command': 'ls -la'});
    });

    test('parses item.started file_change update into file_edit ToolUse', () {
      final adapter = CodexExecProtocolAdapter();

      final message = adapter.parseLine(
        _j({
          'type': 'item.started',
          'item': {'id': 'tool-2', 'type': 'file_change', 'path': '/tmp/output.txt', 'kind': 'update'},
        }),
      );

      expect(message, isA<ToolUse>());
      final toolUse = message! as ToolUse;
      expect(toolUse.id, 'tool-2');
      expect(toolUse.name, 'file_edit');
      expect(toolUse.input, {'path': '/tmp/output.txt', 'kind': 'update'});
    });

    test('parses item.started mcp_tool_call into ToolUse', () {
      final adapter = CodexExecProtocolAdapter();

      final message = adapter.parseLine(
        _j({
          'type': 'item.started',
          'item': {
            'id': 'tool-3',
            'type': 'mcp_tool_call',
            'server': 'filesystem',
            'tool': 'read_file',
            'arguments': {'path': '/tmp/data.json'},
          },
        }),
      );

      expect(message, isA<ToolUse>());
      final toolUse = message! as ToolUse;
      expect(toolUse.id, 'tool-3');
      expect(toolUse.name, 'mcp_call');
      expect(toolUse.input, {
        'server': 'filesystem',
        'tool': 'read_file',
        'arguments': {'path': '/tmp/data.json'},
      });
    });

    test('parses item.completed agent_message into TextDelta', () {
      final adapter = CodexExecProtocolAdapter();

      final message = adapter.parseLine(
        _j({
          'type': 'item.completed',
          'item': {'id': 'msg-1', 'type': 'agent_message', 'text': 'final answer'},
        }),
      );

      expect(message, isA<TextDelta>());
      expect((message! as TextDelta).text, 'final answer');
    });

    test('parses item.completed command_execution into ToolResult', () {
      final adapter = CodexExecProtocolAdapter();

      final message = adapter.parseLine(
        _j({
          'type': 'item.completed',
          'item': {'id': 'tool-4', 'type': 'command_execution', 'aggregated_output': 'done\n', 'exit_code': 0},
        }),
      );

      expect(message, isA<ToolResult>());
      final toolResult = message! as ToolResult;
      expect(toolResult.toolId, 'tool-4');
      expect(toolResult.output, 'done\n');
      expect(toolResult.isError, isFalse);
    });

    test('parses item.completed file_change into ToolResult', () {
      final adapter = CodexExecProtocolAdapter();

      final message = adapter.parseLine(
        _j({
          'type': 'item.completed',
          'item': {
            'id': 'tool-5',
            'type': 'file_change',
            'changes': [
              {'path': '/tmp/data.txt', 'kind': 'update'},
            ],
          },
        }),
      );

      expect(message, isA<ToolResult>());
      final toolResult = message! as ToolResult;
      expect(toolResult.toolId, 'tool-5');
      expect(toolResult.output, '[{"path":"/tmp/data.txt","kind":"update"}]');
      expect(toolResult.isError, isFalse);
    });

    test('parses item.completed mcp_tool_call into ToolResult', () {
      final adapter = CodexExecProtocolAdapter();

      final message = adapter.parseLine(
        _j({
          'type': 'item.completed',
          'item': {
            'id': 'tool-6',
            'type': 'mcp_tool_call',
            'result': {'ok': true},
          },
        }),
      );

      expect(message, isA<ToolResult>());
      final toolResult = message! as ToolResult;
      expect(toolResult.toolId, 'tool-6');
      expect(toolResult.output, '{"ok":true}');
      expect(toolResult.isError, isFalse);
    });

    test('parses item.completed command_execution exit code into error ToolResult', () {
      final adapter = CodexExecProtocolAdapter();

      final message = adapter.parseLine(
        _j({
          'type': 'item.completed',
          'item': {'id': 'tool-7', 'type': 'command_execution', 'aggregated_output': 'boom\n', 'exit_code': 2},
        }),
      );

      expect(message, isA<ToolResult>());
      final toolResult = message! as ToolResult;
      expect(toolResult.toolId, 'tool-7');
      expect(toolResult.output, 'boom\n');
      expect(toolResult.isError, isTrue);
    });

    test('parses turn.completed into TurnComplete with usage', () {
      final adapter = CodexExecProtocolAdapter();

      final message = adapter.parseLine(
        _j({
          'type': 'turn.completed',
          'usage': {'input_tokens': 12, 'output_tokens': 34, 'cached_input_tokens': 7},
        }),
      );

      expect(message, isA<TurnComplete>());
      final turnComplete = message! as TurnComplete;
      expect(turnComplete.stopReason, 'end_turn');
      expect(turnComplete.inputTokens, 12);
      expect(turnComplete.outputTokens, 34);
      expect(turnComplete.cachedInputTokens, 7);
    });

    test('returns null for malformed JSON', () {
      final adapter = CodexExecProtocolAdapter();
      expect(adapter.parseLine('{not json'), isNull);
    });

    test('returns null for empty line', () {
      final adapter = CodexExecProtocolAdapter();
      expect(adapter.parseLine('   '), isNull);
    });
  });

  group('CodexExecProtocolAdapter.buildTurnRequest', () {
    test('returns an empty map', () {
      final adapter = CodexExecProtocolAdapter();
      expect(adapter.buildTurnRequest(message: 'hello'), isEmpty);
    });
  });

  group('CodexExecProtocolAdapter.buildApprovalResponse', () {
    test('returns an empty map', () {
      final adapter = CodexExecProtocolAdapter();
      expect(adapter.buildApprovalResponse('req-1', allow: true), isEmpty);
    });
  });

  group('CodexExecProtocolAdapter.mapToolName', () {
    test('maps command_execution to shell', () {
      final adapter = CodexExecProtocolAdapter();
      expect(adapter.mapToolName('command_execution')?.stableName, 'shell');
    });

    test('maps file_change create to file_write', () {
      final adapter = CodexExecProtocolAdapter();
      expect(adapter.mapToolName('file_change', kind: 'create')?.stableName, 'file_write');
    });

    test('maps file_change update to file_edit', () {
      final adapter = CodexExecProtocolAdapter();
      expect(adapter.mapToolName('file_change', kind: 'update')?.stableName, 'file_edit');
    });

    test('maps file_change unknown kind to file_write', () {
      final adapter = CodexExecProtocolAdapter();
      expect(adapter.mapToolName('file_change', kind: 'rename')?.stableName, 'file_write');
    });

    test('maps mcp_tool_call to mcp_call', () {
      final adapter = CodexExecProtocolAdapter();
      expect(adapter.mapToolName('mcp_tool_call')?.stableName, 'mcp_call');
    });

    test('returns null for unknown tool names', () {
      final adapter = CodexExecProtocolAdapter();
      expect(adapter.mapToolName('unknown_tool'), isNull);
    });
  });
}
