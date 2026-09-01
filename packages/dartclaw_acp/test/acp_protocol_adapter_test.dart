import 'dart:convert';

import 'package:dartclaw_acp/dartclaw_acp.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_core/dartclaw_core.dart' as protocol;
import 'package:test/test.dart';

void main() {
  group('ACP protocol adapter S04 session/update mapping', () {
    final adapter = AcpProtocolAdapter();

    test('agent_message_chunk maps to assistant TextDelta while agent_thought_chunk stays progress metadata', () {
      final messages = [
        ...adapter.messagesForSessionUpdate(_textUpdate('agent_message_chunk', 'visible ')),
        ...adapter.messagesForSessionUpdate(_textUpdate('agent_thought_chunk', 'hidden thought')),
      ];

      expect(messages, [
        isA<TextDelta>().having((message) => message.text, 'text', 'visible '),
        isA<ProgressMessage>()
            .having((message) => message.kind, 'kind', 'agent_thought_chunk')
            .having((message) => message.text, 'text', 'hidden thought'),
      ]);
    });

    test('user_message_chunk maps to progress metadata instead of assistant response text', () {
      final messages = adapter.messagesForSessionUpdate(_textUpdate('user_message_chunk', 'quoted user text'));

      expect(messages, [
        isA<ProgressMessage>()
            .having((message) => message.kind, 'kind', 'user_message_chunk')
            .having((message) => message.text, 'text', 'quoted user text'),
      ]);
    });

    test('session_info_update plus usage and context updates produce metadata messages', () {
      final session = adapter.messagesForSessionUpdate(
        _update('session_info_update', {'title': 'Plan cleanup', 'model': 'goose-model'}),
      );
      final usage = adapter.messagesForSessionUpdate(_update('usage_update', {'input_tokens': 7, 'output_tokens': 11}));

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
        ...adapter.messagesForSessionUpdate(
          _update('tool_call', {
            'toolCallId': 'tool-1',
            'title': 'Read config',
            'rawInput': {'path': 'dartclaw.yaml'},
          }),
        ),
        ...adapter.messagesForSessionUpdate(
          _update('tool_call_update', {
            'toolCallId': 'tool-1',
            'rawOutput': {'result': 'ok'},
            'status': 'completed',
          }),
        ),
      ];

      expect(messages, [
        isA<ToolUse>()
            .having((message) => message.id, 'id', 'tool-1')
            .having((message) => message.name, 'name', 'Read config')
            .having((message) => message.input['path'], 'path', 'dartclaw.yaml'),
        isA<protocol.ToolResultMessage>()
            .having((message) => message.toolId, 'toolId', 'tool-1')
            .having((message) => message.output, 'output', '{"result":"ok"}')
            .having((message) => message.isError, 'isError', isFalse),
      ]);
      expect(
        messages.whereType<ToolUse>().single.name,
        isNot(anyOf('fs/read_text_file', 'fs/write_text_file', 'terminal/create')),
      );
    });

    test('tool_call_update progress for tool-1 does not create duplicate ToolUse starts', () {
      final messages = [
        ...adapter.messagesForSessionUpdate(_update('tool_call', {'toolCallId': 'tool-1', 'title': 'Read config'})),
        ...adapter.messagesForSessionUpdate(
          _update('tool_call_update', {'toolCallId': 'tool-1', 'title': 'Read config'}),
        ),
        ...adapter.messagesForSessionUpdate(
          _update('tool_call_update', {
            'toolCallId': 'tool-1',
            'status': 'completed',
            'rawOutput': {'result': 'ok'},
          }),
        ),
      ];

      expect(messages.whereType<ToolUse>(), hasLength(1));
      expect(messages.whereType<ProgressMessage>(), hasLength(1));
      expect(messages.whereType<protocol.ToolResultMessage>(), hasLength(1));
    });

    test('unimplemented official and future update variants are diagnostic skips', () {
      final messages = [
        ...adapter.messagesForSessionUpdate(_update('available_commands_update', {'availableCommands': []})),
        ...adapter.messagesForSessionUpdate(_update('config_option_update', {'configOptions': []})),
        ...adapter.messagesForSessionUpdate(_update('current_mode_update', {'currentModeId': 'code'})),
      ];

      expect(messages, everyElement(isA<ProtocolDiagnostic>()));
      expect(messages.map((message) => (message as ProtocolDiagnostic).updateType), [
        'available_commands_update',
        'config_option_update',
        'current_mode_update',
      ]);
    });

    test('malformed JSON-RPC and unknown future variants are non-fatal and later valid updates still stream', () {
      final messages = [
        ...adapter.parseLine('{not json'),
        ...adapter.parseLine(
          jsonEncode({
            'jsonrpc': '2.0',
            'method': 'session/update',
            'params': _update('unknown_future_variant', {'value': true}),
          }),
        ),
        ...adapter.parseLine(
          jsonEncode({
            'jsonrpc': '2.0',
            'method': 'session/update',
            'params': _textUpdate('agent_message_chunk', 'still visible'),
          }),
        ),
      ];

      expect(messages[0], isA<ProtocolDiagnostic>());
      expect(messages[1], isA<ProtocolDiagnostic>());
      expect(messages[2], isA<TextDelta>().having((message) => message.text, 'text', 'still visible'));
    });

    test('rejects missing pinned envelope, discriminator, and text carrier but accepts empty text', () {
      final violations = <Map<String, dynamic>>[
        const {},
        const {'update': <String, dynamic>{}},
        _update('agent_message_chunk'),
      ];

      for (final payload in violations) {
        expect(
          () => adapter.messagesForSessionUpdate(payload),
          throwsA(
            isA<AcpHarnessException>()
                .having((error) => error.code, 'code', 'ACP_PROTOCOL_VIOLATION')
                .having((error) => error.diagnostics['payload'], 'payload', payload),
          ),
        );
      }
      expect(adapter.messagesForSessionUpdate(_textUpdate('agent_message_chunk', '')), isEmpty);
    });
  });
}

Map<String, dynamic> _update(String type, [Map<String, dynamic> fields = const {}]) => {
  'update': {'sessionUpdate': type, ...fields},
};

Map<String, dynamic> _textUpdate(String type, String text) => _update(type, {
  'content': {
    'content': {'type': 'text', 'text': text},
  },
});
