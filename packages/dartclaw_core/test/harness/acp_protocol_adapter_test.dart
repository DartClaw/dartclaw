import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_core/src/harness/protocol_message.dart' as protocol;
import 'package:test/test.dart';

void main() {
  group('ACP protocol adapter S04 session/update mapping', () {
    final adapter = AcpProtocolAdapter();

    test('agent_message_chunk maps to assistant TextDelta while agent_thought_chunk stays progress metadata', () {
      final messages = [
        ...adapter.messagesForSessionUpdate({'type': 'agent_message_chunk', 'text': 'visible '}),
        ...adapter.messagesForSessionUpdate({'type': 'agent_thought_chunk', 'text': 'hidden thought'}),
      ];

      expect(messages, [
        isA<TextDelta>().having((message) => message.text, 'text', 'visible '),
        isA<ProgressMessage>()
            .having((message) => message.kind, 'kind', 'agent_thought_chunk')
            .having((message) => message.text, 'text', 'hidden thought'),
      ]);
    });

    test('user_message_chunk maps to progress metadata instead of assistant response text', () {
      final messages = adapter.messagesForSessionUpdate({'type': 'user_message_chunk', 'text': 'quoted user text'});

      expect(messages, [
        isA<ProgressMessage>()
            .having((message) => message.kind, 'kind', 'user_message_chunk')
            .having((message) => message.text, 'text', 'quoted user text'),
      ]);
    });

    test('session_info_update plus usage and context updates produce metadata messages', () {
      final session = adapter.messagesForSessionUpdate({
        'type': 'session_info_update',
        'title': 'Plan cleanup',
        'model': 'goose-model',
      });
      final usage = adapter.messagesForSessionUpdate({'type': 'usage_update', 'input_tokens': 7, 'output_tokens': 11});

      expect(session.single, isA<SessionMetadataUpdate>().having((message) => message.title, 'title', 'Plan cleanup'));
      expect(
        usage.single,
        isA<SessionMetadataUpdate>()
            .having((message) => message.metadata['input_tokens'], 'input tokens', 7)
            .having((message) => message.metadata['output_tokens'], 'output tokens', 11),
      );
    });

    test('tool-1 case produces ToolUse and ToolResult without host reverse-call execution names', () {
      final messages = [
        ...adapter.messagesForSessionUpdate({
          'type': 'tool_call',
          'id': 'tool-1',
          'title': 'Read config',
          'progress': 0.5,
          'input': {'path': 'dartclaw.yaml'},
        }),
        ...adapter.messagesForSessionUpdate({
          'type': 'tool_result',
          'id': 'tool-1',
          'output': 'ok',
          'status': 'completed',
        }),
      ];

      expect(messages, [
        isA<ToolUse>()
            .having((message) => message.id, 'id', 'tool-1')
            .having((message) => message.name, 'name', 'Read config')
            .having((message) => message.input['progress'], 'progress', 0.5),
        isA<protocol.ToolResult>()
            .having((message) => message.toolId, 'toolId', 'tool-1')
            .having((message) => message.output, 'output', 'ok')
            .having((message) => message.isError, 'isError', isFalse),
      ]);
      expect(
        messages.whereType<ToolUse>().single.name,
        isNot(anyOf('fs/read_text_file', 'fs/write_text_file', 'terminal/create')),
      );
    });

    test('tool_call_update progress for tool-1 does not create duplicate ToolUse starts', () {
      final messages = [
        ...adapter.messagesForSessionUpdate({'type': 'tool_call', 'id': 'tool-1', 'title': 'Read config'}),
        ...adapter.messagesForSessionUpdate({
          'type': 'tool_call_update',
          'id': 'tool-1',
          'title': 'Read config',
          'progress': 0.5,
        }),
        ...adapter.messagesForSessionUpdate({
          'type': 'tool_call_update',
          'id': 'tool-1',
          'status': 'completed',
          'output': 'ok',
        }),
      ];

      expect(messages.whereType<ToolUse>(), hasLength(1));
      expect(messages.whereType<ProgressMessage>(), hasLength(1));
      expect(messages.whereType<protocol.ToolResult>(), hasLength(1));
    });

    test('system/api_retry and optional model or plan variants are diagnostic skips', () {
      final messages = [
        ...adapter.messagesForSessionUpdate({'type': 'system/api_retry', 'message': 'retrying'}),
        ...adapter.messagesForSessionUpdate({'type': 'model_update', 'model': 'next'}),
        ...adapter.messagesForSessionUpdate({'type': 'plan_update', 'entries': []}),
      ];

      expect(messages, everyElement(isA<ProtocolDiagnostic>()));
      expect(messages.map((message) => (message as ProtocolDiagnostic).updateType), [
        'system/api_retry',
        'model_update',
        'plan_update',
      ]);
    });

    test('malformed JSON-RPC and unknown future variants are non-fatal and later valid updates still stream', () {
      final messages = [
        ...adapter.parseLine('{not json'),
        ...adapter.parseLine(
          jsonEncode({
            'jsonrpc': '2.0',
            'method': 'session/update',
            'params': {'type': 'unknown_future_variant', 'value': true},
          }),
        ),
        ...adapter.parseLine(
          jsonEncode({
            'jsonrpc': '2.0',
            'method': 'session/update',
            'params': {'type': 'agent_message_chunk', 'text': 'still visible'},
          }),
        ),
      ];

      expect(messages[0], isA<ProtocolDiagnostic>());
      expect(messages[1], isA<ProtocolDiagnostic>());
      expect(messages[2], isA<TextDelta>().having((message) => message.text, 'text', 'still visible'));
    });
  });
}
