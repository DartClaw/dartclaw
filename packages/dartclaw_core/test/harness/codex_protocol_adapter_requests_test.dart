import 'dart:convert';

import 'package:dartclaw_core/src/harness/canonical_tool.dart';
import 'package:dartclaw_core/src/harness/codex_protocol_adapter.dart';
import 'package:dartclaw_core/src/harness/codex_settings.dart';
import 'package:dartclaw_core/src/harness/protocol_message.dart';
import 'package:test/test.dart';

Map<String, dynamic> _j(Map<String, dynamic> value) => jsonDecode(jsonEncode(value)) as Map<String, dynamic>;

void main() {
  group('CodexProtocolAdapter.buildTurnRequest', () {
    test('maps configured sandbox values to camelCase sandboxPolicy types', () {
      final adapter = CodexProtocolAdapter();

      for (final entry in const {
        'workspace-write': 'workspaceWrite',
        'danger-full-access': 'dangerFullAccess',
      }.entries) {
        final settings = CodexSettings.buildDynamicSettings(sandbox: entry.key);
        final request = adapter.buildTurnRequest(message: 'test', settings: settings);
        expect(request['params']?['sandboxPolicy'], {'type': entry.value}, reason: entry.key);
      }
    });

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
      final payload = adapter.buildTurnRequest(
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
      ) as Map<String, dynamic>;

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

  group('CodexProtocolAdapter request helpers', () {
    test('builds initialization requests', () {
      final adapter = CodexProtocolAdapter();

      expect(adapter.buildInitializeRequest(id: 1), {
        'id': 1,
        'method': 'initialize',
        'params': {
          'clientInfo': {'name': 'dartclaw', 'version': '0.9.0'},
        },
      });
      expect(adapter.buildInitializedNotification(params: {'session_id': 'sess-123'}), {
        'method': 'initialized',
        'params': {'session_id': 'sess-123'},
      });
      expect(adapter.buildThreadStartRequest(id: 'thread-1', params: {'session_id': 'sess-123'}), {
        'id': 'thread-1',
        'method': 'thread/start',
        'params': {'session_id': 'sess-123'},
      });
    });

    test('fails closed on command authority it cannot evaluate using an offered denial', () {
      final cases = <String, ({Map<String, dynamic> params, Object response})>{
        'missing command': (params: {}, response: {'decision': 'decline'}),
        'additional filesystem permission': (
          params: {
            'command': 'pwd',
            'additionalPermissions': {'fileSystem': <String, dynamic>{}},
          },
          response: {'decision': 'decline'},
        ),
        'network approval': (
          params: {'command': 'curl https://example.com', 'networkApprovalContext': <String, dynamic>{}},
          response: {'decision': 'decline'},
        ),
        'remote environment': (
          params: {'command': 'pwd', 'environmentId': 'remote-1'},
          response: {'decision': 'decline'},
        ),
        'cancel only': (
          params: {
            'command': 'pwd',
            'availableDecisions': ['cancel'],
          },
          response: {'decision': 'cancel'},
        ),
        'accept only with unsafe authority': (
          params: {
            'command': 'pwd',
            'additionalPermissions': {
              'network': {'enabled': true},
            },
            'availableDecisions': ['accept'],
          },
          response: {'code': -32602, 'message': 'No safe approval decision was offered'},
        ),
      };

      for (final entry in cases.entries) {
        final adapter = CodexProtocolAdapter();
        final request = adapter.parseLine(
          jsonEncode({
            'id': entry.key,
            'method': 'item/commandExecution/requestApproval',
            'params': {'itemId': 'command-1', ...entry.value.params},
          }),
        );

        expect(
          request,
          isA<ControlRequest>().having((request) => request.subtype, 'subtype', 'unsupported_command_request'),
          reason: entry.key,
        );
        final response = adapter.buildApprovalResponse(entry.key, allow: false);
        expect(
          response[entry.value.response is Map && (entry.value.response as Map).containsKey('code')
              ? 'error'
              : 'result'],
          entry.value.response,
        );
      }
    });

    test('accepts a command when accept is the offered decision', () {
      final adapter = CodexProtocolAdapter();
      final request = adapter.parseLine(
        jsonEncode({
          'id': 'accept-only',
          'method': 'item/commandExecution/requestApproval',
          'params': {
            'itemId': 'command-1',
            'command': 'pwd',
            'availableDecisions': ['accept'],
          },
        }),
      );

      expect(request, isA<ControlRequest>().having((request) => request.subtype, 'subtype', 'approval'));
      expect(adapter.buildApprovalResponse('accept-only', allow: true)['result'], {'decision': 'accept'});
    });

    test('accepts one command without applying offered persistent policy amendments', () {
      final adapter = CodexProtocolAdapter();
      final request = adapter.parseLine(
        jsonEncode({
          'id': 'one-command',
          'method': 'item/commandExecution/requestApproval',
          'params': {
            'itemId': 'command-1',
            'command': 'pwd',
            'proposedExecpolicyAmendment': ['pwd'],
            'proposedNetworkPolicyAmendments': [
              {'host': 'example.com', 'action': 'allow'},
            ],
            'availableDecisions': [
              'accept',
              {
                'acceptWithExecpolicyAmendment': {
                  'execpolicy_amendment': ['pwd'],
                },
              },
            ],
          },
        }),
      );

      expect(request, isA<ControlRequest>().having((request) => request.subtype, 'subtype', 'approval'));
      expect(adapter.buildApprovalResponse('one-command', allow: true)['result'], {'decision': 'accept'});
    });

    test('answers every other pinned server request with a JSON-RPC error', () {
      const methods = [
        'item/tool/requestUserInput',
        'item/tool/call',
        'account/chatgptAuthTokens/refresh',
        'attestation/generate',
        'currentTime/read',
        'applyPatchApproval',
        'execCommandApproval',
      ];

      for (final method in methods) {
        final adapter = CodexProtocolAdapter();
        final request = adapter.parseLine(jsonEncode({'id': method, 'method': method, 'params': <String, dynamic>{}}));

        expect(
          request,
          isA<ControlRequest>().having((request) => request.subtype, 'subtype', 'unsupported_server_request'),
          reason: method,
        );
        expect(adapter.buildApprovalResponse(method, allow: false), {
          'jsonrpc': '2.0',
          'id': method,
          'error': {'code': -32601, 'message': 'Method not supported by DartClaw'},
        });
      }
    });
  });

  group('CodexProtocolAdapter.mapToolName', () {
    test('maps known provider tools', () {
      final adapter = CodexProtocolAdapter();
      expect(adapter.mapToolName('command_execution'), CanonicalTool.shell);
      expect(adapter.mapToolName('file_change', kind: 'create'), CanonicalTool.fileWrite);
      expect(adapter.mapToolName('file_change', kind: 'update'), CanonicalTool.fileEdit);
      expect(adapter.mapToolName('file_change', kind: 'rename'), CanonicalTool.fileWrite);
      expect(adapter.mapToolName('mcp_tool_call'), CanonicalTool.mcpCall);
      expect(adapter.mapToolName('web_search'), CanonicalTool.webSearch);
    });

    test('maps exact own MCP tools while unknown and third-party tools stay generic', () {
      final adapter = CodexProtocolAdapter(
        ownMcpToolCanonicals: const {
          'memory_apply': CanonicalTool.memoryApply,
          'memory_observe': CanonicalTool.memoryObserve,
          'memory_search': CanonicalTool.memorySearch,
          'memory_read': CanonicalTool.memoryRead,
          'sessions_spawn': CanonicalTool.sessionsSpawn,
        },
      );

      ToolUse parse(String server, String tool) =>
          adapter.parseLine(
                jsonEncode({
                  'method': 'item/started',
                  'params': {
                    'item': {
                      'type': 'mcp_tool_call',
                      'id': '$server-$tool',
                      'server': server,
                      'tool': tool,
                      'arguments': <String, dynamic>{},
                    },
                  },
                }),
              )!
              as ToolUse;

      expect(parse('dartclaw', 'memory_apply').name, 'memory_apply');
      expect(parse('dartclaw', 'memory_observe').name, 'memory_observe');
      expect(parse('dartclaw', 'memory_search').name, 'memory_search');
      expect(parse('dartclaw', 'memory_read').name, 'memory_read');
      expect(parse('dartclaw', 'sessions_spawn').name, 'sessions_spawn');
      expect(parse('dartclaw', 'unknown').name, 'mcp_call');
      expect(parse('third_party', 'memory_apply').name, 'mcp_call');
    });

    test('returns null for unknown and edge-case tool names', () {
      final adapter = CodexProtocolAdapter();
      for (final tool in ['unknown_tool', 'reasoning', 'todo_list', 'error']) {
        expect(adapter.mapToolName(tool), isNull, reason: tool);
      }
    });
  });
}
